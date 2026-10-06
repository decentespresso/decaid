import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/data/profile.dart';
import 'package:reaprime/src/models/device/impl/mock_de1/mock_de1.dart';
import 'package:reaprime/src/models/device/impl/mock_scale/mock_scale.dart';
import 'package:reaprime/src/models/device/machine.dart';

import '../../helpers/fake_time.dart';

Profile _pourProfile() => Profile(
  version: '1.0',
  title: 'pour',
  notes: '',
  author: 'test',
  beverageType: BeverageType.espresso,
  targetVolumeCountStart: 0,
  tankTemperature: 92.0,
  steps: [
    ProfileStepFlow(
      name: 'pour',
      flow: 4.0,
      seconds: 30,
      temperature: 92,
      sensor: TemperatureSensor.coffee,
      transition: TransitionType.fast,
      volume: 0,
    ),
  ],
);

void main() {
  group('MockScale weight synthesis', () {
    late FakeTime time;

    setUp(() {
      time = FakeTime();
    });

    tearDown(() {
      expect(time.pendingTimers, isEmpty);
    });

    test('reads a flat ~0 when no machine is attached', () async {
      final scale = time.run(MockScale.new);
      addTearDown(scale.simulateDisconnect);
      final pendingSamples = scale.currentSnapshot
          .take(6)
          .toList()
          .timeout(const Duration(seconds: 5));
      await time.elapse(const Duration(milliseconds: 1200));
      final samples = await pendingSamples;
      for (final s in samples) {
        expect(
          s.weight.abs(),
          lessThan(0.2),
          reason:
              'an empty scale reads ~0 with sensor jitter, '
              'not an ever-climbing random walk',
        );
      }
      scale.simulateDisconnect();
    });

    test('idle reading is rock steady, not flickering', () async {
      final scale = time.run(MockScale.new);
      addTearDown(scale.simulateDisconnect);
      final pendingSamples = scale.currentSnapshot
          .take(8)
          .toList()
          .timeout(const Duration(seconds: 5));
      await time.elapse(const Duration(milliseconds: 1600));
      final samples = await pendingSamples;
      final first = samples.first.weight;
      for (final s in samples) {
        expect(
          s.weight,
          equals(first),
          reason: 'reading must hold perfectly still at rest',
        );
      }
      expect(first.abs(), lessThan(0.1));
      scale.simulateDisconnect();
    });

    test(
      'weight follows the simulated shot when a machine is attached',
      () async {
        final de1 = time.run(MockDe1.new);
        final scale = time.run(MockScale.new);
        addTearDown(de1.disconnect);
        addTearDown(scale.simulateDisconnect);
        scale.attachMachine(de1);

        await time.run(de1.onConnect);
        await de1.setProfile(_pourProfile());

        final pendingIdle = scale.currentSnapshot.first.timeout(
          const Duration(seconds: 2),
        );
        await time.elapse(const Duration(milliseconds: 200));
        final idle = await pendingIdle;
        expect(idle.weight.abs(), lessThan(0.2));

        await de1.requestState(MachineState.espresso);
        await time.elapse(const Duration(seconds: 4));
        await de1.requestState(MachineState.idle);

        final pendingPoured = scale.currentSnapshot.first.timeout(
          const Duration(seconds: 2),
        );
        await time.elapse(const Duration(milliseconds: 200));
        final poured = await pendingPoured;
        expect(
          poured.weight,
          greaterThan(1.0),
          reason: 'simulated flow must land in the cup',
        );

        await scale.tare();
        final pendingTared = scale.currentSnapshot.first.timeout(
          const Duration(seconds: 2),
        );
        await time.elapse(const Duration(milliseconds: 200));
        final tared = await pendingTared;
        expect(tared.weight.abs(), lessThan(0.2));

        scale.simulateDisconnect();
        await de1.disconnect();
      },
    );

    test('detachMachine stops the weight from following the machine', () async {
      final de1 = time.run(MockDe1.new);
      final scale = time.run(MockScale.new);
      addTearDown(de1.disconnect);
      addTearDown(scale.simulateDisconnect);
      scale.attachMachine(de1);
      scale.detachMachine();

      await time.run(de1.onConnect);
      await de1.setProfile(_pourProfile());
      await de1.requestState(MachineState.espresso);
      await time.elapse(const Duration(seconds: 2));
      await de1.requestState(MachineState.idle);

      final pendingSnapshot = scale.currentSnapshot.first.timeout(
        const Duration(seconds: 2),
      );
      await time.elapse(const Duration(milliseconds: 200));
      final snapshot = await pendingSnapshot;
      expect(snapshot.weight.abs(), lessThan(0.2));

      scale.simulateDisconnect();
      await de1.disconnect();
    });

    test('reconnected scale follows its machine without a rescan', () async {
      final de1 = MockDe1(
        simulationTickInterval: const Duration(milliseconds: 10),
      );
      final scale = MockScale();
      addTearDown(() async {
        await scale.disconnect();
        await de1.disconnect();
      });
      scale.attachMachine(de1);
      await de1.onConnect();
      await scale.onConnect();
      await scale.currentSnapshot.first.timeout(const Duration(seconds: 2));

      await scale.disconnect();
      await scale.onConnect();
      await de1.requestState(MachineState.hotWater);

      final poured = await scale.currentSnapshot
          .firstWhere((snapshot) => snapshot.weight > 1.0)
          .timeout(const Duration(seconds: 3));
      expect(poured.weight, greaterThan(1.0));
    });
  });
}
