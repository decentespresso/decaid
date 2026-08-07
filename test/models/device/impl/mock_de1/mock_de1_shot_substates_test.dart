import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/data/profile.dart';
import 'package:reaprime/src/models/device/impl/mock_de1/mock_de1.dart';
import 'package:reaprime/src/models/device/machine.dart';

Profile _testProfile({
  int targetVolumeCountStart = 1,
  List<ProfileStep>? steps,
}) {
  return Profile(
    version: '1.0',
    title: 'test',
    notes: '',
    author: 'test',
    beverageType: BeverageType.espresso,
    targetVolumeCountStart: targetVolumeCountStart,
    tankTemperature: 94.0,
    steps:
        steps ??
        [
          ProfileStepPressure(
            name: 'preinfuse',
            pressure: 2.0,
            seconds: 2,
            temperature: 92,
            sensor: TemperatureSensor.coffee,
            transition: TransitionType.fast,
            volume: 0,
          ),
          ProfileStepPressure(
            name: 'pour',
            pressure: 9.0,
            seconds: 5,
            temperature: 94,
            sensor: TemperatureSensor.coffee,
            transition: TransitionType.fast,
            volume: 0,
          ),
        ],
  );
}

void main() {
  group('MockDe1 shot substates', () {
    late MockDe1 machine;

    setUp(() async {
      machine = MockDe1();
      await machine.onConnect();
    });

    tearDown(() async {
      await machine.onDisconnect();
    });

    test('emits preparingForShot at shot start', () async {
      await machine.setProfile(_testProfile());
      await machine.requestState(MachineState.espresso);

      final snapshot = await machine.currentSnapshot.first.timeout(
        const Duration(seconds: 2),
      );

      expect(snapshot.state.substate, MachineSubstate.preparingForShot);
    });

    test(
      'emits preinfusion when profileFrame < targetVolumeCountStart',
      () async {
        final profile = _testProfile(
          targetVolumeCountStart: 2,
          steps: [
            ProfileStepPressure(
              name: 'fill',
              pressure: 2.0,
              seconds: 1,
              temperature: 92,
              sensor: TemperatureSensor.coffee,
              transition: TransitionType.fast,
              volume: 0,
            ),
            ProfileStepPressure(
              name: 'soak',
              pressure: 2.0,
              seconds: 1,
              temperature: 92,
              sensor: TemperatureSensor.coffee,
              transition: TransitionType.fast,
              volume: 0,
            ),
            ProfileStepPressure(
              name: 'pour',
              pressure: 9.0,
              seconds: 3,
              temperature: 94,
              sensor: TemperatureSensor.coffee,
              transition: TransitionType.fast,
              volume: 0,
            ),
          ],
        );

        await machine.setProfile(profile);
        await machine.requestState(MachineState.espresso);

        final completer = Completer<MachineSubstate>();
        final sub = machine.currentSnapshot.listen((s) {
          final ss = s.state.substate;
          if (ss == MachineSubstate.preinfusion ||
              ss == MachineSubstate.pouring) {
            if (!completer.isCompleted) completer.complete(ss);
          }
        });

        final firstNonPrep = await completer.future.timeout(
          const Duration(seconds: 3),
        );
        await sub.cancel();

        expect(firstNonPrep, MachineSubstate.preinfusion);
      },
    );

    test('emits pouring when profileFrame >= targetVolumeCountStart', () async {
      final profile = _testProfile(targetVolumeCountStart: 1);

      await machine.setProfile(profile);
      await machine.requestState(MachineState.espresso);

      final completer = Completer<MachineSubstate>();
      final sub = machine.currentSnapshot.listen((s) {
        if (s.state.substate == MachineSubstate.pouring) {
          if (!completer.isCompleted) completer.complete(s.state.substate);
        }
      });

      final substate = await completer.future.timeout(
        const Duration(seconds: 3),
      );
      await sub.cancel();

      expect(substate, MachineSubstate.pouring);
    });

    test('emits pouringDone and idle at shot end', () async {
      final profile = _testProfile(
        targetVolumeCountStart: 0,
        steps: [
          ProfileStepPressure(
            name: 'quick',
            pressure: 9.0,
            seconds: 1,
            temperature: 94,
            sensor: TemperatureSensor.coffee,
            transition: TransitionType.fast,
            volume: 0,
          ),
        ],
      );

      await machine.setProfile(profile);
      await machine.requestState(MachineState.espresso);

      final snapshots = await machine.currentSnapshot
          .takeWhile((s) => s.state.state != MachineState.idle)
          .toList()
          .timeout(const Duration(seconds: 5));

      final hasPouringDone = snapshots.any(
        (s) => s.state.substate == MachineSubstate.pouringDone,
      );
      expect(
        hasPouringDone,
        isTrue,
        reason: 'Should emit pouringDone before idle',
      );

      final finalSnapshot = await machine.currentSnapshot.first.timeout(
        const Duration(seconds: 2),
      );
      expect(finalSnapshot.state.state, MachineState.idle);
    });

    test('profileFrame in snapshot matches current step index', () async {
      final profile = _testProfile(
        targetVolumeCountStart: 1,
        steps: [
          ProfileStepPressure(
            name: 'step0',
            pressure: 2.0,
            seconds: 1,
            temperature: 92,
            sensor: TemperatureSensor.coffee,
            transition: TransitionType.fast,
            volume: 0,
          ),
          ProfileStepPressure(
            name: 'step1',
            pressure: 9.0,
            seconds: 3,
            temperature: 94,
            sensor: TemperatureSensor.coffee,
            transition: TransitionType.fast,
            volume: 0,
          ),
        ],
      );

      await machine.setProfile(profile);
      await machine.requestState(MachineState.espresso);

      final completer = Completer<int>();
      final sub = machine.currentSnapshot.listen((s) {
        if (s.state.substate == MachineSubstate.pouring) {
          if (!completer.isCompleted) completer.complete(s.profileFrame);
        }
      });

      final frame = await completer.future.timeout(const Duration(seconds: 3));
      await sub.cancel();

      expect(frame, greaterThanOrEqualTo(1));
    });
  });
}
