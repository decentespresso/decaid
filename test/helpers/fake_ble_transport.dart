import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/impl/de1/de1.models.dart';
import 'package:reaprime/src/models/device/impl/de1/mmr_address.dart';
import 'package:reaprime/src/models/device/machine.dart';
import 'package:reaprime/src/models/device/transport/ble_transport.dart';
import 'package:rxdart/rxdart.dart';

/// Recorded write captured by [FakeBleTransport]. Includes the
/// `withResponse` flag so tests covering `writeWithResponse` vs.
/// fire-and-forget paths can distinguish them.
typedef FakeBleWrite = ({
  String characteristicUUID,
  Uint8List data,
  bool withResponse,
});

/// Consolidated BLE transport stub for tests.
///
/// Replaces the per-test stubs that lived in `protected_surface_test.dart`
/// (`_ProgrammableBleTransport`), `firmware_prelude_hook_test.dart`
/// (`_CapturingBleTransport`), and `bengle_firmware_prelude_test.dart`
/// (`_CapturingBleTransport`).
///
/// Capabilities provided:
///
/// * BLE service discovery returns `[de1ServiceUUID]`.
/// * Per-UUID subscribe-callback capture.
/// * Per-UUID `read()` queue ([queueRead]) — falls through to a 20-byte
///   zero buffer for unstubbed reads.
/// * Ordered write capture in [writes].
/// * MMR-response synthesis: calling [queueMmrResponseInt] /
///   [queueMmrResponseRaw] sets up a pending response that is emitted
///   on the `readFromMMR` notification stream when a matching MMR
///   read request hits `Endpoint.readFromMMR.uuid`.
/// * [lastRequestedState] decodes the most recent write to
///   `Endpoint.requestedState` back into a [MachineState] for
///   readable assertions.
class FakeBleTransport extends BLETransport {
  final _connState = BehaviorSubject<ConnectionState>.seeded(
    ConnectionState.connected,
  );

  /// Subscribe callbacks keyed by characteristic UUID.
  final Map<String, void Function(Uint8List)> subscribers = {};

  /// Address -> integer to emit on the next matching MMR read request.
  final Map<int, int> _intResponses = {};

  /// Address -> raw 16-byte payload (bytes 4..19 of the 20-byte MMR
  /// notification frame). Takes precedence over [_intResponses] when
  /// both are queued for the same address.
  final Map<int, List<int>> _rawResponses = {};

  /// Per-UUID queued `read()` payloads.
  final Map<String, Queue<Uint8List>> _readQueue = {};
  final Queue<Uint8List> _firmwareMapResponses = Queue<Uint8List>();

  /// Ordered writes seen by the transport.
  final List<FakeBleWrite> writes = [];

  /// Number of upcoming matching MMR read requests whose notification is
  /// silently dropped (the queued response is left intact for a retry).
  /// Simulates the Android post-connect notify-loss the `_mmrReadRaw`
  /// retry guards against.
  int dropNextMmrResponses = 0;

  /// Queue an integer to be returned when a read request to [item] hits
  /// the MMR write characteristic.
  void queueMmrResponseInt(MmrAddress item, int value) {
    _intResponses[item.address] = value;
  }

  /// Queue a raw payload (1..16 bytes) to be returned when a read
  /// request to [item] hits the MMR write characteristic.
  void queueMmrResponseRaw(MmrAddress item, List<int> payload) {
    _rawResponses[item.address] = payload;
  }

  /// Queue [bytes] for the next `read()` call against [characteristicUUID].
  /// Subsequent reads pop further entries; once empty the default 20-byte
  /// zero buffer is returned.
  void queueRead(String characteristicUUID, Uint8List bytes) {
    _readQueue.putIfAbsent(characteristicUUID, Queue.new).add(bytes);
  }

  void queueFirmwareMapResponse(List<int> bytes) {
    _firmwareMapResponses.add(Uint8List.fromList(bytes));
  }

  void emitFirmwareMapResponse(List<int> bytes) {
    subscribers[Endpoint.fwMapRequest.uuid]?.call(Uint8List.fromList(bytes));
  }

  /// Decoded last `requestedState` write, or null if none seen.
  MachineState? get lastRequestedState {
    for (final w in writes.reversed) {
      if (w.characteristicUUID != Endpoint.requestedState.uuid) continue;
      if (w.data.isEmpty) continue;
      final stateEnum = De1StateEnum.fromHexValue(w.data[0]);
      for (final ms in MachineState.values) {
        if (De1StateEnum.fromMachineState(ms) == stateEnum) return ms;
      }
      return null;
    }
    return null;
  }

  @override
  String get id => 'fake-ble';

  @override
  String get name => 'FakeBle';

  @override
  Stream<ConnectionState> get connectionState => _connState.stream;

  @override
  Future<ConnectionState> getConnectionState() async => _connState.value;

  @override
  Future<void> connect() async {}

  @override
  Future<void> disconnect() async {}

