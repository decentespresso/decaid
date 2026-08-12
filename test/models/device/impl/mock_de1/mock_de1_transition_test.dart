import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/data/profile.dart';
import 'package:reaprime/src/models/device/impl/mock_de1/mock_de1.dart';
import 'package:reaprime/src/models/device/machine.dart';

void main() {
  group('MockDe1 transition shaping', () {
    late MockDe1 machine;

    setUp(() async {
      machine = MockDe1(
        simulationTickInterval: const Duration(milliseconds: 10),
      );
      await machine.onConnect();
    });

    tearDown(() async {
      await machine.onDisconnect();
    });

    test('fast transition: target jumps to step value immediately', () async {
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
            name: 'low',
            flow: 2.0,
            seconds: 1,
            temperature: 94,
            sensor: TemperatureSensor.coffee,
            transition: TransitionType.fast,
            volume: 0,
          ),
          ProfileStepFlow(
            name: 'high',
            flow: 4.0,
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

      await Future.delayed(const Duration(milliseconds: 180));

      final snapshots = await machine.currentSnapshot
          .take(3)
          .toList()
          .timeout(const Duration(seconds: 2));

      for (final s in snapshots) {
        expect(
          s.targetFlow,
          closeTo(4.0, 0.1),
          reason: 'Fast transition should set targetFlow=4.0 immediately',
        );
      }
      expect(
        snapshots.last.flow,
        greaterThan(2.5),
        reason: 'Reported flow should be converging toward 4.0',
      );
    });

    test('smooth transition: target interpolates over step duration', () async {
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
            name: 'low',
            pressure: 2.0,
            seconds: 2,
            temperature: 94,
            sensor: TemperatureSensor.coffee,
            transition: TransitionType.fast,
            volume: 0,
          ),
          ProfileStepPressure(
            name: 'high',
            pressure: 8.0,
            seconds: 6,
            temperature: 94,
            sensor: TemperatureSensor.coffee,
            transition: TransitionType.smooth,
            volume: 0,
          ),
        ],
      );

      await machine.setProfile(profile);
      await machine.requestState(MachineState.espresso);

      await Future.delayed(const Duration(milliseconds: 370));

      final snapshots = await machine.currentSnapshot
          .take(20)
          .toList()
          .timeout(const Duration(seconds: 4));

      final first = snapshots.first.targetPressure;
      final last = snapshots.last.targetPressure;

      expect(
        last,
        greaterThan(first),
        reason: 'targetPressure should rise over a smooth transition',
      );
      expect(
        first,
        greaterThan(2.0),
        reason: 'Should start above step0 target of 2.0',
      );
      expect(
        last,
        greaterThan(3.5),
        reason: 'Should be rising toward 8.0 after ~1-3s into step',
      );
    });
  });

  tearDownAll(() {});
}
