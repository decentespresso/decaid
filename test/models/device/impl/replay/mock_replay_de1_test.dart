import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/data/profile.dart';
import 'package:reaprime/src/models/device/impl/replay/mock_replay_de1.dart';
import 'package:reaprime/src/models/device/led_strip.dart';
import 'package:reaprime/src/models/device/machine.dart';
import 'package:reaprime/src/services/simulated_shot_library.dart';

Profile _profile(String title) => Profile(
  version: '2',
  title: title,
  notes: '',
  author: '',
  beverageType: BeverageType.espresso,
  steps: const [],
  targetVolumeCountStart: 0,
  tankTemperature: 0,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('MockReplayDe1', () {
    late SimulatedShotLibrary library;

    setUp(() async {
      library = SimulatedShotLibrary();
      await library.ensureLoaded();
    });

    test('replays the shot recorded with the selected profile', () async {
      final expected = library.forProfileTitle('Adaptive v2')!;
      final recordedPressures = expected.measurements
          .map((m) => m.machine.pressure)
          .toSet();

      final machine = MockReplayDe1(library: library);
      await machine.setProfile(_profile('Adaptive v2'));
      await machine.onConnect();
      await machine.requestState(MachineState.espresso);

      final snapshots = await machine.currentSnapshot
          .where((s) => s.state.state == MachineState.espresso)
          .take(15)
          .toList()
          .timeout(const Duration(seconds: 5));
      await machine.disconnect();

      expect(snapshots, isNotEmpty);
      for (final s in snapshots) {
        expect(
          recordedPressures.contains(s.pressure),
          isTrue,
          reason: '${s.pressure} is not from the Adaptive v2 recording',
        );
      }
    });

    test(
      'replay starts from the beginning of the recording after prep',
      () async {
        final m = library.forProfileTitle('Adaptive v2')!.measurements;
        final recordingStart = {m[0].machine.pressure, m[1].machine.pressure};

        final machine = MockReplayDe1(library: library);
        await machine.setProfile(_profile('Adaptive v2'));
        await machine.onConnect();
        await machine.requestState(MachineState.espresso);

        final firstPour = await machine.currentSnapshot
            .firstWhere((s) => s.state.substate == MachineSubstate.pouring)
            .timeout(const Duration(seconds: 3));
        await machine.disconnect();

        expect(
          recordingStart.contains(firstPour.pressure),
          isTrue,
          reason:
              'first post-prep sample should be the recording start, '
              'got ${firstPour.pressure}',
        );
      },
    );

    test('falls back to a generic shot for an unmatched profile', () async {
      final machine = MockReplayDe1(library: library);
      await machine.setProfile(_profile('No Such Profile 999'));
      await machine.onConnect();
      await machine.requestState(MachineState.espresso);

      final snapshots = await machine.currentSnapshot
          .where((s) => s.state.state == MachineState.espresso)
          .take(5)
          .toList()
          .timeout(const Duration(seconds: 5));
      await machine.disconnect();

      expect(
        snapshots,
        isNotEmpty,
        reason: 'fallback shot should still replay',
      );
    });

    test('the integrated scale reports the recorded weight', () async {
      final expected = library.forProfileTitle('Adaptive v2')!;
      final recordedWeights = expected.measurements
          .map((m) => m.scale?.weight ?? 0.0)
          .toSet();

      final machine = MockReplayDe1(library: library);
      await machine.setProfile(_profile('Adaptive v2'));
      await machine.onConnect();
      await machine.requestState(MachineState.espresso);

      final weights = await machine.weightSnapshot
          .map((s) => s.weight)
          .take(12)
          .toList()
          .timeout(const Duration(seconds: 5));
      await machine.disconnect();

      for (final w in weights) {
        expect(
          recordedWeights.any((r) => (r - w).abs() < 1e-6),
          isTrue,
          reason: '${w}g is not a recorded weight sample',
        );
      }
    });

    test('autonomous stop-at-weight stops the shot at target', () {
      // milky-drinks reaches the target early, keeping the test short.
      fakeAsync((async) {
        final machine = MockReplayDe1(library: library);
        machine.setProfile(_profile('Flow profile for milky drinks'));
        machine.onConnect();
        machine.setStopAtWeightTarget(3);
        machine.requestState(MachineState.espresso);

        var idleSeen = false;
        machine.currentSnapshot.listen((s) {
          if (s.state.state == MachineState.idle) idleSeen = true;
        });

        async.elapse(const Duration(seconds: 20));
        async.flushMicrotasks();

        expect(idleSeen, isTrue, reason: 'shot should stop at the 3g target');

        machine.disconnect();
        async.flushMicrotasks();
      });
    });

    test('debug selection forces a specific recording', () async {
      final forced = library.byId('sim-best_practice')!;
      final forcedPressures = forced.measurements
          .map((m) => m.machine.pressure)
          .toSet();

      final machine = MockReplayDe1(library: library);
      expect(machine.availableShots, isNotEmpty);
      expect(machine.selectShot('no-such-id'), isFalse);
      expect(machine.selectShot('sim-best_practice'), isTrue);
      expect(machine.selectedShotId, 'sim-best_practice');

      await machine.setProfile(_profile('Londonium'));
      await machine.onConnect();
      await machine.requestState(MachineState.espresso);

      final snapshots = await machine.currentSnapshot
          .where((s) => s.state.state == MachineState.espresso)
          .take(15)
          .toList()
          .timeout(const Duration(seconds: 5));
      await machine.disconnect();

      expect(snapshots, isNotEmpty);
      for (final s in snapshots) {
        expect(
          forcedPressures.contains(s.pressure),
          isTrue,
          reason: '${s.pressure} is not from the forced recording',
        );
      }

      machine.clearSelectedShot();
      expect(machine.selectedShotId, isNull);
    });

    test(
      'skipStep advances the replay frame instead of ending the shot',
      () async {
        final machine = MockReplayDe1(library: library);
        await machine.setProfile(_profile('D-Flow / default'));
        await machine.onConnect();
        await machine.requestState(MachineState.espresso);

        await machine.currentSnapshot
            .firstWhere(
              (s) =>
                  s.state.substate == MachineSubstate.pouring &&
                  s.profileFrame == 0,
            )
            .timeout(const Duration(seconds: 5));
        await machine.requestState(MachineState.skipStep);

        final advanced = await machine.currentSnapshot
            .firstWhere(
              (s) =>
                  s.state.state == MachineState.espresso && s.profileFrame >= 1,
            )
            .timeout(const Duration(seconds: 5));
        await machine.disconnect();

        expect(advanced.profileFrame, greaterThanOrEqualTo(1));
      },
    );

    test('the integrated scale produces weight during hot water', () {
      fakeAsync((async) {
        final machine = MockReplayDe1(library: library);
        machine.onConnect();
        machine.requestState(MachineState.hotWater);

        final weights = <double>[];
        machine.weightSnapshot.listen((s) => weights.add(s.weight));

        async.elapse(const Duration(seconds: 8));
        async.flushMicrotasks();

        expect(
          weights.any((w) => w > 0.5),
          isTrue,
          reason: 'hot water should accumulate integrated-scale weight',
        );

        machine.disconnect();
        async.flushMicrotasks();
      });
    });

    test('autonomous stop-at-weight terminates hot water at target', () {
      fakeAsync((async) {
        final machine = MockReplayDe1(library: library);
        machine.onConnect();
        machine.setStopAtWeightTarget(2);

        var poured = false;
        double lastWeight = 0;
        var stopWeight = 0.0;
        final stopped = Completer<void>();
        final weightSub = machine.weightSnapshot.listen(
          (s) => lastWeight = s.weight,
        );
        final stateSub = machine.currentSnapshot.listen((s) {
          if (s.state.substate == MachineSubstate.pouring) poured = true;
          if (poured &&
              s.state.state == MachineState.idle &&
              !stopped.isCompleted) {
            stopWeight = lastWeight;
            stopped.complete();
          }
        });

        machine.requestState(MachineState.hotWater);
        async.elapse(const Duration(seconds: 15));
        async.flushMicrotasks();

        expect(
          stopped.isCompleted,
          isTrue,
          reason:
              'hot water must run until the integrated scale reaches target',
        );
        expect(
          stopWeight,
          greaterThanOrEqualTo(2),
          reason: 'stop weight must reach the 2g target',
        );

        weightSub.cancel();
        stateSub.cancel();
        machine.disconnect();
        async.flushMicrotasks();
      });
    });

    test('without a target, replay ends at the recording, not the tail', () {
      fakeAsync((async) {
        final machine = MockReplayDe1(library: library);
        machine.setProfile(_profile('Extractamundo Dos!'));
        machine.onConnect();
        machine.requestState(MachineState.espresso);

        var idleSeen = false;
        machine.currentSnapshot.listen((s) {
          if (s.state.state == MachineState.idle) idleSeen = true;
        });

        async.elapse(const Duration(seconds: 10));
        async.flushMicrotasks();
        expect(
          idleSeen,
          isFalse,
          reason: 'must not end before the recording plays',
        );

        async.elapse(const Duration(seconds: 25));
        async.flushMicrotasks();
        expect(
          idleSeen,
          isTrue,
          reason: 'should end near the ~23s recording, not the ~150s tail',
        );

        machine.disconnect();
        async.flushMicrotasks();
      });
    });

    test('setLedStrip quantizes to the firmware spelling', () async {
      final machine = MockReplayDe1(library: library);

      await machine.setLedStrip(
        const LedStripState(
          frontStrip: ZoneLedState(
            sleeping: Color16(0xFFFF, 0x2222, 0x0000),
            awake: Color16(0xFF00, 0xF000, 0x8000),
          ),
          backStrip: ZoneLedState(
            sleeping: Color16(0x3030, 0x2020, 0x1010),
            awake: Color16(0xFFFF, 0xFFFF, 0xFFFF),
          ),
        ),
      );

      final state = await machine.getLedStripState();
      expect(state.frontStrip.sleeping.toJson(), 'FF0022000000');
      expect(state.frontStrip.awake.toJson(), 'FF00F0008000');
      expect(state.backStrip.sleeping.toJson(), '300020001000');
      expect(state.backStrip.awake.toJson(), 'FF00FF00FF00');
    });

    test('steam falls back to synthetic device telemetry', () async {
      final machine = MockReplayDe1(library: library);
      await machine.onConnect();
      await machine.requestState(MachineState.steam);

      final snapshot = await machine.currentSnapshot.first.timeout(
        const Duration(seconds: 3),
      );
      await machine.disconnect();

      expect(snapshot, isNotNull);
    });
  });
}
