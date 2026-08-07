import 'package:logging/logging.dart';
import 'package:reaprime/src/models/data/profile.dart';

/// Decides whether the tablet should send `skipStep` on a mixed step
/// (both weight exit and firmware exit conditions), or defer to let
/// firmware handle the transition.
///
/// On each snapshot where projected weight exceeds the step's weight
/// threshold, [evaluate] checks how close the current sensor reading is
/// to the firmware exit threshold:
///
/// - **Far away** → `fire` immediately (no race risk).
/// - **Near** → defer up to [maxDeferralFrames], checking the trend.
///   If the sensor is trending toward the threshold, firmware might fire
///   on its own — wait. If not trending, fire sooner.
/// - **Past threshold** → defer once (firmware should fire imminently).
/// - **Max deferral reached** → `fire` regardless (cap the wait).
///
/// Created per-shot alongside [ShotSequencer]. Call [reset] at shot start
/// and [onFrameAdvanced] when `profileFrame` changes.
class StepExitArbiter {
  static final _log = Logger('StepExitArbiter');

  /// Maximum frames to defer before firing skipStep regardless.
  /// At ~10 Hz DE1 snapshot rate, 3 frames ≈ 300 ms of deferral.
  static const int maxDeferralFrames = 3;

  /// Proximity window as fraction of exit threshold.
  /// At 20%, a 9-bar exit enters deferral ~1.8 bar from threshold;
  /// a 2-bar exit enters ~0.4 bar out. Calibrated to DE1 sensor
  /// noise at 10 Hz — wide enough to catch genuine firmware approaches,
  /// narrow enough not to stall low-threshold steps.
  static const double pressureProximityFraction = 0.20;

  /// Proximity window as fraction of flow exit threshold.
  static const double flowProximityFraction = 0.25;

  /// Absolute floor so low-threshold exits still have meaningful windows.
  static const double pressureProximityMinimum = 0.3;
  static const double flowProximityMinimum = 0.2;

  final Map<int, _DeferralState> _deferrals = {};

  StepExitArbiter();

  /// Evaluate whether to fire or defer a tablet `skipStep` for a mixed
  /// step (weight exit reached, firmware exit also present).
  ///
  /// [profileFrame] is the current step index from the machine snapshot.
  /// [exit] is the firmware exit condition on this step.
  /// [currentPressure] and [currentFlow] are the live sensor readings.
  StepExitVerdict evaluate({
    required int profileFrame,
    required StepExitCondition exit,
    required double currentPressure,
    required double currentFlow,
  }) {
    if (exit.value <= 0) {
      _log.fine(
        'Frame $profileFrame: firmware exit value ${exit.value} ≤ 0, '
        'treating as weight-only.',
      );
      return StepExitVerdict.fire;
    }

    final sensorValue = switch (exit.type) {
      ExitType.pressure => currentPressure,
      ExitType.flow => currentFlow,
    };

    final distance = switch (exit.condition) {
      ExitCondition.over => exit.value - sensorValue,
      ExitCondition.under => sensorValue - exit.value,
    };

    if (distance <= 0) {
      final deferral = _deferrals.putIfAbsent(
        profileFrame,
        () => _DeferralState(),
      );
      deferral.record(sensorValue);
      if (deferral.frameCount >= maxDeferralFrames) {
        _log.info(
          'Frame $profileFrame: sensor past firmware threshold '
          '(distance=$distance) for $maxDeferralFrames frames — firing.',
        );
        return StepExitVerdict.fire;
      }
      _log.fine(
        'Frame $profileFrame: sensor past firmware threshold '
        '(distance=$distance), deferring '
        '(${deferral.frameCount}/$maxDeferralFrames).',
      );
      return StepExitVerdict.defer;
    }

    final proximityFraction = switch (exit.type) {
      ExitType.pressure => pressureProximityFraction,
      ExitType.flow => flowProximityFraction,
    };
    final proximityMinimum = switch (exit.type) {
      ExitType.pressure => pressureProximityMinimum,
      ExitType.flow => flowProximityMinimum,
    };
    final proximityThreshold = (exit.value * proximityFraction).clamp(
      proximityMinimum,
      double.infinity,
    );

    if (distance > proximityThreshold) {
      _log.info(
        'Frame $profileFrame: firmware exit far '
        '(distance=$distance > $proximityThreshold) — firing skipStep.',
      );
      return StepExitVerdict.fire;
    }

    final deferral = _deferrals.putIfAbsent(
      profileFrame,
      () => _DeferralState(),
    );
    deferral.record(sensorValue);

    if (deferral.frameCount >= maxDeferralFrames) {
      _log.info(
        'Frame $profileFrame: max deferral ($maxDeferralFrames frames) '
        'reached — firing skipStep.',
      );
      return StepExitVerdict.fire;
    }

    if (deferral.isTrending(exit.condition)) {
      _log.fine(
        'Frame $profileFrame: near firmware threshold '
        '(distance=$distance) and trending — deferring '
        '(${deferral.frameCount}/$maxDeferralFrames).',
      );
      return StepExitVerdict.defer;
    }

    _log.info(
      'Frame $profileFrame: near firmware threshold '
      '(distance=$distance) but NOT trending — firing skipStep.',
    );
    return StepExitVerdict.fire;
  }

  /// Notify that the machine's profileFrame has changed.
  /// Clears deferral state for frames the machine has passed
  /// (frames below [newFrame]), since firmware never revisits them.
  void onFrameAdvanced(int newFrame) {
    _deferrals.removeWhere((frame, _) => frame < newFrame);
  }

  /// Reset all state. Call at shot start.
  void reset() {
    _deferrals.clear();
  }
}

/// The arbiter's recommendation for a mixed-step weight exit.
enum StepExitVerdict {
  /// Send `skipStep` now.
  fire,

  /// Wait — firmware exit may fire on its own.
  defer,
}

class _DeferralState {
  int frameCount = 0;
  final List<double> readings = [];

  void record(double sensorValue) {
    readings.add(sensorValue);
    frameCount++;
  }

  /// Whether the latest readings are moving toward the exit condition
  /// threshold. Requires all available pairwise comparisons to point
  /// toward the exit — a single reversal flips to "not trending."
  ///
  /// On the first sample (no prior reading), assumes trending
  /// (conservative: gives firmware the benefit of the doubt).
  bool isTrending(ExitCondition condition) {
    if (readings.length < 2) return true;
    for (var i = readings.length - 1; i >= 1; i--) {
      final prev = readings[i - 1];
      final curr = readings[i];
      final stepTowards = switch (condition) {
        ExitCondition.over => curr > prev,
        ExitCondition.under => curr < prev,
      };
      if (!stepTowards) return false;
    }
    return true;
  }
}
