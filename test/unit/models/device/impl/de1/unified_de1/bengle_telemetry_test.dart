import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/scale_controller.dart';
import 'package:reaprime/src/models/device/impl/bengle/bengle.dart';
import 'package:reaprime/src/models/device/impl/bengle/bengle_virtual_scale.dart';
import 'package:reaprime/src/models/device/impl/de1/de1.models.dart';
import 'package:reaprime/src/models/device/impl/de1/unified_de1/bengle_shot_sample.dart';
import 'package:reaprime/src/models/device/impl/de1/unified_de1/unified_de1.dart';
import 'package:reaprime/src/models/device/machine.dart';

import '../../../../../../helpers/fake_ble_transport.dart';

final _goldenFrame = Uint8List.fromList(const [
  0x12,
  0x34,
  0x03,
  0x84,
  0x02,
  0x8A,
  0x00,
  0xFA,
  0x00,
  0xAF,
  0x00,
  0xB4,
  0x24,
  0x22,
  0x22,
  0x60,
  0x24,
  0x54,
  0x23,
  0x28,
  0x04,
  0x90,
  0x07,
  0x34,
  0xEE,
  0x10,
  0x9A,
  0x01,
]);

FakeBleTransport _transport({required int model}) => FakeBleTransport()
  ..queueMmrResponseInt(MMRItem.calFlowEst, 100)
  ..queueOnConnectResponses(v13Model: model);

