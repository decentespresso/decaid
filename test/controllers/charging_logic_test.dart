import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/charging_logic.dart';
import 'package:reaprime/src/settings/charging_mode.dart';

void main() {
  group('emergency override', () {
    test('battery at 15% returns shouldCharge true regardless of mode', () {
      final result = decide(
        batteryPercent: 15,
        currentTime: DateTime(2026, 1, 15, 12, 0),
        chargingMode: ChargingMode.longevity,
        nightModeConfig: null,
        wasCharging: false,
      );
      expect(result.shouldCharge, true);
      expect(result.reason, 'emergency');
    });

    test('battery at 14% returns shouldCharge true', () {
      final result = decide(
        batteryPercent: 14,
        currentTime: DateTime(2026, 1, 15, 12, 0),
        chargingMode: ChargingMode.longevity,
        nightModeConfig: null,
        wasCharging: false,
      );
      expect(result.shouldCharge, true);
      expect(result.reason, 'emergency');
    });

    test('battery at 16% with balanced mode follows mode rules', () {
      final result = decide(
        batteryPercent: 16,
        currentTime: DateTime(2026, 1, 15, 12, 0),
        chargingMode: ChargingMode.balanced,
        nightModeConfig: null,
        wasCharging: false,
      );
      expect(result.shouldCharge, true);
      expect(result.reason, 'balanced');
    });

    test('emergency during night sleeping phase returns shouldCharge true', () {
      final config = NightModeConfig(
        sleepTimeMinutes: 1320,
        morningTimeMinutes: 420,
      );
      final result = decide(
        batteryPercent: 10,
        currentTime: DateTime(2026, 1, 16, 3, 0),
        chargingMode: ChargingMode.balanced,
        nightModeConfig: config,
        wasCharging: false,
      );
      expect(result.shouldCharge, true);
      expect(result.reason, 'emergency');
    });
  });

  group('disabled mode', () {
    test('always returns shouldCharge true at any battery level', () {
      final result = decide(
        batteryPercent: 50,
        currentTime: DateTime(2026, 1, 15, 12, 0),
        chargingMode: ChargingMode.disabled,
        nightModeConfig: null,
        wasCharging: false,
      );
      expect(result.shouldCharge, true);
      expect(result.reason, 'disabled');
    });

    test('nightPhase is inactive', () {
      final result = decide(
        batteryPercent: 50,
        currentTime: DateTime(2026, 1, 15, 12, 0),
        chargingMode: ChargingMode.disabled,
        nightModeConfig: null,
        wasCharging: false,
      );
      expect(result.nightPhase, NightPhase.inactive);
    });
  });

  group('longevity mode 45-55%', () {
    test('battery at 44% returns shouldCharge true', () {
      final result = decide(
        batteryPercent: 44,
        currentTime: DateTime(2026, 1, 15, 12, 0),
        chargingMode: ChargingMode.longevity,
        nightModeConfig: null,
        wasCharging: false,
      );
      expect(result.shouldCharge, true);
    });

    test('battery at 56% returns shouldCharge false', () {
      final result = decide(
        batteryPercent: 56,
        currentTime: DateTime(2026, 1, 15, 12, 0),
        chargingMode: ChargingMode.longevity,
        nightModeConfig: null,
        wasCharging: true,
      );
      expect(result.shouldCharge, false);
    });

    test('battery at 50%, wasCharging true returns shouldCharge true', () {
      final result = decide(
        batteryPercent: 50,
        currentTime: DateTime(2026, 1, 15, 12, 0),
        chargingMode: ChargingMode.longevity,
        nightModeConfig: null,
        wasCharging: true,
      );
      expect(result.shouldCharge, true);
    });

    test('battery at 50%, wasCharging false returns shouldCharge false', () {
      final result = decide(
        batteryPercent: 50,
        currentTime: DateTime(2026, 1, 15, 12, 0),
        chargingMode: ChargingMode.longevity,
        nightModeConfig: null,
        wasCharging: false,
      );
      expect(result.shouldCharge, false);
    });

    test('battery at 45% returns shouldCharge true (boundary: <= low)', () {
      final result = decide(
        batteryPercent: 45,
        currentTime: DateTime(2026, 1, 15, 12, 0),
        chargingMode: ChargingMode.longevity,
        nightModeConfig: null,
        wasCharging: false,
      );
      expect(result.shouldCharge, true);
    });

    test('battery at 55% returns shouldCharge false (boundary: >= high)', () {
      final result = decide(
        batteryPercent: 55,
        currentTime: DateTime(2026, 1, 15, 12, 0),
        chargingMode: ChargingMode.longevity,
        nightModeConfig: null,
        wasCharging: true,
      );
      expect(result.shouldCharge, false);
    });
  });

  group('balanced mode 40-80%', () {
    test('battery at 39% returns shouldCharge true', () {
      final result = decide(
        batteryPercent: 39,
        currentTime: DateTime(2026, 1, 15, 12, 0),
        chargingMode: ChargingMode.balanced,
        nightModeConfig: null,
        wasCharging: false,
      );
      expect(result.shouldCharge, true);
    });

    test('battery at 81% returns shouldCharge false', () {
      final result = decide(
        batteryPercent: 81,
        currentTime: DateTime(2026, 1, 15, 12, 0),
        chargingMode: ChargingMode.balanced,
        nightModeConfig: null,
        wasCharging: true,
      );
      expect(result.shouldCharge, false);
    });

    test('battery at 60%, wasCharging true returns shouldCharge true', () {
      final result = decide(
        batteryPercent: 60,
        currentTime: DateTime(2026, 1, 15, 12, 0),
        chargingMode: ChargingMode.balanced,
        nightModeConfig: null,
        wasCharging: true,
      );
      expect(result.shouldCharge, true);
    });

    test('battery at 60%, wasCharging false returns shouldCharge false', () {
      final result = decide(
        batteryPercent: 60,
        currentTime: DateTime(2026, 1, 15, 12, 0),
        chargingMode: ChargingMode.balanced,
        nightModeConfig: null,
        wasCharging: false,
      );
      expect(result.shouldCharge, false);
    });

    test('battery at 40% returns shouldCharge true', () {
      final result = decide(
        batteryPercent: 40,
        currentTime: DateTime(2026, 1, 15, 12, 0),
        chargingMode: ChargingMode.balanced,
        nightModeConfig: null,
        wasCharging: false,
      );
      expect(result.shouldCharge, true);
    });

    test('battery at 80% returns shouldCharge false', () {
      final result = decide(
        batteryPercent: 80,
        currentTime: DateTime(2026, 1, 15, 12, 0),
        chargingMode: ChargingMode.balanced,
        nightModeConfig: null,
        wasCharging: true,
      );
      expect(result.shouldCharge, false);
    });
  });

  group('highAvailability mode 80-95%', () {
    test('battery at 79% returns shouldCharge true', () {
      final result = decide(
        batteryPercent: 79,
        currentTime: DateTime(2026, 1, 15, 12, 0),
        chargingMode: ChargingMode.highAvailability,
        nightModeConfig: null,
        wasCharging: false,
      );
      expect(result.shouldCharge, true);
    });

    test('battery at 96% returns shouldCharge false', () {
      final result = decide(
        batteryPercent: 96,
        currentTime: DateTime(2026, 1, 15, 12, 0),
        chargingMode: ChargingMode.highAvailability,
        nightModeConfig: null,
        wasCharging: true,
      );
      expect(result.shouldCharge, false);
    });

    test('battery at 85%, wasCharging true returns shouldCharge true', () {
      final result = decide(
        batteryPercent: 85,
        currentTime: DateTime(2026, 1, 15, 12, 0),
        chargingMode: ChargingMode.highAvailability,
        nightModeConfig: null,
        wasCharging: true,
      );
      expect(result.shouldCharge, true);
    });

    test('battery at 85%, wasCharging false returns shouldCharge false', () {
      final result = decide(
        batteryPercent: 85,
        currentTime: DateTime(2026, 1, 15, 12, 0),
        chargingMode: ChargingMode.highAvailability,
        nightModeConfig: null,
        wasCharging: false,
      );
      expect(result.shouldCharge, false);
    });

    test('battery at 80% returns shouldCharge true', () {
      final result = decide(
        batteryPercent: 80,
        currentTime: DateTime(2026, 1, 15, 12, 0),
        chargingMode: ChargingMode.highAvailability,
        nightModeConfig: null,
        wasCharging: false,
      );
      expect(result.shouldCharge, true);
    });

    test('battery at 95% returns shouldCharge false', () {
      final result = decide(
        batteryPercent: 95,
        currentTime: DateTime(2026, 1, 15, 12, 0),
        chargingMode: ChargingMode.highAvailability,
        nightModeConfig: null,
        wasCharging: true,
      );
      expect(result.shouldCharge, false);
    });
  });

  group('night mode phase determination', () {
    // sleep=22:00 (1320), morning=07:00 (420)
    // balanced mode at 60% with wasCharging=false
    final config = NightModeConfig(
      sleepTimeMinutes: 1320,
      morningTimeMinutes: 420,
    );

    test('19:59 is normal phase', () {
      final result = decide(
        batteryPercent: 60,
        currentTime: DateTime(2026, 1, 15, 19, 59),
        chargingMode: ChargingMode.balanced,
        nightModeConfig: config,
        wasCharging: false,
      );
      expect(result.nightPhase, NightPhase.normal);
    });

    test('20:00 is hovering phase', () {
      final result = decide(
        batteryPercent: 60,
        currentTime: DateTime(2026, 1, 15, 20, 0),
        chargingMode: ChargingMode.balanced,
        nightModeConfig: config,
        wasCharging: false,
      );
      expect(result.nightPhase, NightPhase.hovering);
    });

    test('21:29 is hovering phase', () {
      final result = decide(
        batteryPercent: 60,
        currentTime: DateTime(2026, 1, 15, 21, 29),
        chargingMode: ChargingMode.balanced,
        nightModeConfig: config,
        wasCharging: false,
      );
      expect(result.nightPhase, NightPhase.hovering);
    });

    test('21:30 is chargingToMax phase', () {
      final result = decide(
        batteryPercent: 60,
        currentTime: DateTime(2026, 1, 15, 21, 30),
        chargingMode: ChargingMode.balanced,
        nightModeConfig: config,
        wasCharging: false,
      );
      expect(result.nightPhase, NightPhase.chargingToMax);
    });

    test('21:59 is chargingToMax phase', () {
      final result = decide(
        batteryPercent: 60,
        currentTime: DateTime(2026, 1, 15, 21, 59),
        chargingMode: ChargingMode.balanced,
        nightModeConfig: config,
        wasCharging: false,
      );
      expect(result.nightPhase, NightPhase.chargingToMax);
    });

    test('22:00 is sleeping phase', () {
      final result = decide(
        batteryPercent: 60,
        currentTime: DateTime(2026, 1, 15, 22, 0),
        chargingMode: ChargingMode.balanced,
        nightModeConfig: config,
        wasCharging: false,
      );
      expect(result.nightPhase, NightPhase.sleeping);
    });

    test('06:59 is sleeping phase', () {
      final result = decide(
        batteryPercent: 60,
        currentTime: DateTime(2026, 1, 16, 6, 59),
        chargingMode: ChargingMode.balanced,
        nightModeConfig: config,
        wasCharging: false,
      );
      expect(result.nightPhase, NightPhase.sleeping);
    });

    test('07:00 is normal phase', () {
      final result = decide(
        batteryPercent: 60,
        currentTime: DateTime(2026, 1, 16, 7, 0),
        chargingMode: ChargingMode.balanced,
        nightModeConfig: config,
        wasCharging: false,
      );
      expect(result.nightPhase, NightPhase.normal);
    });
  });

  group('night mode hovering phase', () {
    // sleep=22:00 (1320), morning=07:00 (420), time=20:30
    final config = NightModeConfig(
      sleepTimeMinutes: 1320,
      morningTimeMinutes: 420,
    );
    final time = DateTime(2026, 1, 15, 20, 30);

    test('battery at 74% returns shouldCharge true (below 75)', () {
      final result = decide(
        batteryPercent: 74,
        currentTime: time,
        chargingMode: ChargingMode.balanced,
        nightModeConfig: config,
        wasCharging: false,
      );
      expect(result.shouldCharge, true);
      expect(result.nightPhase, NightPhase.hovering);
    });

    test('battery at 81% returns shouldCharge false (above 80)', () {
      final result = decide(
        batteryPercent: 81,
        currentTime: time,
        chargingMode: ChargingMode.balanced,
        nightModeConfig: config,
        wasCharging: true,
      );
      expect(result.shouldCharge, false);
      expect(result.nightPhase, NightPhase.hovering);
    });

    test('battery at 77%, wasCharging true returns shouldCharge true', () {
      final result = decide(
        batteryPercent: 77,
        currentTime: time,
        chargingMode: ChargingMode.balanced,
        nightModeConfig: config,
        wasCharging: true,
      );
      expect(result.shouldCharge, true);
      expect(result.nightPhase, NightPhase.hovering);
    });

    test('battery at 77%, wasCharging false returns shouldCharge false', () {
      final result = decide(
        batteryPercent: 77,
        currentTime: time,
        chargingMode: ChargingMode.balanced,
        nightModeConfig: config,
        wasCharging: false,
      );
      expect(result.shouldCharge, false);
      expect(result.nightPhase, NightPhase.hovering);
    });
  });

  group('night mode chargingToMax phase', () {
    // sleep=22:00 (1320), morning=07:00 (420), time=21:45
    final config = NightModeConfig(
      sleepTimeMinutes: 1320,
      morningTimeMinutes: 420,
    );
    final time = DateTime(2026, 1, 15, 21, 45);

    test('battery at 94% returns shouldCharge true', () {
      final result = decide(
        batteryPercent: 94,
        currentTime: time,
        chargingMode: ChargingMode.balanced,
        nightModeConfig: config,
        wasCharging: true,
      );
      expect(result.shouldCharge, true);
      expect(result.nightPhase, NightPhase.chargingToMax);
    });

    test('battery at 95% returns shouldCharge false (>= 95)', () {
      final result = decide(
        batteryPercent: 95,
        currentTime: time,
        chargingMode: ChargingMode.balanced,
        nightModeConfig: config,
        wasCharging: true,
      );
      expect(result.shouldCharge, false);
      expect(result.nightPhase, NightPhase.chargingToMax);
    });

    test('battery at 96% returns shouldCharge false', () {
      final result = decide(
        batteryPercent: 96,
        currentTime: time,
        chargingMode: ChargingMode.balanced,
        nightModeConfig: config,
        wasCharging: true,
      );
      expect(result.shouldCharge, false);
      expect(result.nightPhase, NightPhase.chargingToMax);
    });
  });

  group('night mode sleeping phase', () {
    // sleep=22:00 (1320), morning=07:00 (420), time=03:00
    final config = NightModeConfig(
      sleepTimeMinutes: 1320,
      morningTimeMinutes: 420,
    );
    final time = DateTime(2026, 1, 16, 3, 0);

    test('battery at 50% returns shouldCharge false', () {
      final result = decide(
        batteryPercent: 50,
        currentTime: time,
        chargingMode: ChargingMode.balanced,
        nightModeConfig: config,
        wasCharging: false,
      );
      expect(result.shouldCharge, false);
      expect(result.nightPhase, NightPhase.sleeping);
    });

    test('battery at 15% returns shouldCharge true (emergency overrides)', () {
      final result = decide(
        batteryPercent: 15,
        currentTime: time,
        chargingMode: ChargingMode.balanced,
        nightModeConfig: config,
        wasCharging: false,
      );
      expect(result.shouldCharge, true);
      expect(result.reason, 'emergency');
    });
  });

  group('midnight wrapping', () {
    final config = NightModeConfig(
      sleepTimeMinutes: 60,
      morningTimeMinutes: 480,
    );

    test('23:00 is hovering phase (sleepTime-120 = 23:00)', () {
      final result = decide(
        batteryPercent: 60,
        currentTime: DateTime(2026, 1, 15, 23, 0),
        chargingMode: ChargingMode.balanced,
        nightModeConfig: config,
        wasCharging: false,
      );
      expect(result.nightPhase, NightPhase.hovering);
    });

    test('00:30 is chargingToMax phase (sleepTime-30 = 00:30)', () {
      final result = decide(
        batteryPercent: 60,
        currentTime: DateTime(2026, 1, 16, 0, 30),
        chargingMode: ChargingMode.balanced,
        nightModeConfig: config,
        wasCharging: false,
      );
      expect(result.nightPhase, NightPhase.chargingToMax);
    });

    test('01:00 is sleeping phase', () {
      final result = decide(
        batteryPercent: 60,
        currentTime: DateTime(2026, 1, 16, 1, 0),
        chargingMode: ChargingMode.balanced,
        nightModeConfig: config,
        wasCharging: false,
      );
      expect(result.nightPhase, NightPhase.sleeping);
    });

    test('07:59 is sleeping phase', () {
      final result = decide(
        batteryPercent: 60,
        currentTime: DateTime(2026, 1, 16, 7, 59),
        chargingMode: ChargingMode.balanced,
        nightModeConfig: config,
        wasCharging: false,
      );
      expect(result.nightPhase, NightPhase.sleeping);
    });

    test('08:00 is normal phase', () {
      final result = decide(
        batteryPercent: 60,
        currentTime: DateTime(2026, 1, 16, 8, 0),
        chargingMode: ChargingMode.balanced,
        nightModeConfig: config,
        wasCharging: false,
      );
      expect(result.nightPhase, NightPhase.normal);
    });

    test('22:59 is normal phase (before hover window)', () {
      final result = decide(
        batteryPercent: 60,
        currentTime: DateTime(2026, 1, 15, 22, 59),
        chargingMode: ChargingMode.balanced,
        nightModeConfig: config,
        wasCharging: false,
      );
      expect(result.nightPhase, NightPhase.normal);
    });
  });

  group('ChargingState toJson', () {
    test('returns a map with all expected keys and correct values', () {
      final state = ChargingState(
        mode: ChargingMode.balanced,
        nightModeEnabled: true,
        currentPhase: NightPhase.hovering,
        batteryPercent: 75,
        usbChargerOn: true,
        isEmergency: false,
      );

      final json = state.toJson();

      expect(json['mode'], 'balanced');
      expect(json['nightModeEnabled'], true);
      expect(json['currentPhase'], 'hovering');
      expect(json['batteryPercent'], 75);
      expect(json['usbChargerOn'], true);
      expect(json['isEmergency'], false);
      expect(json.length, 6);
    });
  });

  group('shouldWriteChargerMode', () {
    final now = DateTime(2026, 1, 15, 12, 0);
    const reassert = Duration(minutes: 5);

    test('charging and unchanged: skip (firmware default already on)', () {
      expect(
        shouldWriteChargerMode(
          shouldCharge: true,
          lastApplied: true,
          now: now,
          lastWrite: now.subtract(const Duration(hours: 1)),
          reassertInterval: reassert,
        ),
        isFalse,
      );
    });

    test('target changed: always write', () {
      expect(
        shouldWriteChargerMode(
          shouldCharge: false,
          lastApplied: true,
          now: now,
          lastWrite: now,
          reassertInterval: reassert,
        ),
        isTrue,
      );
      expect(
        shouldWriteChargerMode(
          shouldCharge: true,
          lastApplied: false,
          now: now,
          lastWrite: now,
          reassertInterval: reassert,
        ),
        isTrue,
      );
    });

    test('lastApplied null forces a write (first tick / after reconnect)', () {
      expect(
        shouldWriteChargerMode(
          shouldCharge: true,
          lastApplied: null,
          now: now,
          lastWrite: now,
          reassertInterval: reassert,
        ),
        isTrue,
      );
    });

    test('discharging re-asserts once the interval elapses', () {
      expect(
        shouldWriteChargerMode(
          shouldCharge: false,
          lastApplied: false,
          now: now,
          lastWrite: now.subtract(const Duration(minutes: 4)),
          reassertInterval: reassert,
        ),
        isFalse,
      );
      // Interval elapsed: re-assert OFF because the firmware re-enables the
      // charger on its own.
      expect(
        shouldWriteChargerMode(
          shouldCharge: false,
          lastApplied: false,
          now: now,
          lastWrite: now.subtract(const Duration(minutes: 5)),
          reassertInterval: reassert,
        ),
        isTrue,
      );
    });

    test('discharging with no prior write re-asserts immediately', () {
      expect(
        shouldWriteChargerMode(
          shouldCharge: false,
          lastApplied: false,
          now: now,
          lastWrite: null,
          reassertInterval: reassert,
        ),
        isTrue,
      );
    });
  });
}
