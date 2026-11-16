import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/device_implementation.dart';
import 'package:reaprime/src/models/device/impl/de1/de1.models.dart';
import 'package:reaprime/src/models/device/impl/de1/unified_de1/bengle_shot_sample.dart';
import 'package:reaprime/src/models/device/impl/de1/unified_de1/unified_de1.dart';
import 'package:reaprime/src/models/device/machine.dart';

import '../../helpers/fake_ble_transport.dart';

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
