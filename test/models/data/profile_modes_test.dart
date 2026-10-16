import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/data/profile.dart';

/// Model round-trip coverage for the additive Power / Lever pump-mode steps and
/// the HOLD transition. Keys are omitted (not null) for the other mode's
/// fields, a power step without its mandatory pressure limiter is a parse
/// error, and `transition:"hold"` survives a round-trip losslessly on any
/// machine (it must never silently degrade to a JUMP).
void main() {
  // A well-formed power-step JSON body (values-as-primitives).
  Map<String, dynamic> powerJson() => {
    'name': 'power pour',
    'pump': 'power',
    'transition': 'smooth',
    'volume': 100,
    'seconds': 25,
    'weight': 0.0,
    'temperature': 93,
    'sensor': 'coffee',
    'power': 2.0,
    'limiter': {'value': 9.0, 'range': 0.6},
  };

  // A well-formed lever-step JSON body (CLASSIC preset triple).
  Map<String, dynamic> leverJson() => {
    'name': 'lever pour',
    'pump': 'lever',
    'transition': 'smooth',
    'volume': 100,
    'seconds': 40,
    'weight': 0.0,
    'temperature': 92,
    'sensor': 'coffee',
    'pressure': 9.0,
    'leverSpring': 0.9,
    'leverGive': 1.5,
  };

  group('ProfileStepPower', () {
    test('dispatches from ProfileStep.fromJson on pump:"power"', () {
      final step = ProfileStep.fromJson(powerJson());
      expect(step, isA<ProfileStepPower>());
    });

    test('getTarget() returns the power (watts), not the limiter', () {
      final step = ProfileStep.fromJson(powerJson()) as ProfileStepPower;
      expect(step.getTarget(), 2.0);
      expect(step.power, 2.0);
      expect(step.limiter!.value, 9.0);
    });

    test('round-trips through toJson/fromJson', () {
      final original = ProfileStep.fromJson(powerJson());
      final restored = ProfileStep.fromJson(original.toJson());
      expect(restored, equals(original));
    });

    test('toJson carries pump:"power" and the power key, no lever keys', () {
      final json = (ProfileStep.fromJson(powerJson())).toJson();
      expect(json['pump'], 'power');
      expect(json['power'], 2.0);
      expect(json.containsKey('leverSpring'), isFalse);
      expect(json.containsKey('leverGive'), isFalse);
    });

    test('throws FormatException when the limiter is absent', () {
      final json = powerJson()..remove('limiter');
      expect(() => ProfileStep.fromJson(json), throwsFormatException);
    });

    test('throws FormatException when the limiter value is zero', () {
      final json = powerJson()..['limiter'] = {'value': 0, 'range': 0.6};
      expect(() => ProfileStep.fromJson(json), throwsFormatException);
    });
  });

  group('ProfileStepLever', () {
    test('dispatches from ProfileStep.fromJson on pump:"lever"', () {
      final step = ProfileStep.fromJson(leverJson());
      expect(step, isA<ProfileStepLever>());
    });

    test('getTarget() returns P0 (the pressure key)', () {
      final step = ProfileStep.fromJson(leverJson()) as ProfileStepLever;
      expect(step.getTarget(), 9.0);
      expect(step.pressure, 9.0);
      expect(step.leverSpring, 0.9);
      expect(step.leverGive, 1.5);
    });

    test('round-trips through toJson/fromJson without a limiter', () {
      final original = ProfileStep.fromJson(leverJson());
      final restored = ProfileStep.fromJson(original.toJson());
      expect(restored, equals(original));
    });

    test('round-trips with an optional flow-cap limiter', () {
      final json = leverJson()..['limiter'] = {'value': 6.0, 'range': 0.6};
      final original = ProfileStep.fromJson(json);
      final restored = ProfileStep.fromJson(original.toJson());
      expect(restored, equals(original));
      expect((restored as ProfileStepLever).limiter!.value, 6.0);
    });

    test('toJson carries pump:"lever" and the lever keys, no power key', () {
      final json = (ProfileStep.fromJson(leverJson())).toJson();
      expect(json['pump'], 'lever');
      expect(json['pressure'], 9.0);
      expect(json['leverSpring'], 0.9);
      expect(json['leverGive'], 1.5);
      expect(json.containsKey('power'), isFalse);
    });
  });

  group('HOLD transition', () {
    // A pressure step holding the previous achieved pressure, with a flow cap
    // (the canonical example) — target `pressure` stored as 0.
    Map<String, dynamic> holdPressureJson() => {
      'name': 'hold pressure',
      'pump': 'pressure',
      'transition': 'hold',
      'volume': 0,
      'seconds': 30,
      'temperature': 92,
      'sensor': 'coffee',
      'pressure': 0,
      'limiter': {'value': 6.0, 'range': 0.6},
    };

    test('parses transition:"hold" into TransitionType.hold', () {
      final step = ProfileStep.fromJson(holdPressureJson());
      expect(step, isA<ProfileStepPressure>());
      expect(step.transition, TransitionType.hold);
    });

    test('round-trips transition:"hold" losslessly (pressure)', () {
      final original = ProfileStep.fromJson(holdPressureJson());
      final restored = ProfileStep.fromJson(original.toJson());
      expect(restored, equals(original));
      expect(restored.transition, TransitionType.hold);
    });

    test('toJson re-emits transition:"hold" (not dropped, not JUMP)', () {
      final json = ProfileStep.fromJson(holdPressureJson()).toJson();
      // The load-bearing guarantee: a HOLD marker survives round-trip on ANY
      // machine and NEVER silently degrades to fast/JUMP.
      expect(json['transition'], 'hold');
    });

    test('round-trips HOLD-flow and HOLD-power', () {
      final flowJson = {
        'name': 'hold flow',
        'pump': 'flow',
        'transition': 'hold',
        'volume': 0,
        'seconds': 30,
        'temperature': 92,
        'sensor': 'coffee',
        'flow': 0,
        'limiter': {'value': 9.0, 'range': 0.9},
      };
      final powerJson = {
        'name': 'hold power',
        'pump': 'power',
        'transition': 'hold',
        'volume': 0,
        'seconds': 30,
        'temperature': 92,
        'sensor': 'coffee',
        'power': 0,
        'limiter': {'value': 9.0, 'range': 0.6},
      };
      for (final j in [flowJson, powerJson]) {
        final original = ProfileStep.fromJson(j);
        final restored = ProfileStep.fromJson(original.toJson());
        expect(restored, equals(original));
        expect(restored.transition, TransitionType.hold);
      }
    });

    test('SKEW: an enum lacking a transition name THROWS on byName '
        '(so an old client without "hold" gives a VISIBLE 400, never a '
        'silent JUMP)', () {
      // This is exactly the mechanism by which `transition:"hold"` was chosen
      // over an additive boolean key: `byName` on an unknown name throws
      // ArgumentError, which the fromJson factory propagates to a clean 400.
      // (A dropped additive key would round-trip to a silent JUMP — forbidden.)
      expect(
        () => TransitionType.values.byName('definitely-not-a-transition'),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('power exit condition', () {
    // A pressure step exiting early on hydraulic power (W = 0.1*P*F).
    Map<String, dynamic> pressureStepPowerOverJson() => {
      'name': 'ramp to power',
      'pump': 'pressure',
      'transition': 'fast',
      'volume': 0,
      'seconds': 30,
      'temperature': 92,
      'sensor': 'coffee',
      'pressure': 9.0,
      'exit': {'type': 'power', 'condition': 'over', 'value': 4.5},
    };

    test('parses exit type:"power" into ExitType.power', () {
      final step = ProfileStep.fromJson(pressureStepPowerOverJson());
      expect(step.exit, isNotNull);
      expect(step.exit!.type, ExitType.power);
      expect(step.exit!.condition, ExitCondition.over);
      expect(step.exit!.value, 4.5);
    });

    test('round-trips a pressure-step power-over exit losslessly', () {
      final original = ProfileStep.fromJson(pressureStepPowerOverJson());
      final restored = ProfileStep.fromJson(original.toJson());
      expect(restored, equals(original));
      expect(restored.exit!.type, ExitType.power);
    });

    test('round-trips a flow-step power-under exit losslessly', () {
      final json = {
        'name': 'flow to power',
        'pump': 'flow',
        'transition': 'fast',
        'volume': 0,
        'seconds': 20,
        'temperature': 90,
        'sensor': 'coffee',
        'flow': 2.0,
        'exit': {'type': 'power', 'condition': 'under', 'value': 2.0},
      };
      final original = ProfileStep.fromJson(json);
      final restored = ProfileStep.fromJson(original.toJson());
      expect(restored, equals(original));
      expect(restored.exit!.type, ExitType.power);
      expect(restored.exit!.condition, ExitCondition.under);
    });

    test('toJson re-emits type:"power" (not dropped, not degraded to P/F)', () {
      final json = ProfileStep.fromJson(pressureStepPowerOverJson()).toJson();
      // The load-bearing guarantee: a power exit survives round-trip on ANY
      // machine and NEVER silently becomes a pressure/flow exit.
      expect(json['exit']['type'], 'power');
    });

    test('StepExitCondition round-trips directly', () {
      const exit = StepExitCondition(
        type: ExitType.power,
        condition: ExitCondition.over,
        value: 4.5,
      );
      expect(StepExitCondition.fromJson(exit.toJson()), equals(exit));
    });

    test('SKEW: an ExitType lacking "power" THROWS on byName (an old client '
        'gives a VISIBLE 400, never a silent pressure/flow exit)', () {
      // The same mechanism that makes `type:"power"` an enum value rather than
      // an additive key: byName on an unknown name throws ArgumentError, which
      // fromJson propagates to a clean 400.
      expect(
        () => ExitType.values.byName('definitely-not-an-exit-type'),
        throwsA(isA<ArgumentError>()),
      );
      // A knowing client resolves it fine.
      expect(ExitType.values.byName('power'), ExitType.power);
    });
  });

  group('whole-Profile round-trip with novel pump-mode steps', () {
    test('a profile mixing flow / power / lever round-trips', () {
      final profileJson = {
        'version': '2',
        'title': 'mixed modes',
        'notes': '',
        'author': 'test',
        'beverage_type': 'espresso',
        'steps': <dynamic>[
          {
            'name': 'fill',
            'pump': 'flow',
            'transition': 'fast',
            'volume': 100,
            'seconds': 10,
            'temperature': 92,
            'sensor': 'coffee',
            'flow': 8.0,
          },
          powerJson(),
          leverJson(),
        ],
        'tank_temperature': 90.0,
        'target_weight': 36.0,
        'target_volume_count_start': 0,
      };

      final profile = Profile.fromJson(profileJson);
      expect(profile.steps, hasLength(3));
      expect(profile.steps[1], isA<ProfileStepPower>());
      expect(profile.steps[2], isA<ProfileStepLever>());

      final restored = Profile.fromJson(profile.toJson());
      expect(restored, equals(profile));
    });

    test('a profile with a HOLD step round-trips losslessly (the '
        '"viewed/synced on a DE1" case — model tolerance is NOT gated)', () {
      final profileJson = {
        'version': '2',
        'title': 'hold pour',
        'notes': '',
        'author': 'test',
        'beverage_type': 'espresso',
        'steps': <dynamic>[
          {
            'name': 'fill',
            'pump': 'flow',
            'transition': 'fast',
            'volume': 100,
            'seconds': 10,
            'temperature': 92,
            'sensor': 'coffee',
            'flow': 8.0,
          },
          {
            'name': 'hold pressure',
            'pump': 'pressure',
            'transition': 'hold',
            'volume': 0,
            'seconds': 30,
            'temperature': 92,
            'sensor': 'coffee',
            'pressure': 0,
            'limiter': {'value': 6.0, 'range': 0.6},
          },
        ],
        'tank_temperature': 90.0,
        'target_volume_count_start': 0,
      };

      final profile = Profile.fromJson(profileJson);
      expect(profile.steps[1].transition, TransitionType.hold);
      final restored = Profile.fromJson(profile.toJson());
      expect(restored, equals(profile), reason: 'no data loss on round-trip');
      // The HOLD marker survives — it is NOT silently rewritten to fast/JUMP.
      expect(restored.toJson()['steps'][1]['transition'], 'hold');
    });
  });
}
