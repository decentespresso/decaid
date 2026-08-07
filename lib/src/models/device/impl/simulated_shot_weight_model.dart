import 'dart:math';

import 'package:reaprime/src/models/device/machine.dart';

/// Synthesises a believable cup weight from a simulated machine's snapshot
/// stream. Shared by `MockBengle`'s integrated scale and the standalone
/// `MockScale` so both read like a real scale under a real shot:
///
/// - Nothing accumulates outside `MachineState.espresso` and
///   `MachineState.hotWater`; espresso preinfusion frames
///   (`profileFrame < targetVolumeCountStart`) are absorbed by the puck,
///   while hot water lands in the cup 1:1.
/// - The basket, screen and spouts hold back the first few mL of every shot
///   ([firstDropsMl]), so weight lags the pour start instead of rising the
///   instant pouring begins.
/// - Extraction ramps in over [saturationSecs] as the basket saturates, so
///   early weight gain is gradual rather than tracking the fill-flow spike.
/// - Once saturated, weight gain tracks flow 1:1 — real DE1 shots show
///   dW/dt of 0.85–1.1x reported flow late in the shot (visualizer.coffee
///   sample set); the absorbed water is a fixed early cost, not a permanent
///   percentage tax.
class SimulatedShotWeightModel {
  /// Volume held back by basket/screen/spouts before drops hit the scale.
  static const double firstDropsMl = 2.0;

  /// Window over which extraction ramps from 0 to full as the basket fills.
  static const double saturationSecs = 2.5;

  /// First profile frame that counts as pour (earlier frames are
  /// preinfusion, absorbed by the puck). Mirrors the machine's
  /// `targetVolumeCountStart`.
  int targetVolumeCountStart = 0;

  double _settledWeight = 0.0;
  double _shotVolume = 0.0;
  double _pourElapsed = 0.0;
  double _tareOffset = 0.0;
  bool _inShot = false;
  DateTime? _lastSampleTime;

  double get _gross => _settledWeight + max(0.0, _shotVolume - firstDropsMl);

  /// Current (tared) scale reading in grams. Never decreases mid-shot.
  double get weight => _gross - _tareOffset;

  /// Zero the reading, like placing/taring a cup.
  void tare() => _tareOffset = _gross;

  /// Full reset (device connect).
  void reset() {
    _settledWeight = 0.0;
    _shotVolume = 0.0;
    _pourElapsed = 0.0;
    _tareOffset = 0.0;
    _inShot = false;
    _lastSampleTime = null;
  }

  /// Integrate one machine snapshot (uses the snapshot's own timestamp, so
  /// callers can replay at any cadence).
  void ingest(MachineSnapshot s) {
    final now = s.timestamp;
    final last = _lastSampleTime;
    _lastSampleTime = now;

    final inEspresso = s.state.state == MachineState.espresso;
    if (inEspresso && !_inShot) {
      // New shot: bank what already landed in the cup (the reading must not
      // jump), then re-apply the fresh puck's holdback and ramp-in.
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
