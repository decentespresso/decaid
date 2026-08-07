import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/device/impl/simulated_shot_weight_model.dart';
import 'package:reaprime/src/models/device/machine.dart';

// Synthetic machine snapshots at a fixed 100ms cadence, mirroring MockDe1's
// tick rate. Only the fields the weight model reads matter (timestamp, state,
// flow, profileFrame); the rest are filler.
MachineSnapshot _snap(
  DateTime t, {
  double flow = 0.0,
  int frame = 0,
  MachineState state = MachineState.espresso,
  MachineSubstate substate = MachineSubstate.pouring,
}) => MachineSnapshot(
  timestamp: t,
  state: MachineStateSnapshot(state: state, substate: substate),
  flow: flow,
  pressure: 0,
  targetFlow: 0,
  targetPressure: 0,
  mixTemperature: 90,
  groupTemperature: 90,
  targetMixTemperature: 90,
  targetGroupTemperature: 90,
  profileFrame: frame,
  steamTemperature: 0,
);

void main() {
  group('SimulatedShotWeightModel', () {
    late SimulatedShotWeightModel model;
    late DateTime clock;

    setUp(() {
      model = SimulatedShotWeightModel();
      clock = DateTime(2026, 1, 1, 8, 0, 0);
    });

    /// Feed [seconds] of snapshots at 100ms cadence.
    void run(
      double seconds, {
      double flow = 0.0,
      int frame = 0,
      MachineState state = MachineState.espresso,
    }) {
      final ticks = (seconds * 10).round();
      for (var i = 0; i < ticks; i++) {
        clock = clock.add(const Duration(milliseconds: 100));
        model.ingest(_snap(clock, flow: flow, frame: frame, state: state));
      }
    }

    test('no weight while profileFrame is below targetVolumeCountStart', () {
      model.targetVolumeCountStart = 1;
      run(3.0, flow: 8.0, frame: 0);
      expect(
        model.weight,
        0.0,
        reason: 'preinfusion water is absorbed by the puck',
      );
    });

    test('no weight while the machine is not pulling a shot', () {
      run(3.0, flow: 2.0, state: MachineState.idle);
      expect(
        model.weight,
        0.0,
        reason: 'weight must not accumulate outside a shot',
      );
    });

    test('first drops are held back at pour start', () {
      run(0.5, flow: 2.0);
      expect(
        model.weight,
        lessThan(0.1),
        reason: 'basket/screen/spouts hold back the first few mL',
      );
      run(5.0, flow: 2.0);
      expect(
        model.weight,
        greaterThan(1.0),
        reason: 'drops reach the cup once the held-back volume fills',
      );
    });

    test('late-shot weight gain tracks flow 1:1', () {
      // Real DE1 shots show dW/dt of 0.85-1.1x reported flow once the puck is
      // saturated (visualizer.coffee sample set) — the absorbed volume is a
      // fixed early cost, not a permanent 20% tax.
      run(10.0, flow: 2.0);
      final at10 = model.weight;
      run(5.0, flow: 2.0);
      expect(
        model.weight - at10,
        closeTo(10.0, 0.2),
        reason: '5s at 2 mL/s must add ~10g after saturation',
      );
    });

    test('weight never decreases during a shot', () {
      model.targetVolumeCountStart = 1;
      var prev = model.weight;
      for (var i = 0; i < 100; i++) {
        clock = clock.add(const Duration(milliseconds: 100));
        final frame = i < 30 ? 0 : 1;
        final flow = i < 30 ? 6.0 : (i < 60 ? 2.0 : 3.5);
        model.ingest(_snap(clock, flow: flow, frame: frame));
        expect(model.weight, greaterThanOrEqualTo(prev - 0.001));
        prev = model.weight;
      }
    });

    test('tare zeroes the reading and later flow adds on top', () {
      run(6.0, flow: 2.0);
      expect(model.weight, greaterThan(1.0));
      model.tare();
      expect(model.weight.abs(), lessThan(0.001));
      run(2.0, flow: 2.0);
      expect(
        model.weight,
        closeTo(4.0, 0.2),
        reason: 'post-tare gain is pure flow (saturated puck)',
      );
    });

    test('a new shot re-applies the first-drops lag', () {
      run(6.0, flow: 2.0);
      run(1.0, flow: 0.0, state: MachineState.idle);
      model.tare();
      // Shot 2 must lag again instead of tracking flow instantly.
      run(0.5, flow: 2.0);
      expect(
        model.weight,
        lessThan(0.1),
        reason: 'fresh puck holds back the first drops of every shot',
      );
      run(5.0, flow: 2.0);
      expect(model.weight, greaterThan(1.0));
    });

    test('weight does not jump when a new shot begins', () {
      run(6.0, flow: 2.0);
      final endOfShot1 = model.weight;
      run(1.0, flow: 0.0, state: MachineState.idle);
      run(0.2, flow: 1.0);
      expect(
        model.weight,
        closeTo(endOfShot1, 0.05),
        reason: 'starting a shot must not discontinue the reading',
      );
    });

    test('hot water dispenses straight into the cup', () {
      // No puck in the path: no first-drops holdback, no saturation ramp —
      // weight tracks the dispense flow 1:1 from the start.
      run(3.0, flow: 2.0, state: MachineState.hotWater);
      expect(
        model.weight,
        closeTo(5.8, 0.3),
        reason: '~3s at 2 mL/s lands ~6g in the cup',
      );
    });

    test('reset clears everything', () {
      run(6.0, flow: 2.0);
      model.tare();
      run(2.0, flow: 2.0);
      model.reset();
      expect(model.weight, 0.0);
    });
  });
}
