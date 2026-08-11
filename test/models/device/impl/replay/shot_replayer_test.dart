import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/scale_controller.dart';
import 'package:reaprime/src/models/data/shot_snapshot.dart';
import 'package:reaprime/src/models/device/impl/replay/shot_replayer.dart';
import 'package:reaprime/src/models/device/machine.dart';

ShotSnapshot _sample({
  required DateTime base,
  required double elapsed,
  required double pressure,
  required double flow,
  double weight = 0,
}) {
  final ts = base.add(Duration(milliseconds: (elapsed * 1000).round()));
  return ShotSnapshot(
    machine: MachineSnapshot(
      timestamp: ts,
      state: const MachineStateSnapshot(
        state: MachineState.espresso,
        substate: MachineSubstate.pouring,
      ),
      flow: flow,
      pressure: pressure,
      targetFlow: 0,
      targetPressure: pressure,
      mixTemperature: 90,
      groupTemperature: 90,
      targetMixTemperature: 90,
      targetGroupTemperature: 90,
      profileFrame: 0,
      steamTemperature: 0,
    ),
    scale: WeightSnapshot(timestamp: ts, weight: weight, weightFlow: 0),
  );
}

void main() {
  final base = DateTime.utc(2022, 1, 1);
  List<ShotSnapshot> curve() => [
    _sample(base: base, elapsed: 0.0, pressure: 1.0, flow: 4.0),
    _sample(base: base, elapsed: 0.5, pressure: 5.0, flow: 2.0, weight: 3),
    _sample(base: base, elapsed: 1.0, pressure: 9.0, flow: 1.8, weight: 10),
  ];

  group('ShotReplayer', () {
    test('durationSeconds is the last recorded elapsed', () {
      expect(ShotReplayer(curve()).durationSeconds, closeTo(1.0, 1e-9));
    });

    test('frameAt returns the recorded sample at-or-before the given time', () {
      final r = ShotReplayer(curve());
      final now = DateTime.utc(2030);

      expect(r.frameAt(0.0, timestamp: now).pressure, 1.0);
      expect(r.frameAt(0.4, timestamp: now).pressure, 1.0);
      expect(r.frameAt(0.5, timestamp: now).pressure, 5.0);
      expect(r.frameAt(0.9, timestamp: now).pressure, 5.0);
      expect(r.frameAt(1.0, timestamp: now).pressure, 9.0);
    });

    test('frameAt stamps the provided timestamp', () {
      final now = DateTime.utc(2030, 5, 5);
      expect(ShotReplayer(curve()).frameAt(0.4, timestamp: now).timestamp, now);
    });

    test('recorded flow is preserved (drives the simulated scale weight)', () {
      final r = ShotReplayer(curve());
      final now = DateTime.utc(2030);
      expect(r.frameAt(0.5, timestamp: now).flow, 2.0);
    });

    test('isFinished only once strictly past the last recorded sample', () {
      final r = ShotReplayer(curve());
      expect(r.isFinished(0.0), isFalse);
      expect(r.isFinished(0.99), isFalse);
      expect(r.isFinished(1.0), isFalse);
      expect(r.isFinished(1.001), isTrue);
      expect(r.isFinished(2.0), isTrue);
    });

    test('scaleAt returns the recorded weight at-or-before the time', () {
      final r = ShotReplayer(curve());
      expect(r.scaleAt(0.0)?.weight, 0);
      expect(r.scaleAt(0.4)?.weight, 0);
      expect(r.scaleAt(0.5)?.weight, 3);
      expect(r.scaleAt(1.0)?.weight, 10);
    });

    test('past the end the frame is idle with zero flow and pressure', () {
      final r = ShotReplayer(curve());
      final now = DateTime.utc(2030);
      final f = r.frameAt(5.0, timestamp: now);
      expect(f.state.state, MachineState.idle);
      expect(f.state.substate, MachineSubstate.idle);
      expect(f.flow, 0);
      expect(f.pressure, 0);
    });
  });
}