void main() {
  test('decodes the current 28-byte Bengle shot sample', () {
    final sample = decodeBengleShotSample(ByteData.sublistView(_goldenFrame));

    expect(sample, isNotNull);
    expect(sample!.sampleTime, 0x1234);
    expect(sample.groupPressure, 9.0);
    expect(sample.setGroupPressure, 6.5);
    expect(sample.groupFlow, 2.5);
    expect(sample.setGroupFlow, 1.75);
    expect(sample.gFlow, 1.8);
    expect(sample.mixTemperature, 92.5);
    expect(sample.groupTemperature, 88.0);
    expect(sample.setMixTemperature, 93.0);
    expect(sample.setGroupTemperature, 90.0);
    expect(sample.weight, 36.5);
    expect(sample.frameNumber, 7);
    expect(sample.steamTemperature, 135.5);
    expect(sample.milkTemperature, 42.5);
    expect(sample.flags, 1);
    expect(decodeBengleShotSample(ByteData(27)), isNull);
  });

  test(
    'one A013 frame fans out to machine, scale, and probe surfaces',
    () async {
      final transport = _transport(model: 128);
      final bengle = Bengle(transport: transport);
      final scaleController = ScaleController();
      await bengle.onConnect();
      await scaleController.connectToScale(BengleVirtualScale(bengle));
      final machineSnapshots = <MachineSnapshot>[];
      final scaleSnapshots = <WeightSnapshot>[];
      final probeTemps = <double>[];
      final probeStates = <bool>[];
      final machineSubscription = bengle.currentSnapshot.listen(
        machineSnapshots.add,
      );
      final scaleSubscription = scaleController.weightSnapshot.listen(
        scaleSnapshots.add,
      );
      final attachedSubscription = bengle.probeAttached.listen(probeStates.add);
      final tempSubscription = bengle.probeTemperature.listen(probeTemps.add);

      await pumpEventQueue();
      expect(machineSnapshots, isEmpty);
      expect(scaleSnapshots, isEmpty);
      expect(probeStates, [false]);

      transport.subscribers[Endpoint.stateInfo.uuid]!(
        Uint8List.fromList([0x04, 0x05]),
      );
      transport.subscribers[Endpoint.shotSample.uuid]!(Uint8List(19));
      await pumpEventQueue();
      expect(machineSnapshots, isEmpty);

      transport.subscribers[Endpoint.bengleShotSample.uuid]!(_goldenFrame);
      await pumpEventQueue();

      expect(machineSnapshots, hasLength(1));
      expect(scaleSnapshots, hasLength(1));
      final machine = machineSnapshots.single;
      final scale = scaleSnapshots.single;
      expect(machine.state.state, MachineState.espresso);
      expect(machine.state.substate, MachineSubstate.pouring);
      expect(machine.pressure, 9.0);
      expect(machine.flow, 2.5);
      expect(machine.mixTemperature, 92.5);
      expect(machine.groupTemperature, 88.0);
      expect(machine.targetMixTemperature, 93.0);
      expect(machine.targetGroupTemperature, 90.0);
      expect(machine.targetPressure, 6.5);
      expect(machine.targetFlow, 1.75);
      expect(machine.profileFrame, 7);
      expect(machine.steamTemperature, 136);
      // MachineSnapshot stays pure machine telemetry: no weight/GFlow/probe.
      expect(machine.toJson().containsKey('weight'), isFalse);
      expect(machine.toJson().containsKey('weightFlow'), isFalse);
      expect(machine.toJson().containsKey('milkTemperature'), isFalse);

      expect(scale.weight, 36.5);
      expect(scale.weightFlow, 1.8);

      expect(probeStates, [false, true]);
      expect(probeTemps, [42.5]);

      await machineSubscription.cancel();
      await scaleSubscription.cancel();
      await attachedSubscription.cancel();
      await tempSubscription.cancel();
      scaleController.dispose();
      await bengle.dispose();
    },
  );

  test(
    'MilkTemp 0 reports probe detached without emitting temperature',
    () async {
      final transport = _transport(model: 128);
      final bengle = Bengle(transport: transport);
      await bengle.onConnect();
      final probeStates = <bool>[];
      final probeTemps = <double>[];
      final attachedSubscription = bengle.probeAttached.listen(probeStates.add);
      final tempSubscription = bengle.probeTemperature.listen(probeTemps.add);
      final emit = transport.subscribers[Endpoint.bengleShotSample.uuid]!;

      emit(_goldenFrame);
      await pumpEventQueue();
      expect(probeStates, [false, true]);
      expect(probeTemps, [42.5]);

      final noProbeFrame = Uint8List.fromList(_goldenFrame)
        ..[25] = 0x00
        ..[26] = 0x00;
      emit(noProbeFrame);
      await pumpEventQueue();
      expect(probeStates, [false, true, false]);
      expect(probeTemps, [42.5]);

      await attachedSubscription.cancel();
      await tempSubscription.cancel();
      await bengle.dispose();
    },
  );

  test('Bengle tare writes ScaleTare and keeps firmware flow', () async {
    final transport = _transport(model: 128);
    final bengle = Bengle(transport: transport);
    final scaleController = ScaleController();
    await bengle.onConnect();
    await scaleController.connectToScale(BengleVirtualScale(bengle));
    final snapshots = <WeightSnapshot>[];
    final subscription = scaleController.weightSnapshot.listen(snapshots.add);
    final emit = transport.subscribers[Endpoint.bengleShotSample.uuid]!;

    emit(_goldenFrame);
    await pumpEventQueue();
    transport.writes.clear();
    await scaleController.tare();

    final write = transport.writes.singleWhere(
      (entry) => entry.characteristicUUID == Endpoint.writeToMMR.uuid,
    );
    expect(write.data.sublist(0, 8), [
      0x04,
      0x80,
      0x38,
      0x8C,
      0x01,
      0x00,
      0x00,
      0x00,
    ]);

    emit(_goldenFrame);
    await pumpEventQueue();
    expect(snapshots.last.weight, 36.5);
    expect(snapshots.last.weightFlow, 1.8);

    await subscription.cancel();
    scaleController.dispose();
    await bengle.dispose();
  });

  test('Bengle integrated telemetry resumes after reconnect', () async {
    final transport = _transport(model: 128);
    final bengle = Bengle(transport: transport);
    addTearDown(bengle.dispose);
    await bengle.onConnect();

    transport.subscribers[Endpoint.bengleShotSample.uuid]!(_goldenFrame);
    expect((await bengle.weightSnapshot.first).weight, 36.5);

    await bengle.disconnect();
    await bengle.onConnect();
    final snapshot = bengle.weightSnapshot.first;
    transport.subscribers[Endpoint.bengleShotSample.uuid]!(_goldenFrame);

    expect((await snapshot).flow, 1.8);
  });

  test('plain DE1 stays on A00D and never subscribes A013', () async {
    final transport = _transport(model: 3);
    final de1 = UnifiedDe1(transport: transport);
    await de1.onConnect();
    final snapshots = <MachineSnapshot>[];
    final subscription = de1.currentSnapshot.listen(snapshots.add);

    expect(transport.subscribers[Endpoint.bengleShotSample.uuid], isNull);
    transport.subscribers[Endpoint.stateInfo.uuid]!(
      Uint8List.fromList([0x04, 0x05]),
    );
    final frame = Uint8List(19)
      ..[2] = 0x10
      ..[3] = 0x00;
    transport.subscribers[Endpoint.shotSample.uuid]!(frame);
    await pumpEventQueue();

    expect(snapshots, hasLength(1));
    expect(snapshots.single.pressure, 1.0);

    await subscription.cancel();
    await de1.dispose();
  });
}
