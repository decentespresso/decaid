import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/data/profile.dart';
import 'package:reaprime/src/models/device/impl/mock_de1/mock_de1.dart';
import 'package:reaprime/src/models/device/machine.dart';

Profile _flowProfile({StepLimiter? limiter}) {
  return Profile(
    version: '1.0',
    title: 'flow-test',
    notes: '',
    author: 'test',
    beverageType: BeverageType.espresso,
    targetVolumeCountStart: 0,
    tankTemperature: 94.0,
    steps: [
      ProfileStepFlow(
        name: 'pour',
        flow: 3.0,
        limiter: limiter,
        seconds: 5,
        temperature: 94,
        sensor: TemperatureSensor.coffee,
        transition: TransitionType.fast,
        volume: 0,
      ),
    ],
  );
}

Profile _pressureProfile({StepLimiter? limiter}) {
  return Profile(
    version: '1.0',
    title: 'pressure-test',
    notes: '',
    author: 'test',
    beverageType: BeverageType.espresso,
    targetVolumeCountStart: 0,
    tankTemperature: 94.0,
    steps: [
      ProfileStepPressure(
        name: 'pour',
        pressure: 6.0,
        limiter: limiter,
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
  group('MockDe1 flow→pressure coupling', () {
    late MockDe1 machine;

    setUp(() async {
      machine = MockDe1();
      await machine.onConnect();
    });

    tearDown(() async {
      await machine.onDisconnect();
    });

    test('flow-step: reported flow approaches target over time', () async {
      await machine.setProfile(_flowProfile());
      await machine.requestState(MachineState.espresso);

      // Wait past preparingForShot, collect snapshots
      await Future.delayed(const Duration(milliseconds: 600));
      final snapshots = await machine.currentSnapshot
          .take(10)
          .toList()
          .timeout(const Duration(seconds: 3));

      // First few should be below target, last few closer to 3.0
      final firstFlow = snapshots.first.flow;
      final lastFlow = snapshots.last.flow;

      expect(
        lastFlow,
        greaterThan(firstFlow),
        reason: 'Flow should increase toward target',
      );
      expect(
        lastFlow,
        lessThanOrEqualTo(3.0),
        reason: 'Flow should not exceed target',
      );
    });

    test('flow-step: pressure builds as flow increases (coupling)', () async {
      await machine.setProfile(_flowProfile());
      await machine.requestState(MachineState.espresso);

      await Future.delayed(const Duration(milliseconds: 600));
      final snapshots = await machine.currentSnapshot
          .take(20)
          .toList()
          .timeout(const Duration(seconds: 4));

      // Pressure and flow should both be rising
      final pressures = snapshots.map((s) => s.pressure).toList();
      final flows = snapshots.map((s) => s.flow).toList();

      // Both should show upward trend
      expect(
        pressures.last,
        greaterThan(pressures.first),
        reason: 'Pressure should build as flow pushes against puck',
      );
      expect(
        flows.last,
        greaterThan(flows.first),
        reason: 'Flow should rise toward target',
      );
    });

    test('pressure-step: does not exceed pressure target', () async {
      await machine.setProfile(_pressureProfile());
      await machine.requestState(MachineState.espresso);

      await Future.delayed(const Duration(milliseconds: 600));
      final snapshots = await machine.currentSnapshot
          .take(30)
          .toList()
          .timeout(const Duration(seconds: 5));

      for (final s in snapshots) {
        expect(
          s.pressure,
          lessThanOrEqualTo(6.5),
          reason: 'Pressure should not significantly exceed step target of 6.0',
        );
      }
    });

    test('pressure-step: targetPressure reflects step target', () async {
      await machine.setProfile(_pressureProfile());
      await machine.requestState(MachineState.espresso);

      await Future.delayed(const Duration(milliseconds: 600));
      final snapshot = await machine.currentSnapshot.first.timeout(
        const Duration(seconds: 2),
      );

      // targetPressure should be set to the pressure step's target
      expect(snapshot.targetPressure, closeTo(6.0, 0.1));
    });

    test('flow-step: targetFlow reflects step target', () async {
      await machine.setProfile(_flowProfile());
      await machine.requestState(MachineState.espresso);

      await Future.delayed(const Duration(milliseconds: 600));
      final snapshot = await machine.currentSnapshot.first.timeout(
        const Duration(seconds: 2),
      );

      expect(snapshot.targetFlow, closeTo(3.0, 0.1));
    });

    test('pressure-step: flow limiter caps flow', () async {
      await machine.setProfile(
        _pressureProfile(limiter: const StepLimiter(value: 1.5, range: 0.5)),
      );
      await machine.requestState(MachineState.espresso);

      await Future.delayed(const Duration(milliseconds: 600));
      final snapshots = await machine.currentSnapshot
          .take(10)
          .toList()
          .timeout(const Duration(seconds: 3));

      expect(
        snapshots.map((snapshot) => snapshot.flow),
        everyElement(lessThanOrEqualTo(1.5)),
      );
    });

    test('flow-step: pressure limiter caps pressure', () async {
      await machine.setProfile(
        _flowProfile(limiter: const StepLimiter(value: 0.15, range: 0.05)),
      );
      await machine.requestState(MachineState.espresso);

      await Future.delayed(const Duration(milliseconds: 600));
      final snapshots = await machine.currentSnapshot
          .take(10)
          .toList()
          .timeout(const Duration(seconds: 3));

      expect(
        snapshots.map((snapshot) => snapshot.pressure),
        everyElement(lessThanOrEqualTo(0.15)),
      );
    });
  });
}
