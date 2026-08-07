import 'package:reaprime/src/settings/charging_mode.dart';

enum NightPhase { inactive, normal, hovering, chargingToMax, sleeping }

class NightModeConfig {
  final int sleepTimeMinutes;
  final int morningTimeMinutes;

  NightModeConfig({
    required this.sleepTimeMinutes,
    required this.morningTimeMinutes,
  });
}

class ChargingDecision {
  final bool shouldCharge;
  final NightPhase nightPhase;
  final String reason;

  ChargingDecision({
    required this.shouldCharge,
    required this.nightPhase,
    required this.reason,
  });
}

class ChargingState {
  final ChargingMode mode;
  final bool nightModeEnabled;
  final NightPhase currentPhase;
  final int batteryPercent;
  final bool usbChargerOn;
  final bool isEmergency;

  ChargingState({
    required this.mode,
    required this.nightModeEnabled,
    required this.currentPhase,
    required this.batteryPercent,
    required this.usbChargerOn,
    required this.isEmergency,
  });

  Map<String, dynamic> toJson() {
    return {
      'mode': mode.name,
      'nightModeEnabled': nightModeEnabled,
      'currentPhase': currentPhase.name,
      'batteryPercent': batteryPercent,
      'usbChargerOn': usbChargerOn,
      'isEmergency': isEmergency,
    };
  }
}

bool shouldWriteChargerMode({
  required bool shouldCharge,
  required bool? lastApplied,
  required DateTime now,
  required DateTime? lastWrite,
  required Duration reassertInterval,
}) {
  if (lastApplied != shouldCharge) return true;
  if (!shouldCharge) {
    return lastWrite == null || now.difference(lastWrite) >= reassertInterval;
  }
  return false;
}

int _minutesSinceMidnight(DateTime dt) => dt.hour * 60 + dt.minute;

NightPhase _determineNightPhase(int nowMinutes, NightModeConfig config) {
  final morning = config.morningTimeMinutes;
  final sleep = config.sleepTimeMinutes;

  final now = (nowMinutes - morning) % 1440;
  final sleepNorm = (sleep - morning) % 1440;
  final hoverStart = (sleepNorm - 120) % 1440;
  final chargeStart = (sleepNorm - 30) % 1440;

  if (now < hoverStart) {
    return NightPhase.normal;
  } else if (now < chargeStart) {
    return NightPhase.hovering;
  } else if (now < sleepNorm) {
    return NightPhase.chargingToMax;
  } else {
    return NightPhase.sleeping;
  }
}

bool _hysteresis({
  required int batteryPercent,
  required int low,
  required int high,
  required bool wasCharging,
}) {
  if (batteryPercent <= low) return true;
  if (batteryPercent >= high) return false;
  return wasCharging;
}

ChargingDecision decide({
  required int batteryPercent,
  required DateTime currentTime,
  required ChargingMode chargingMode,
  required NightModeConfig? nightModeConfig,
  required bool wasCharging,
}) {
  if (batteryPercent <= 15) {
    return ChargingDecision(
      shouldCharge: true,
      nightPhase: nightModeConfig != null
          ? _determineNightPhase(
              _minutesSinceMidnight(currentTime),
              nightModeConfig,
            )
          : NightPhase.inactive,
      reason: 'emergency',
    );
  }

  if (chargingMode == ChargingMode.disabled) {
    return ChargingDecision(
      shouldCharge: true,
      nightPhase: NightPhase.inactive,
      reason: 'disabled',
    );
  }

  if (nightModeConfig != null) {
    final nowMinutes = _minutesSinceMidnight(currentTime);
    final phase = _determineNightPhase(nowMinutes, nightModeConfig);

    switch (phase) {
      case NightPhase.sleeping:
        return ChargingDecision(
          shouldCharge: false,
          nightPhase: NightPhase.sleeping,
          reason: 'night sleeping',
        );
      case NightPhase.chargingToMax:
        return ChargingDecision(
          shouldCharge: batteryPercent < 95,
          nightPhase: NightPhase.chargingToMax,
          reason: 'night charging to max',
        );
      case NightPhase.hovering:
        final shouldCharge = _hysteresis(
          batteryPercent: batteryPercent,
          low: 75,
          high: 80,
          wasCharging: wasCharging,
        );
        return ChargingDecision(
          shouldCharge: shouldCharge,
          nightPhase: NightPhase.hovering,
          reason: 'night hovering',
        );
      case NightPhase.normal:
        break;
      case NightPhase.inactive:
        break;
    }
  }

  final nightPhase = nightModeConfig != null
      ? _determineNightPhase(
          _minutesSinceMidnight(currentTime),
          nightModeConfig,
        )
      : NightPhase.inactive;

  final (int low, int high) = switch (chargingMode) {
    ChargingMode.longevity => (45, 55),
    ChargingMode.balanced => (40, 80),
    ChargingMode.highAvailability => (80, 95),
    ChargingMode.disabled => (0, 100),
  };

  final shouldCharge = _hysteresis(
    batteryPercent: batteryPercent,
    low: low,
    high: high,
    wasCharging: wasCharging,
  );

  return ChargingDecision(
    shouldCharge: shouldCharge,
    nightPhase: nightPhase,
    reason: chargingMode.name,
  );
}
