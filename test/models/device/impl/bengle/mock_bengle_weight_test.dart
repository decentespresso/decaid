import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/data/profile.dart';
import 'package:reaprime/src/models/device/impl/bengle/mock_bengle.dart';
import 'package:reaprime/src/models/device/machine.dart';

Profile _profileWithPreinfusion() {
  return Profile(
    version: '1.0',
    title: 'test',
    notes: '',
    author: 'test',
    beverageType: BeverageType.espresso,
    targetVolumeCountStart: 2, // first 2 steps are preinfusion
    tankTemperature: 94.0,
    steps: [
      ProfileStepPressure(
        name: 'fill',
        pressure: 2.0,
        seconds: 2,
        temperature: 92,
        sensor: TemperatureSensor.coffee,
        transition: TransitionType.fast,
        volume: 0,
      ),
      ProfileStepPressure(
        name: 'soak',
        pressure: 2.0,
        seconds: 2,
        temperature: 92,
        sensor: TemperatureSensor.coffee,
        transition: TransitionType.fast,
        volume: 0,
      ),
      ProfileStepFlow(
        name: 'pour',
        flow: 3.0,
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
  group('MockBengle weight accumulation', () {
    late MockBengle bengle;

    setUp(() async {
      bengle = MockBengle();
      await bengle.onConnect();
    });

    tearDown(() async {
      await bengle.onDisconnect();
    });

    test('weight stays near zero during preinfusion frames', () async {
      await bengle.setProfile(_profileWithPreinfusion());
      await bengle.requestState(MachineState.espresso);

      await Future.delayed(const Duration(milliseconds: 600));
      final snapshots = await bengle.weightSnapshot
          .take(15)
          .toList()
          .timeout(const Duration(seconds: 3));

      // 15 ticks @ 100ms = 1.5s. Preinfusion steps are 2+2=4s long.
      // Weight should be near zero throughout.
      for (final s in snapshots) {
        expect(
          s.weight.abs(),
          lessThan(1.0),
          reason: 'Weight should stay ~0 during preinfusion (step 0-1)',
        );
      }
    });

    test('weight climbs after targetVolumeCountStart', () async {
      final profile = Profile(
        version: '1.0',
        title: 'test',
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
            seconds: 5,
            temperature: 94,
            sensor: TemperatureSensor.coffee,
            transition: TransitionType.fast,
            volume: 0,
          ),
        ],
      );

      await bengle.setProfile(profile);
      await bengle.requestState(MachineState.espresso);

      await Future.delayed(const Duration(milliseconds: 1700));

      final snapshots = await bengle.weightSnapshot
          .take(20)
          .toList()
          .timeout(const Duration(seconds: 4));

      final firstWeight = snapshots.first.weight;
      final lastWeight = snapshots.last.weight;

      expect(
        lastWeight,
        greaterThan(firstWeight),
        reason: 'Weight should climb during extraction',
      );
      expect(
        lastWeight,
        greaterThan(0.5),
        reason: 'Weight should accumulate meaningfully',
      );
    });
  });
}
