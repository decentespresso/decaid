import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/data/profile.dart';
import 'package:reaprime/src/models/device/impl/mock_de1/mock_de1.dart';
import 'package:reaprime/src/models/device/machine.dart';

Profile _gentleAndSweet() => Profile(
  version: '2',
  title: 'Gentle and sweet',
  notes: '',
  author: 'test',
  beverageType: BeverageType.espresso,
  targetVolumeCountStart: 2,
  tankTemperature: 88.0,
  targetWeight: 40,
  targetVolume: 100,
  steps: [
    ProfileStepFlow(
      name: 'preinfusion temp boost',
      flow: 8,
      seconds: 2,
      temperature: 88,
      sensor: TemperatureSensor.coffee,
      transition: TransitionType.fast,
      volume: 0,
    ),
    ProfileStepFlow(
      name: 'preinfusion',
      flow: 8,
      seconds: 18,
      temperature: 88,
      sensor: TemperatureSensor.coffee,
      transition: TransitionType.fast,
      volume: 0,
      exit: const StepExitCondition(
        type: ExitType.pressure,
        condition: ExitCondition.over,
        value: 4,
      ),
    ),
    ProfileStepPressure(
      name: 'forced rise without limit',
      pressure: 6,
      seconds: 3,
      temperature: 88,
      sensor: TemperatureSensor.coffee,
      transition: TransitionType.fast,
      volume: 0,
    ),
    ProfileStepPressure(
      name: 'rise and hold',
      pressure: 6,
      seconds: 13,
      temperature: 88,
      sensor: TemperatureSensor.coffee,
      transition: TransitionType.smooth,
      volume: 0,
    ),
    ProfileStepPressure(
      name: 'decline',
      pressure: 4,
      seconds: 30,
      temperature: 88,
      sensor: TemperatureSensor.coffee,
      transition: TransitionType.smooth,
      volume: 0,
    ),
  ],
);

void main() {
  test('simulated shot curves resemble a real pull', () async {
    final machine = MockDe1();
    await machine.onConnect();
    await machine.setProfile(_gentleAndSweet());

    final samples = <MachineSnapshot>[];
    final sub = machine.currentSnapshot.listen(samples.add);

    await machine.requestState(MachineState.espresso);
    await Future.delayed(const Duration(milliseconds: 9000));
    await sub.cancel();
    await machine.onDisconnect();

    final pour = samples
        .where((s) => s.state.substate == MachineSubstate.pouring)
        .toList();
    final preinf = samples
        .where((s) => s.state.substate == MachineSubstate.preinfusion)
        .toList();
    final maxPressure = samples
        .map((s) => s.pressure)
        .reduce((a, b) => a > b ? a : b);
    final minGroupTemp = samples
        .map((s) => s.groupTemperature)
        .reduce((a, b) => a < b ? a : b);

    expect(
      maxPressure,
      lessThan(7.5),
      reason: 'pressure should hold at the ceiling, not spike',
    );

    expect(minGroupTemp, lessThan(80), reason: 'cold-puck dip');
    expect(
      samples.last.groupTemperature,
      greaterThan(minGroupTemp + 5),
      reason: 'temperature should recover after the dip',
    );

    expect(
      pour,
      isNotEmpty,
      reason: 'should reach the pour within 9s via the exit condition',
    );

    final maxPreinfFlow = preinf
        .map((s) => s.flow)
        .reduce((a, b) => a > b ? a : b);
    final minPourFlow = pour.map((s) => s.flow).reduce((a, b) => a < b ? a : b);
    expect(
      minPourFlow,
      lessThan(maxPreinfFlow * 0.6),
      reason: 'pour flow should decline well below the preinfusion fill flow',
    );
    expect(
      minPourFlow,
      greaterThan(0.3),
      reason: 'flow should not collapse to ~0 (no transition glitch)',
    );
  });

  test('successive shots have different puck responses', () async {
    final machine = MockDe1();
    await machine.onConnect();
    await machine.setProfile(_gentleAndSweet());

    Future<List<double>> pull() async {
      await machine.requestState(MachineState.espresso);
      final pressures = await machine.currentSnapshot
          .where((snapshot) => snapshot.state.state == MachineState.espresso)
          .take(12)
          .map((snapshot) => snapshot.pressure)
          .toList()
          .timeout(const Duration(seconds: 3));
      await machine.requestState(MachineState.idle);
      await machine.currentSnapshot
          .firstWhere((snapshot) => snapshot.state.state == MachineState.idle)
          .timeout(const Duration(seconds: 2));
      return pressures;
    }

    try {
      final first = await pull();
      final second = await pull();

      expect(second, isNot(equals(first)));
    } finally {
      await machine.onDisconnect();
    }
  });
}
