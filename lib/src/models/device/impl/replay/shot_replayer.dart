import 'package:reaprime/src/controllers/scale_controller.dart';
import 'package:reaprime/src/models/data/shot_snapshot.dart';
import 'package:reaprime/src/models/device/machine.dart';

class ShotReplayer {
  ShotReplayer(List<ShotSnapshot> measurements)
    : assert(measurements.isNotEmpty, 'replay needs at least one sample'),
      _measurements = measurements,
      _elapsedSeconds = _computeElapsed(measurements);

  final List<ShotSnapshot> _measurements;
  final List<double> _elapsedSeconds;

  double get durationSeconds => _elapsedSeconds.last;

  bool isFinished(double elapsedSeconds) =>
      elapsedSeconds > _elapsedSeconds.last;

  MachineSnapshot frameAt(
    double elapsedSeconds, {
    required DateTime timestamp,
  }) {
    final source = _measurements[_indexAt(elapsedSeconds)].machine;
    if (isFinished(elapsedSeconds)) {
      return source.copyWith(
        timestamp: timestamp,
        flow: 0,
        pressure: 0,
        state: const MachineStateSnapshot(
          state: MachineState.idle,
          substate: MachineSubstate.idle,
        ),
      );
    }
    return source.copyWith(timestamp: timestamp);
  }

  WeightSnapshot? scaleAt(double elapsedSeconds) =>
      _measurements[_indexAt(elapsedSeconds)].scale;

  int _indexAt(double elapsedSeconds) {
    var index = 0;
    for (var i = 0; i < _elapsedSeconds.length; i++) {
      if (_elapsedSeconds[i] <= elapsedSeconds) {
        index = i;
      } else {
        break;
      }
    }
    return index;
  }

  static List<double> _computeElapsed(List<ShotSnapshot> measurements) {
    final origin = measurements.first.machine.timestamp;
    return measurements
        .map((s) => s.machine.timestamp.difference(origin).inMicroseconds / 1e6)
        .toList(growable: false);
  }
}
