import 'package:logging/logging.dart';
import 'package:reaprime/src/models/data/profile.dart';

class StepExitArbiter {
  static final _log = Logger('StepExitArbiter');

  static const int maxDeferralFrames = 3;

  static const double pressureProximityFraction = 0.20;

  static const double flowProximityFraction = 0.25;

  static const double pressureProximityMinimum = 0.3;
  static const double flowProximityMinimum = 0.2;

  final Map<int, _DeferralState> _deferrals = {};

  StepExitArbiter();

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

  void onFrameAdvanced(int newFrame) {
    _deferrals.removeWhere((frame, _) => frame < newFrame);
  }

  void reset() {
    _deferrals.clear();
  }
}

enum StepExitVerdict { fire, defer }

class _DeferralState {
  int frameCount = 0;
  final List<double> readings = [];

  void record(double sensorValue) {
    readings.add(sensorValue);
    frameCount++;
  }

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
