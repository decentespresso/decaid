import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/data/profile.dart';
import 'package:reaprime/src/models/device/impl/bengle/mock_bengle.dart';
import 'package:reaprime/src/models/device/machine.dart';

/// SAW (stop-at-weight) profile: step0 preinfusion, step1 pours until weight hits exit.
Profile _sawProfile() {
  return Profile(
    version: '1.0',
    title: 'saw-test',
    notes: '',
    author: 'test',
    beverageType: BeverageType.espresso,
    targetVolumeCountStart: 1,
    tankTemperature: 94.0,
    steps: [
      ProfileStepPressure(
        name: 'preinfuse',
        pressure: 2.0,
        seconds: 1,
        temperature: 92,
        sensor: TemperatureSensor.coffee,
        transition: TransitionType.fast,
        volume: 0,
      ),
      ProfileStepFlow(
        name: 'pour',
        flow: 3.0,
        seconds: 30,
        temperature: 94,
        sensor: TemperatureSensor.coffee,
        transition: TransitionType.fast,
        volume: 0,
        weight: 4.0,
      ),
    ],
  );
}

void main() {
  group('MockBengle SAW integration', () {
    late MockBengle bengle;

    setUp(() async {
      bengle = MockBengle();
      await bengle.onConnect();
    });

    tearDown(() async {
      await bengle.onDisconnect();
    });

    test('weight accumulation + skipStep works end-to-end', () async {
      await bengle.setProfile(_sawProfile());
      await bengle.requestState(MachineState.espresso);

      await Future.delayed(const Duration(milliseconds: 1700));

      // Collect snapshots. When weight passes 4g, call skipStep (simulating
      // what ShotSequencer does).
      final completer = Completer<void>();
      var skipped = false;
      final snapshots = <String>[];

      final machineSub = bengle.currentSnapshot.listen((m) {
        if (m.state.state != MachineState.espresso) return;
        snapshots.add(
          'machine frame=${m.profileFrame} '
          'substate=${m.state.substate} flow=${m.flow.toStringAsFixed(2)} '
          'pressure=${m.pressure.toStringAsFixed(2)}',
        );
      });

      final scaleSub = bengle.weightSnapshot.listen((w) async {
        snapshots.add('scale weight=${w.weight.toStringAsFixed(2)}');
        if (!skipped && w.weight >= 4.0) {
          skipped = true;
          await bengle.requestState(MachineState.skipStep);
          await bengle.requestState(MachineState.idle);
          completer.complete();
        }
      });

      await completer.future.timeout(const Duration(seconds: 10));
      await machineSub.cancel();
      await scaleSub.cancel();

      // Verify weight reached 4g before skip
      expect(skipped, isTrue, reason: 'Weight should reach 4g exit condition');

      // Verify we didn't crash — the shot ended cleanly.
      final finalSnapshot = await bengle.currentSnapshot.first.timeout(
        const Duration(seconds: 2),
      );
      expect(
        finalSnapshot.state.state,
        anyOf(MachineState.idle, MachineState.espresso),
      );
    });

    test('weight does not accumulate before targetVolumeCountStart', () async {
      await bengle.setProfile(_sawProfile());
      await bengle.requestState(MachineState.espresso);

      // Sample entirely within preinfusion (step0 is 1s; prep is the first
      // ~0.5s). Weight is gated on profileFrame >= targetVolumeCountStart, so it
      // must read ~0 for every preinfusion sample. Keep the window under 1s —
      // sampling past the pour boundary would legitimately catch early extraction.
      await Future.delayed(const Duration(milliseconds: 400));

      final weights = await bengle.weightSnapshot
          .take(3)
          .toList()
          .timeout(const Duration(seconds: 2));

      for (final w in weights) {
        expect(
          w.weight.abs(),
          lessThan(0.5),
          reason: 'Weight should be ~0 during preinfusion',
        );
      }
    });

    test(
      'skipStep followed by shot end produces correct substate sequence',
      () async {
        final profile = Profile(
          version: '1.0',
          title: 'test',
          notes: '',
          author: 'test',
          beverageType: BeverageType.espresso,
          targetVolumeCountStart: 0,
          tankTemperature: 94.0,
          steps: [
            ProfileStepFlow(
              name: 'step0',
              flow: 3.0,
              seconds: 10,
              temperature: 94,
              sensor: TemperatureSensor.coffee,
              transition: TransitionType.fast,
              volume: 0,
              weight: 1.0,
            ),
            ProfileStepFlow(
              name: 'step1',
              flow: 1.0,
              seconds: 1,
              temperature: 94,
              sensor: TemperatureSensor.coffee,
              transition: TransitionType.fast,
              volume: 0,
            ),
          ],
        );

        await bengle.setProfile(profile);
        await bengle.requestState(MachineState.espresso);

        await Future.delayed(const Duration(milliseconds: 700));

        await bengle.requestState(MachineState.skipStep);

        final states = await bengle.currentSnapshot
            .takeWhile((s) => s.state.state != MachineState.idle)
            .map((s) => '${s.state.state}/${s.state.substate}')
            .toList()
            .timeout(const Duration(seconds: 5));

        expect(
          states.contains('MachineState.espresso/MachineSubstate.pouringDone'),
          isTrue,
          reason: 'Should emit pouringDone before idle',
        );
      },
    );
  });
}
