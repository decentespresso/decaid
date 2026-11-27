import 'dart:async';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/device/device.dart' as device;
import 'package:reaprime/src/models/device/firmware_update_state.dart';
import 'package:reaprime/src/models/device/impl/de1/de1.models.dart';
import 'package:reaprime/src/models/device/impl/de1/unified_de1/unified_de1.dart';
import 'package:reaprime/src/models/device/transport/ble_timeout_exception.dart';

import '../../../../../../helpers/fake_ble_transport.dart';

final class _FakeAsyncConnectionBleTransport extends FakeBleTransport {
  final device.ConnectionState _connectionState =
      device.ConnectionState.connected;

  @override
  Stream<device.ConnectionState> get connectionState => Stream.multi((events) {
    events.add(_connectionState);
    events.close();
  });

  @override
  Future<device.ConnectionState> getConnectionState() async => _connectionState;
}

/// Terminal frame: window, erase, map, then three error bytes.
final _eraseTerminal = Uint8List.fromList([0, 0, 0, 1, 0, 0, 0]);
final _verifySuccess = Uint8List.fromList([0, 0, 0, 1, 0xff, 0xff, 0xfd]);

void main() {
  late FakeBleTransport transport;
  late UnifiedDe1 de1;

  setUp(() async {
    transport = _FakeAsyncConnectionBleTransport();
    addTearDown(transport.dispose);
    transport.queueOnConnectResponses(v13Model: 3);
    transport.queueMmrResponseInt(MMRItem.calFlowEst, 0);
    de1 = UnifiedDe1(
      transport: transport,
      firmwareEraseTimeout: const Duration(seconds: 1),
      firmwareVerificationTimeout: const Duration(seconds: 1),
    );
    await de1.onConnect();
  });

  test(
    'POLL-only: completes via GATT read when NO notify is ever emitted',
    () async {
      transport.queueRead(Endpoint.fwMapRequest.uuid, _eraseTerminal);
      transport.queueRead(Endpoint.fwMapRequest.uuid, _verifySuccess);

      await de1.updateFirmware(Uint8List(16), onProgress: (_) {});

      expect(de1.firmwareUpdateState, FirmwareUpdateState.idle);
    },
  );

  test(
    'NOTIFY-only regression: still completes via notify with the poll present',
    () async {
      // No queued reads, so the poll only ever sees the non-terminal default.
      transport.queueFirmwareMapResponse(_eraseTerminal);
      var completed = false;
      final update = de1
          .updateFirmware(Uint8List(16), onProgress: (_) {})
          .whenComplete(() => completed = true);

      await _waitForState(de1, FirmwareUpdateState.verifying);
      expect(completed, isFalse, reason: 'verify awaits its notify');

      transport.emitFirmwareMapResponse(_verifySuccess);
      await update;
      expect(de1.firmwareUpdateState, FirmwareUpdateState.idle);
    },
  );

  test('BLE missing A009 uses notifications without repeated reads', () async {
    transport.firmwareMapReadUnavailable = true;
    transport.queueFirmwareMapResponse(_eraseTerminal);
    Future<void>? update;
    fakeAsync((async) {
      update = de1.updateFirmware(Uint8List(16), onProgress: (_) {});
      unawaited(
        update!.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
      );
      async.elapse(Duration.zero);
      expect(de1.firmwareUpdateState, FirmwareUpdateState.verifying);
      expect(transport.firmwareMapReadCalls, 1);
      async.elapse(const Duration(milliseconds: 750));
      expect(transport.firmwareMapReadCalls, 1);
      transport.emitFirmwareMapResponse(_verifySuccess);
      async.elapse(Duration.zero);
    });
    await update!;

    expect(transport.firmwareMapReadCalls, 1);
    expect(de1.firmwareUpdateState, FirmwareUpdateState.idle);
  });

  test(
    'BLE unreadable A009 uses notifications without repeated reads',
    () async {
      transport.firmwareMapReadNotReadable = true;
      transport.queueFirmwareMapResponse(_eraseTerminal);
      Future<void>? update;
      fakeAsync((async) {
        update = de1.updateFirmware(Uint8List(16), onProgress: (_) {});
        unawaited(
          update!.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
        );
        async.elapse(Duration.zero);
        expect(de1.firmwareUpdateState, FirmwareUpdateState.verifying);
        expect(transport.firmwareMapReadCalls, 1);
        async.elapse(const Duration(milliseconds: 750));
        expect(transport.firmwareMapReadCalls, 1);
        transport.emitFirmwareMapResponse(_verifySuccess);
        async.elapse(Duration.zero);
      });
      await update!;

      expect(transport.firmwareMapReadCalls, 1);
      expect(de1.firmwareUpdateState, FirmwareUpdateState.idle);
    },
  );

  test(
    'NEITHER: times out when no notify AND no terminal poll read arrives',
    () async {
      // setUp's onConnect drained the first batch of MMR responses.
      transport.queueOnConnectResponses(v13Model: 3);
      transport.queueMmrResponseInt(MMRItem.calFlowEst, 0);
      final timeoutDe1 = UnifiedDe1(
        transport: transport,
        firmwareEraseTimeout: const Duration(milliseconds: 100),
        firmwareVerificationTimeout: const Duration(milliseconds: 100),
      );
      await timeoutDe1.onConnect();

      final writesBefore = transport.writes.length;
      await expectLater(
        timeoutDe1.updateFirmware(Uint8List(16), onProgress: (_) {}),
        throwsA(isA<TimeoutException>()),
      );
      expect(
        transport.writes
            .skip(writesBefore)
            .where((w) => w.characteristicUUID == Endpoint.writeToMMR.uuid),
        isEmpty,
      );
    },
  );

  test(
    'a failed verify poll read still fails: non-success terminal throws',
    () async {
      transport.queueRead(Endpoint.fwMapRequest.uuid, _eraseTerminal);
      transport.queueRead(
        Endpoint.fwMapRequest.uuid,
        Uint8List.fromList([0, 0, 0, 1, 0xff, 0xff, 0x01]),
      );

      await expectLater(
        de1.updateFirmware(Uint8List(16), onProgress: (_) {}),
        throwsA(isA<StateError>()),
      );
      expect(de1.firmwareUpdateState, FirmwareUpdateState.idle);
    },
  );

  test(
    'a thrown poll read does not disturb the link: retries and still completes',
    () async {
      transport.queueRead(Endpoint.fwMapRequest.uuid, _eraseTerminal);
      transport.queueReadError(
        Endpoint.fwMapRequest.uuid,
        BleTimeoutException('GATT read(fwMapRequest)'),
      );
      transport.queueRead(Endpoint.fwMapRequest.uuid, _verifySuccess);

      final connectsBefore = transport.connectCalls;
      final disconnectsBefore = transport.disconnectCalls;

      await de1.updateFirmware(Uint8List(16), onProgress: (_) {});

      expect(de1.firmwareUpdateState, FirmwareUpdateState.idle);
      expect(
        transport.connectCalls,
        connectsBefore,
        reason: 'poll read must not trigger a reconnect',
      );
      expect(transport.disconnectCalls, disconnectsBefore);
    },
  );
}

Future<void> _waitForState(UnifiedDe1 de1, FirmwareUpdateState state) async {
  final deadline = DateTime.now().add(const Duration(seconds: 1));
  while (de1.firmwareUpdateState != state) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('State did not become ${state.name}');
    }
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
}
