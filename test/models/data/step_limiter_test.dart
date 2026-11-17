import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/data/profile.dart';
import 'package:reaprime/src/models/data/profile_hash.dart';

void main() {
  Map<String, dynamic> flowStepJson({dynamic limiter}) => {
    'name': 'preinfusion',
    'pump': 'flow',
    'transition': 'fast',
    'volume': 100,
    'seconds': 20,
    'weight': 0,
    'temperature': 83.5,
    'sensor': 'coffee',
    'flow': 12,
    'limiter': limiter,
  };

  Map<String, dynamic> profileJsonWithLimiter(dynamic limiter) => {
    'version': '2',
    'title': 'limiter canonicalization',
    'beverage_type': 'espresso',
    'steps': <dynamic>[flowStepJson(limiter: limiter)],
    'target_volume': 0,
    'target_weight': 40,
    'target_volume_count_start': 2,
    'tank_temperature': 0,
  };

  Profile profileWithLimiter(dynamic limiter) =>
      Profile.fromJson(profileJsonWithLimiter(limiter));

  Matcher refusesNaming(String field) => throwsA(
    isA<FormatException>().having(
      (e) => e.message,
      'message',
      'limiter "$field" must be a number',
    ),
  );

  group('StepLimiter.fromJson - unchanged behaviour', () {
    test('parses a complete limiter', () {
      final limiter = StepLimiter.fromJson({'value': 9.0, 'range': 0.6});

      expect(limiter.value, 9.0);
      expect(limiter.range, 0.6);
    });

    test('round-trips a complete limiter through toJson', () {
      final original = StepLimiter.fromJson({'value': 9.0, 'range': 0.6});

      expect(StepLimiter.fromJson(original.toJson()), equals(original));
    });

    test('parses the string spelling used by the bundled defaults', () {
      final limiter = StepLimiter.fromJson({'value': '8.0', 'range': '0.6'});

      expect(limiter.value, 8.0);
      expect(limiter.range, 0.6);
    });

    test('form (b): an explicit range 0 parses as range 0', () {
      final limiter = StepLimiter.fromJson({'value': 6, 'range': 0});

      expect(limiter, equals(const StepLimiter(value: 6, range: 0)));
      expect(limiter.toJson(), {'value': 6.0, 'range': 0.0});
    });

    test('an explicit range 0 with value 0 parses as an OFF limiter', () {
      final limiter = StepLimiter.fromJson({'value': 0, 'range': 0});

      expect(limiter, equals(const StepLimiter(value: 0, range: 0)));
    });
  });

  group('StepLimiter.fromJson - a missing range is refused', () {
    test('form (a): a value-only limiter refuses by naming "range"', () {
      expect(() => StepLimiter.fromJson({'value': 6}), refusesNaming('range'));
    });

    test('form (c): an explicit null range refuses by naming "range"', () {
      expect(
        () => StepLimiter.fromJson({'value': 6, 'range': null}),
        refusesNaming('range'),
      );
    });

    test('the undo-after-arm body {value: 0} refuses by naming "range"', () {
      expect(() => StepLimiter.fromJson({'value': 0}), refusesNaming('range'));
    });

    test('the keypad body {value: 2.5} refuses by naming "range"', () {
      expect(
        () => StepLimiter.fromJson({'value': 2.5}),
        refusesNaming('range'),
      );
    });
  });

  group('StepLimiter.fromJson - refusals name the field', () {
    test('an empty limiter refuses by naming "value"', () {
      expect(
        () => StepLimiter.fromJson(<String, dynamic>{}),
        refusesNaming('value'),
      );
    });

    test('form (d): a range-only limiter refuses by naming "value"', () {
      expect(() => StepLimiter.fromJson({'range': 1}), refusesNaming('value'));
    });

    test('form (e): an explicitly null value refuses by naming "value"', () {
      expect(
        () => StepLimiter.fromJson({'value': null, 'range': 1}),
        refusesNaming('value'),
      );
    });

    test('an unparseable value refuses by naming "value"', () {
      expect(
        () => StepLimiter.fromJson({'value': 'abc', 'range': 0.6}),
        refusesNaming('value'),
      );
    });

    test('form (f): a non-numeric range refuses by naming "range"', () {
      expect(
        () => StepLimiter.fromJson({'value': 6, 'range': 'x'}),
        refusesNaming('range'),
      );
    });
  });

  group('StepLimiter.fromJson - a JSON type that is not a number', () {
    for (final (json, field) in [
      (<String, dynamic>{'value': 6, 'range': true}, 'range'),
      (<String, dynamic>{'value': 6, 'range': <dynamic>[]}, 'range'),
      (<String, dynamic>{'value': 6, 'range': <String, dynamic>{}}, 'range'),
      (<String, dynamic>{'value': true, 'range': 1}, 'value'),
      (
        <String, dynamic>{
          'value': <dynamic>[1],
          'range': 1,
        },
        'value',
      ),
    ]) {
      test('$json refuses by naming "$field"', () {
        expect(() => StepLimiter.fromJson(json), refusesNaming(field));
      });
    }
  });

  group('steps carrying a rangeless limiter', () {
    test('a flow step refuses one by naming "range"', () {
      expect(
        () => ProfileStep.fromJson(flowStepJson(limiter: {'value': 0.1})),
        refusesNaming('range'),
      );
    });

    test('a flow step accepts an explicit range 0', () {
      final step = ProfileStep.fromJson(
        flowStepJson(limiter: {'value': 0.1, 'range': 0}),
      );

      expect(step.limiter, equals(const StepLimiter(value: 0.1, range: 0)));
    });

    test('an absent limiter is still null, not defaulted', () {
      final step = ProfileStep.fromJson(flowStepJson(limiter: null));

      expect(step.limiter, isNull);
      expect(step.toJson()['limiter'], isNull);
    });
  });

  group('profile hash', () {
    test('a profile with a rangeless limiter refuses before it has a hash', () {
      expect(() => profileWithLimiter({'value': 2.5}), refusesNaming('range'));
    });

    test('a complete limiter keeps the hash it has today', () {
      final profile = profileWithLimiter({'value': 6, 'range': 3});

      expect(
        ProfileHash.calculateProfileHash(profile),
        equals('profile:d2e17095ab0aba1341a2'),
      );
    });

    test('a null-limiter profile keeps the hash it has today', () {
      final profile = profileWithLimiter(null);

      expect(
        ProfileHash.calculateProfileHash(profile),
        equals('profile:ce03a28e18f849d671ef'),
      );
    });
  });
}
