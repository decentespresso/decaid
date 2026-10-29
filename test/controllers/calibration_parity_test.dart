import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/de1_controller.dart';
import 'package:reaprime/src/controllers/device_controller.dart';
import 'package:reaprime/src/controllers/scale_controller.dart';
import 'package:reaprime/src/models/device/impl/de1/de1.models.dart';
import 'package:reaprime/src/models/device/impl/de1/mmr_address.dart';
import 'package:reaprime/src/models/device/impl/de1/unified_de1/unified_de1.dart';
import 'package:reaprime/src/models/device/machine.dart';
import 'package:reaprime/src/models/device/scale.dart';

import '../helpers/fake_ble_transport.dart';
import '../helpers/test_scale.dart';

List<int> _mmrWriteValues(FakeBleTransport transport, MmrAddress address) {
  return transport.writes
      .where(
        (write) =>
            write.characteristicUUID == Endpoint.writeToMMR.uuid &&
            write.data.length >= 8 &&
            write.data[1] == ((address.address >> 16) & 0xff) &&
            write.data[2] == ((address.address >> 8) & 0xff) &&
            write.data[3] == (address.address & 0xff),
      )
      .map(
        (write) => ByteData.sublistView(write.data).getUint32(4, Endian.little),
      )
      .toList();
}

void main() {
  test(
    'settings defaults send no calibration packet and keep reported calibration',
    () async {
      final transport = FakeBleTransport()
        ..queueOnConnectResponses(calFlowEst: 1200);
      final de1 = UnifiedDe1(transport: transport);
      addTearDown(de1.dispose);
      await de1.onConnect();
      transport.writes.clear();
      expect(de1.cachedFlowEstimation, 1.2);

      final controller = De1Controller(controller: DeviceController(const []));
      await controller.applySettingsDefaults(de1);

      expect(
        transport.writes.where(
          (write) => write.characteristicUUID == Endpoint.calibration.uuid,
        ),
        isEmpty,
      );
      expect(_mmrWriteValues(transport, MMRItem.calFlowEst), isEmpty);
      expect(de1.cachedFlowEstimation, 1.2);
    },
  );

  test(
    'calibration changes do not alter flow or weight telemetry consumers',
    () async {
      final transport = FakeBleTransport()
        ..queueOnConnectResponses(v13Model: 3);
      final de1 = UnifiedDe1(transport: transport);
      final testScale = TestScale();
      final scaleController = ScaleController();
      addTearDown(de1.dispose);
      addTearDown(testScale.dispose);
      addTearDown(scaleController.dispose);
      await de1.onConnect();
      await scaleController.connectToScale(testScale);

      final machineSnapshots = <MachineSnapshot>[];
      final weightSnapshots = <WeightSnapshot>[];
      final machineSubscription = de1.currentSnapshot.listen(
        machineSnapshots.add,
      );
      final weightSubscription = scaleController.weightSnapshot.listen(
        weightSnapshots.add,
      );
      addTearDown(machineSubscription.cancel);
      addTearDown(weightSubscription.cancel);

      final state = Uint8List.fromList([0x04, ...List.filled(19, 0)]);
      final shot = Uint8List(19);
      ByteData.sublistView(shot)
        ..setUint16(2, 9 * (1 << 12))
        ..setUint16(4, (2.5 * (1 << 12)).toInt());
      transport.subscribers[Endpoint.stateInfo.uuid]!(state);
      transport.subscribers[Endpoint.shotSample.uuid]!(shot);
      testScale.emitSnapshot(
        ScaleSnapshot(
          timestamp: DateTime(2026, 1, 15, 8, 0),
          weight: 36.5,
          batteryLevel: null,
          flow: 1.8,
        ),
      );
      await pumpEventQueue();

      transport.queueMmrResponseInt(MMRItem.calFlowEst, 1500);
      await de1.setFlowEstimation(1.5);
      transport.subscribers[Endpoint.shotSample.uuid]!(shot);
      testScale.emitSnapshot(
        ScaleSnapshot(
          timestamp: DateTime(2026, 1, 15, 8, 0, 0, 1),
          weight: 36.5,
          batteryLevel: null,
          flow: 1.8,
        ),
      );
      await pumpEventQueue();

      expect(machineSnapshots, hasLength(2));
      expect(machineSnapshots[0].flow, 2.5);
      expect(machineSnapshots[1].flow, 2.5);
      expect(weightSnapshots, hasLength(2));
      expect(weightSnapshots[0].weight, 36.5);
      expect(weightSnapshots[1].weight, 36.5);
      expect(weightSnapshots[0].weightFlow, 1.8);
      expect(weightSnapshots[1].weightFlow, 1.8);
    },
  );
}
