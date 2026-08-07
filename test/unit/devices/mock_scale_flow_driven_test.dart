import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/data/profile.dart';
import 'package:reaprime/src/models/device/impl/mock_de1/mock_de1.dart';
import 'package:reaprime/src/models/device/impl/mock_scale/mock_scale.dart';
import 'package:reaprime/src/models/device/machine.dart';

// Single pouring step counting weight from frame 0, so extraction starts as
// soon as the simulated shot does.
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
    test('reads a flat ~0 when no machine is attached', () async {
      final scale = MockScale();
      final samples = await scale.currentSnapshot
          .take(6)
          .toList()
          .timeout(const Duration(seconds: 5));
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
      // Real scale firmware stability-filters its output: at rest the
      // reported weight locks to one value instead of broadcasting raw
      // load-cell noise. Skins render the stream verbatim, so a flickering
      // idle reading (0.0 / -0.0) is a simulator bug, not a skin bug.
      final scale = MockScale();
      final samples = await scale.currentSnapshot
          .take(8)
          .toList()
          .timeout(const Duration(seconds: 5));
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
        final de1 = MockDe1();
        final scale = MockScale();
        scale.attachMachine(de1);

        await de1.onConnect();
        await de1.setProfile(_pourProfile());

        // Before the shot: flat zero.
        final idle = await scale.currentSnapshot.first.timeout(
          const Duration(seconds: 2),
        );
        expect(idle.weight.abs(), lessThan(0.2));

        await de1.requestState(MachineState.espresso);
        await Future.delayed(const Duration(seconds: 4));
        await de1.requestState(MachineState.idle);

        final poured = await scale.currentSnapshot.first.timeout(
          const Duration(seconds: 2),
        );
        expect(
          poured.weight,
          greaterThan(1.0),
          reason: 'simulated flow must land in the cup',
        );

        await scale.tare();
        final tared = await scale.currentSnapshot.first.timeout(
          const Duration(seconds: 2),
        );
        expect(tared.weight.abs(), lessThan(0.2));

        scale.simulateDisconnect();
        await de1.disconnect();
      },
    );

    test('detachMachine stops the weight from following the machine', () async {
      final de1 = MockDe1();
      final scale = MockScale();
      scale.attachMachine(de1);
      scale.detachMachine();

      await de1.onConnect();
      await de1.setProfile(_pourProfile());
      await de1.requestState(MachineState.espresso);
      await Future.delayed(const Duration(seconds: 2));
      await de1.requestState(MachineState.idle);

      final snapshot = await scale.currentSnapshot.first.timeout(
        const Duration(seconds: 2),
      );
      expect(snapshot.weight.abs(), lessThan(0.2));

      scale.simulateDisconnect();
      await de1.disconnect();
    });
  });
}
