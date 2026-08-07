import 'dart:math';

import 'package:reaprime/src/models/device/machine.dart';

class SimulatedShotWeightModel {
  static const double firstDropsMl = 2.0;

  static const double saturationSecs = 2.5;

  int targetVolumeCountStart = 0;

  double _settledWeight = 0.0;
  double _shotVolume = 0.0;
  double _pourElapsed = 0.0;
  double _tareOffset = 0.0;
  bool _inShot = false;
  DateTime? _lastSampleTime;

  double get _gross => _settledWeight + max(0.0, _shotVolume - firstDropsMl);

  double get weight => _gross - _tareOffset;

  void tare() => _tareOffset = _gross;

  void reset() {
    _settledWeight = 0.0;
    _shotVolume = 0.0;
    _pourElapsed = 0.0;
    _tareOffset = 0.0;
    _inShot = false;
    _lastSampleTime = null;
  }

  void ingest(MachineSnapshot s) {
    final now = s.timestamp;
    final last = _lastSampleTime;
    _lastSampleTime = now;

    final inEspresso = s.state.state == MachineState.espresso;
    if (inEspresso && !_inShot) {
      _settledWeight = _gross;
      _shotVolume = 0.0;
      _pourElapsed = 0.0;
    }
    _inShot = inEspresso;

    if (last == null) return;
    final dtSec = now.difference(last).inMilliseconds / 1000.0;
    if (dtSec <= 0) return;

    if (inEspresso) {
      if (s.profileFrame < targetVolumeCountStart) return;
      _pourElapsed += dtSec;
      final ramp = (_pourElapsed / saturationSecs).clamp(0.0, 1.0);
      _shotVolume += s.flow * dtSec * ramp;
    } else if (s.state.state == MachineState.hotWater) {
      _settledWeight += s.flow * dtSec;
    }
  }
}
