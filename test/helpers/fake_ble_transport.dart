import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/impl/de1/de1.models.dart';
import 'package:reaprime/src/models/device/impl/de1/mmr_address.dart';
import 'package:reaprime/src/models/device/machine.dart';
import 'package:reaprime/src/models/device/transport/ble_transport.dart';
import 'package:rxdart/rxdart.dart';

typedef FakeBleWrite = ({
  String characteristicUUID,
  Uint8List data,
  bool withResponse,
});

class FakeBleTransport extends BLETransport {
  final _connState = BehaviorSubject<ConnectionState>.seeded(
    ConnectionState.connected,
  );

  final Map<String, void Function(Uint8List)> subscribers = {};

  final Map<int, int> _intResponses = {};

  final Map<int, Queue<int>> _intResponseQueues = {};

  final Map<int, List<int>> _rawResponses = {};

  final Map<String, Queue<Uint8List>> _readQueue = {};
  final Queue<Uint8List> _firmwareMapResponses = Queue<Uint8List>();

  /// MMR addresses whose reads fail fast with an exception (simulates a
  /// transport error on those registers).
  final Set<int> failMmrReadsForAddresses = {};

  final List<FakeBleWrite> writes = [];

  int dropNextMmrResponses = 0;

  void queueMmrResponseInt(MmrAddress item, int value) {
    _intResponses[item.address] = value;
  }

  /// Queue a zero response for every LED palette register (rows 45-48,
  /// 0x00803898-0x008038A4) so the LED hydration in `Bengle.onConnect`
  /// completes quickly in tests that do not care about LEDs. Without this,
  /// each unqueued read burns the full MMR timeout path (~4s x 3 attempts).
  void queuePaletteHydrationResponses() {
    for (final addr in [0x00803898, 0x0080389C, 0x008038A0, 0x008038A4]) {
      _intResponses[addr] = 0;
    }
  }

  /// Queue multiple responses for repeated reads of the same address, in
  /// FIFO order (the one-shot [_intResponses] map can only serve one).
  void queueMmrResponseIntSequence(MmrAddress item, List<int> values) {
    _intResponseQueues.putIfAbsent(item.address, Queue.new).addAll(values);
  }

  void queueMmrResponseRaw(MmrAddress item, List<int> payload) {
    _rawResponses[item.address] = payload;
  }

  void queueRead(String characteristicUUID, Uint8List bytes) {
    _readQueue.putIfAbsent(characteristicUUID, Queue.new).add(bytes);
  }

  void queueFirmwareMapResponse(List<int> bytes) {
    _firmwareMapResponses.add(Uint8List.fromList(bytes));
  }

  void emitFirmwareMapResponse(List<int> bytes) {
    subscribers[Endpoint.fwMapRequest.uuid]?.call(Uint8List.fromList(bytes));
  }

  void emitNotification(Endpoint endpoint, List<int> bytes) {
    subscribers[endpoint.uuid]?.call(Uint8List.fromList(bytes));
  }

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

    if (characteristicUUID != Endpoint.readFromMMR.uuid) return;
    if (data.length < 4) return;
    for (final addr in failMmrReadsForAddresses) {
      final bytes = ByteData(4)..setInt32(0, addr, Endian.big);
      if (bytes.getUint8(1) == data[1] &&
          bytes.getUint8(2) == data[2] &&
          bytes.getUint8(3) == data[3]) {
        throw StateError(
          'simulated MMR read failure for 0x'
          '${addr.toRadixString(16)}',
        );
      }
    }
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

    // Serve queued sequences first (FIFO per address) so repeated reads of
    // the same register can return different values.
    for (final addr in _intResponseQueues.keys) {
      final bytes = ByteData(4)..setInt32(0, addr, Endian.big);
      if (bytes.getUint8(1) == addrMid1 &&
          bytes.getUint8(2) == addrMid2 &&
          bytes.getUint8(3) == addrLow) {
        final queue = _intResponseQueues[addr]!;
        if (queue.isNotEmpty) {
          final value = queue.removeFirst();
          if (queue.isEmpty) _intResponseQueues.remove(addr);
          final resp = Uint8List(20);
          final view = ByteData.sublistView(resp);
          view.setUint8(0, data[0]);
          view.setUint8(1, addrMid1);
          view.setUint8(2, addrMid2);
          view.setUint8(3, addrLow);
          view.setInt32(4, value, Endian.little);
          final cb = subscribers[Endpoint.readFromMMR.uuid];
          if (cb != null) {
            scheduleMicrotask(() => cb(resp));
          }
          return;
        }
      }
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
      scheduleMicrotask(() => cb(resp));
    }
  }

  void queueOnConnectResponses({
    int v13Model = 1,
    int ghcInfo = 0,
    int serialN = 12345,
    int cpuFirmwareBuild = 1300,
    int heaterV = 230,
    int refillKitPresent = 0,
    // calFlowEst has a read scale of 0.001, so raw 1000 is 1.0.
    int calFlowEst = 1000,
  }) {
    queueMmrResponseInt(MMRItem.v13Model, v13Model);
    queueMmrResponseInt(MMRItem.ghcInfo, ghcInfo);
    queueMmrResponseInt(MMRItem.serialN, serialN);
    queueMmrResponseInt(MMRItem.cpuFirmwareBuild, cpuFirmwareBuild);
    queueMmrResponseInt(MMRItem.heaterV, heaterV);
    queueMmrResponseInt(MMRItem.refillKitPresent, refillKitPresent);
    queueMmrResponseInt(MMRItem.calFlowEst, calFlowEst);
  }

  @override
  Future<void> dispose() async => _connState.close();
}
