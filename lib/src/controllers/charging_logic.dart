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

/// Decides whether to push `setUsbChargerMode(shouldCharge)` to the DE1 on
/// this tick.
///
/// The DE1 firmware re-enables the USB charger on its own, so keeping the
/// tablet discharging requires periodically re-asserting "off". When we want
/// to charge, the firmware default already matches, so re-writing every tick
/// is pure BLE noise.
///
/// - Write whenever the target differs from [lastApplied] (`null` forces a
///   write — first tick, or after a reconnect cleared it; a reconnected
///   machine resets to its charging-on default).
/// - While discharging (`shouldCharge == false`), re-assert once at least
///   [reassertInterval] has elapsed since [lastWrite].
/// - While charging and unchanged, skip.
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

/// Determines the night phase based on current time and night mode config.
///
/// Phases (relative to sleepTime):
/// - normal: morningTime to sleepTime - 120min
/// - hovering: sleepTime - 120min to sleepTime - 30min
/// - chargingToMax: sleepTime - 30min to sleepTime
/// - sleeping: sleepTime to morningTime
///
/// All arithmetic is modulo 1440 to handle midnight wrapping.
NightPhase _determineNightPhase(int nowMinutes, NightModeConfig config) {
  final morning = config.morningTimeMinutes;
  final sleep = config.sleepTimeMinutes;

  // Normalize all times relative to morningTime as "start of day".
  // This way we can do simple range comparisons without worrying about
  // midnight wrapping.
  final now = (nowMinutes - morning) % 1440;
  final sleepNorm = (sleep - morning) % 1440;
  final hoverStart = (sleepNorm - 120) % 1440;
  final chargeStart = (sleepNorm - 30) % 1440;

  // In normalized space, the day goes:
  //   0 (morning) -> hoverStart -> chargeStart -> sleepNorm -> 1440 (next morning)
  // sleeping phase: sleepNorm to end of normalized day (1440)
  // normal phase: 0 to hoverStart
  // hovering: hoverStart to chargeStart
  // chargingToMax: chargeStart to sleepNorm

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

/// Applies hysteresis charging logic.
///
/// If battery <= low, charge. If battery >= high, stop.
/// In between, maintain the previous charging direction (wasCharging).
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

/// Pure function that decides whether to charge the battery.
///
/// Priority order:
/// 1. Emergency: battery <= 15% -> always charge
/// 2. Disabled mode -> always charge
/// 3. Night mode phases (if config provided)
/// 4. Charging mode hysteresis ranges
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
        // Should not happen when nightModeConfig is non-null
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