  @override
  Future<List<String>> discoverServices() async => [de1ServiceUUID];

  @override
  Future<Uint8List> read(
    String serviceUUID,
    String characteristicUUID, {
    Duration? timeout,
  }) async {
    final q = _readQueue[characteristicUUID];
    if (q != null && q.isNotEmpty) return q.removeFirst();
    return Uint8List(20);
  }

  @override
  Future<void> subscribe(
    String serviceUUID,
    String characteristicUUID,
    void Function(Uint8List) callback,
  ) async {
    subscribers[characteristicUUID] = callback;
  }

  @override
  Future<void> setTransportPriority(bool prioritized) async {}

  @override
  Future<void> write(
    String serviceUUID,
    String characteristicUUID,
    Uint8List data, {
    bool withResponse = true,
    Duration? timeout,
  }) async {
    writes.add((
      characteristicUUID: characteristicUUID,
      data: data,
      withResponse: withResponse,
    ));

    if (characteristicUUID == Endpoint.fwMapRequest.uuid &&
        _firmwareMapResponses.isNotEmpty) {
      final response = _firmwareMapResponses.removeFirst();
      final callback = subscribers[Endpoint.fwMapRequest.uuid];
      if (callback != null) scheduleMicrotask(() => callback(response));
    }

    // The DE1 firmware overloads `Endpoint.readFromMMR` for *requests*:
    // a write to that characteristic asks for a payload; the firmware
    // then notifies on the same UUID. Synthesize a matching notification
    // when the test has queued a response for the requested address.
    if (characteristicUUID != Endpoint.readFromMMR.uuid) return;
    if (data.length < 4) return;
    // Drop this notification (but keep the queued response) to simulate a
    // lost notify; the retry's next write will be answered.
    if (dropNextMmrResponses > 0) {
      dropNextMmrResponses--;
      return;
    }
    final addrMid1 = data[1];
    final addrMid2 = data[2];
    final addrLow = data[3];

    int? matchedRawAddr;
    for (final addr in _rawResponses.keys) {
      final bytes = ByteData(4)..setInt32(0, addr, Endian.big);
      if (bytes.getUint8(1) == addrMid1 &&
          bytes.getUint8(2) == addrMid2 &&
          bytes.getUint8(3) == addrLow) {
        matchedRawAddr = addr;
        break;
      }
    }
    if (matchedRawAddr != null) {
      final payload = _rawResponses.remove(matchedRawAddr)!;
      final resp = Uint8List(20);
      resp[0] = data[0];
      resp[1] = addrMid1;
      resp[2] = addrMid2;
      resp[3] = addrLow;
      for (var i = 0; i < payload.length && i + 4 < 20; i++) {
        resp[i + 4] = payload[i];
      }
      final cb = subscribers[Endpoint.readFromMMR.uuid];
      if (cb != null) {
        scheduleMicrotask(() => cb(resp));
      }
      return;
    }

    int? matchedAddr;
    for (final addr in _intResponses.keys) {
      final bytes = ByteData(4)..setInt32(0, addr, Endian.big);
      if (bytes.getUint8(1) == addrMid1 &&
          bytes.getUint8(2) == addrMid2 &&
          bytes.getUint8(3) == addrLow) {
        matchedAddr = addr;
        break;
      }
    }
    if (matchedAddr == null) return;
    final value = _intResponses.remove(matchedAddr)!;
    final resp = Uint8List(20);
    final view = ByteData.sublistView(resp);
    view.setUint8(0, data[0]);
    view.setUint8(1, addrMid1);
    view.setUint8(2, addrMid2);
    view.setUint8(3, addrLow);
    view.setInt32(4, value, Endian.little);
    final cb = subscribers[Endpoint.readFromMMR.uuid];
    if (cb != null) {
      // Emit asynchronously so `_mmrRead`'s firstWhere subscription is
      // set up before the value lands.
      scheduleMicrotask(() => cb(resp));
    }
  }

  /// Queue the standard set of MMR responses needed for `onConnect()` to
  /// complete (`v13Model`, `ghcInfo`, `serialN`, `cpuFirmwareBuild`,
  /// `heaterV`, `refillKitPresent`). Override individual values via
  /// keyword arguments.
  void queueOnConnectResponses({
    int v13Model = 1,
    int ghcInfo = 0,
    int serialN = 12345,
    int cpuFirmwareBuild = 1300,
    int heaterV = 230,
    int refillKitPresent = 0,
  }) {
    queueMmrResponseInt(MMRItem.v13Model, v13Model);
    queueMmrResponseInt(MMRItem.ghcInfo, ghcInfo);
    queueMmrResponseInt(MMRItem.serialN, serialN);
    queueMmrResponseInt(MMRItem.cpuFirmwareBuild, cpuFirmwareBuild);
    queueMmrResponseInt(MMRItem.heaterV, heaterV);
    queueMmrResponseInt(MMRItem.refillKitPresent, refillKitPresent);
  }

  @override
  Future<void> dispose() async => _connState.close();
}
