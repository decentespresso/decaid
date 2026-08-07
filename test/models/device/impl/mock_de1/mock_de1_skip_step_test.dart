import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/data/profile.dart';
import 'package:reaprime/src/models/device/impl/mock_de1/mock_de1.dart';
import 'package:reaprime/src/models/device/machine.dart';

Profile _testProfile() {
  return Profile(
    version: '1.0',
    title: 'test',
    notes: '',
    author: 'test',
    beverageType: BeverageType.espresso,
    targetVolumeCountStart: 0,
    tankTemperature: 94.0,
    steps: [
      ProfileStepPressure(
        name: 'step0',
        pressure: 3.0,
        seconds: 5,
        temperature: 92,
        sensor: TemperatureSensor.coffee,
        transition: TransitionType.fast,
        volume: 0,
      ),
      ProfileStepPressure(
        name: 'step1',
        pressure: 9.0,
        seconds: 5,
        temperature: 94,
        sensor: TemperatureSensor.coffee,
        transition: TransitionType.fast,
        volume: 0,
      ),
      ProfileStepPressure(
        name: 'step2',
        pressure: 6.0,
        seconds: 5,
        temperature: 93,
        sensor: TemperatureSensor.coffee,
        transition: TransitionType.fast,
        volume: 0,
      ),
    ],
  );
}

void main() {
  group('MockDe1 skipStep', () {
    late MockDe1 machine;

    setUp(() async {
      machine = MockDe1();
      await machine.onConnect();
    });

    tearDown(() async {
      await machine.onDisconnect();
    });

    test('skipStep advances profileFrame during espresso', () async {
      await machine.setProfile(_testProfile());
      await machine.requestState(MachineState.espresso);

      await machine.currentSnapshot
          .firstWhere((s) => s.state.substate == MachineSubstate.pouring)
          .timeout(const Duration(seconds: 2));

      final before = await machine.currentSnapshot.first.timeout(
        const Duration(seconds: 1),
      );

      await machine.requestState(MachineState.skipStep);

      await Future.delayed(const Duration(milliseconds: 200));

      final after = await machine.currentSnapshot.first.timeout(
        const Duration(seconds: 1),
      );

      expect(
        after.profileFrame,
        greaterThan(before.profileFrame),
        reason: 'skipStep should advance to next profile step',
      );
    });

    test('skipStep does not end the shot', () async {
      await machine.setProfile(_testProfile());
      await machine.requestState(MachineState.espresso);

      await machine.currentSnapshot
          .firstWhere((s) => s.state.substate == MachineSubstate.pouring)
          .timeout(const Duration(seconds: 2));

      await machine.requestState(MachineState.skipStep);

      await Future.delayed(const Duration(milliseconds: 300));
      final snapshot = await machine.currentSnapshot.first.timeout(
        const Duration(seconds: 1),
      );

      expect(
        snapshot.state.state,
        MachineState.espresso,
        reason: 'skipStep should not kill the shot',
      );
    });

    test('skipStep resets step elapsed time', () async {
      await machine.setProfile(_testProfile());
      await machine.requestState(MachineState.espresso);

      await machine.currentSnapshot
          .firstWhere((s) => s.state.substate == MachineSubstate.pouring)
          .timeout(const Duration(seconds: 2));

      await machine.requestState(MachineState.skipStep);

      await Future.delayed(const Duration(milliseconds: 500));
      final snapshot = await machine.currentSnapshot.first.timeout(
        const Duration(seconds: 1),
      );

      expect(snapshot.state.state, MachineState.espresso);
    });

    test('skipStep at last step triggers pouringDone → idle', () async {
      final profile = Profile(
        version: '1.0',
        title: 'test',
        notes: '',
        author: 'test',
        beverageType: BeverageType.espresso,
        targetVolumeCountStart: 0,
        tankTemperature: 94.0,
        steps: [
          ProfileStepPressure(
            name: 'step0',
            pressure: 3.0,
            seconds: 10,
            temperature: 92,
            sensor: TemperatureSensor.coffee,
            transition: TransitionType.fast,
            volume: 0,
          ),
          ProfileStepPressure(
            name: 'step1',
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

      await machine.currentSnapshot
          .firstWhere((s) => s.state.substate == MachineSubstate.pouring)
          .timeout(const Duration(seconds: 2));

      await machine.requestState(MachineState.skipStep);

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
        reason: 'Should emit pouringDone when last step completes after skip',
      );

      final finalSnapshot = await machine.currentSnapshot.first.timeout(
        const Duration(seconds: 2),
      );
      expect(
        finalSnapshot.state.state,
        MachineState.idle,
        reason: 'Shot should end after last step completes',
      );
    });
  });
}
