import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/device_implementation.dart';
import 'package:reaprime/src/models/device/impl/de1/de1.models.dart';
import 'package:reaprime/src/models/device/impl/de1/unified_de1/bengle_shot_sample.dart';
import 'package:reaprime/src/models/device/impl/de1/unified_de1/unified_de1.dart';
import 'package:reaprime/src/models/device/machine.dart';
import 'package:reaprime/src/models/device/transport/ble_timeout_exception.dart';

import '../../helpers/fake_ble_transport.dart';

class _RecoveringSnapshotTransport extends FakeBleTransport {
  bool failNextStateWrite = false;

  @override
  Future<void> connect() async {
    await super.connect();
    emitConnectionState(ConnectionState.connected);
  }

  @override
  Future<void> disconnect() async {
    await super.disconnect();
    emitConnectionState(ConnectionState.disconnected);
  }

  @override
  Future<void> write(
    String serviceUUID,
    String characteristicUUID,
    Uint8List data, {
    bool withResponse = true,
    Duration? timeout,
  }) async {
    if (failNextStateWrite &&
        characteristicUUID == Endpoint.requestedState.uuid) {
      failNextStateWrite = false;
      throw BleTimeoutException('write');
    }
    await super.write(
      serviceUUID,
      characteristicUUID,
      data,
      withResponse: withResponse,
      timeout: timeout,
    );
  }
}

void _automaticRecoveryTests(bool bengle) {
  test(
    'snapshot bengle=$bengle timeout recovery rejects previous-session replay',
    () async {
      final ble = _RecoveringSnapshotTransport()..queueOnConnectResponses();
      final machine = _SnapshotMachine(transport: ble, bengle: bengle);
      addTearDown(machine.dispose);
      await machine.onConnect();
      final endpoint = bengle ? Endpoint.bengleShotSample : Endpoint.shotSample;
      final oldValues = <MachineSnapshot>[];
      final old = machine.currentSnapshot.listen(oldValues.add);
      addTearDown(old.cancel);
      await pumpEventQueue();
      ble.emitNotification(endpoint, _sample(1, bengle));
      await pumpEventQueue();
      expect(oldValues.single.pressure, 1);
      final retired = ble.subscribers[endpoint.uuid]!;

      ble.failNextStateWrite = true;
      await machine.requestState(MachineState.idle);
      final currentValues = <MachineSnapshot>[];
      final current = machine.currentSnapshot.listen(currentValues.add);
      addTearDown(current.cancel);
      await pumpEventQueue();
      expect(currentValues, isEmpty);
      retired(_sample(3, bengle));
      await pumpEventQueue();
      expect(currentValues, isEmpty);
      expect(oldValues, hasLength(1));
      ble.emitNotification(endpoint, _sample(2, bengle));
      await pumpEventQueue();
      expect(currentValues.single.pressure, 2);
    },
  );

  test(
    'snapshot bengle=$bengle timeout recovery keeps existing listeners live',
    () async {
      final ble = _RecoveringSnapshotTransport()..queueOnConnectResponses();
      final machine = _SnapshotMachine(transport: ble, bengle: bengle);
      addTearDown(machine.dispose);
      await machine.onConnect();
      final endpoint = bengle ? Endpoint.bengleShotSample : Endpoint.shotSample;
      final values = <MachineSnapshot>[];
      final subscription = machine.currentSnapshot.listen(values.add);
      addTearDown(subscription.cancel);
      final states = <ConnectionState>[];
      final connection = machine.connectionState.listen(states.add);
      addTearDown(connection.cancel);
      await pumpEventQueue();
      ble.emitNotification(endpoint, _sample(1, bengle));
      await pumpEventQueue();

      ble.failNextStateWrite = true;
      await machine.requestState(MachineState.idle);
      ble.emitNotification(endpoint, _sample(2, bengle));
      await pumpEventQueue();

      expect(values.map((snapshot) => snapshot.pressure), [1, 2]);
      expect(states, isNot(contains(ConnectionState.disconnected)));
      expect(ble.disconnectCalls, 1);
      expect(ble.connectCalls, 2);
    },
  );
}

Uint8List _sample(int pressure, bool bengle) => (ByteData(
  bengle ? bengleShotSampleLength : 19,
)..setUint16(2, pressure * (bengle ? 100 : 4096))).buffer.asUint8List();

class _SnapshotMachine extends UnifiedDe1 {
  _SnapshotMachine({required super.transport, required this.bengle});

  final bool bengle;

  @override
  DeviceImplementation get implementation =>
      bengle ? DeviceImplementation.bengle : DeviceImplementation.unifiedDe1;

  @override
  Future<void> onConnect() async {
    await super.onConnect();
    if (bengle) await enableBengleShotSample();
  }
}

void main() {
  for (final bengle in [false, true]) {
    _automaticRecoveryTests(bengle);
    test(
      'snapshot bengle=$bengle reconnect uses only the new session',
      () async {
        final ble = FakeBleTransport()..queueOnConnectResponses();
        final machine = _SnapshotMachine(transport: ble, bengle: bengle);
        addTearDown(machine.dispose);
        await machine.onConnect();
        final oldValues = <MachineSnapshot>[];
        final old = machine.currentSnapshot.listen(oldValues.add);
        await pumpEventQueue();
        final endpoint = bengle
            ? Endpoint.bengleShotSample
            : Endpoint.shotSample;
        Uint8List sample(int pressure) {
          final data = ByteData(bengle ? bengleShotSampleLength : 19)
            ..setUint16(2, pressure * (bengle ? 100 : 4096));
          return data.buffer.asUint8List();
        }

        ble.emitNotification(endpoint, sample(1));
        await pumpEventQueue();
        expect(oldValues.single.pressure, 1);
        ble.emitConnectionState(ConnectionState.disconnected);
        await pumpEventQueue();
        ble.emitConnectionState(ConnectionState.connected);
        ble.queueOnConnectResponses();
        await machine.onConnect();
        final currentValues = <MachineSnapshot>[];
        final current = machine.currentSnapshot.listen(currentValues.add);
        await pumpEventQueue();
        expect(currentValues, isEmpty);
        ble.emitNotification(endpoint, sample(2));
        await pumpEventQueue();
        expect(currentValues.single.pressure, 2);
        expect(oldValues, hasLength(1));
        await old.cancel();
        await current.cancel();
      },
    );
  }
}
