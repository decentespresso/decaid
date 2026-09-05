import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/data/profile.dart';
import 'package:reaprime/src/models/data/profile_hash.dart';

/// Parse coverage for [StepLimiter]. A limiter's `range` (the falloff band
/// below the cap) is optional on the wire: absent or null means a hard cap at
/// `value`, which is what range 0 already encodes on the DE1 and what the
/// mock's clamp branch already implements. `value` stays required and is
/// refused by name, because a limiter without a value would silently become an
/// OFF limiter on the machine (Decal audit finding F-048, server half).
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

  Profile profileWithLimiter(dynamic limiter) => Profile.fromJson({
    'version': '2',
    'title': 'limiter canonicalization',
    'beverage_type': 'espresso',
    'steps': <dynamic>[flowStepJson(limiter: limiter)],
    'target_volume': 0,
    'target_weight': 40,
    'target_volume_count_start': 2,
    'tank_temperature': 0,
  });

  group('StepLimiter.fromJson — unchanged behaviour', () {
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
  });

  group('StepLimiter.fromJson — optional range (F-048)', () {
    test('a value-only limiter parses as a hard cap (range 0)', () {
      final limiter = StepLimiter.fromJson({'value': 0.1});

      expect(limiter.value, 0.1);
      expect(limiter.range, 0.0);
      expect(limiter, equals(const StepLimiter(value: 0.1, range: 0)));
    });

    test('toJson materialises the defaulted range as 0.0', () {
      final json = StepLimiter.fromJson({'value': 0.1}).toJson();

      expect(json['value'], 0.1);
      expect(json['range'], 0.0);
    });

    test('an explicit null range behaves like an absent one', () {
      final limiter = StepLimiter.fromJson({'value': 0.1, 'range': null});

      expect(limiter, equals(const StepLimiter(value: 0.1, range: 0)));
    });

    test('the undo-after-arm body parses to an OFF limiter', () {
      final limiter = StepLimiter.fromJson({'value': 0});

      expect(limiter.value, 0.0);
      expect(limiter.range, 0.0);
    });

    test('the keypad body parses', () {
      final limiter = StepLimiter.fromJson({'value': 2.5});

      expect(limiter, equals(const StepLimiter(value: 2.5, range: 0)));
    });
  });

  group('StepLimiter.fromJson — refusals name the field', () {
    test('an empty limiter refuses by naming "value"', () {
      expect(
        () => StepLimiter.fromJson(<String, dynamic>{}),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('limiter "value"'),
          ),
        ),
      );
    });

    test('a range-only limiter refuses by naming "value"', () {
      expect(
        () => StepLimiter.fromJson({'range': 0.6}),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('limiter "value"'),
          ),
        ),
      );
    });

    test('an explicitly null value refuses by naming "value"', () {
      expect(
        () => StepLimiter.fromJson({'value': null}),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('limiter "value"'),
          ),
        ),
      );
    });

    test('an unparseable value refuses by naming "value"', () {
      expect(
        () => StepLimiter.fromJson({'value': 'abc', 'range': 0.6}),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('limiter "value"'),
          ),
        ),
      );
    });

    test('a garbage range refuses by naming "range" rather than capping', () {
      expect(
        () => StepLimiter.fromJson({'value': 1, 'range': 'abc'}),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('limiter "range"'),
          ),
        ),
      );
    });
  });

  group('steps carrying a rangeless limiter', () {
    test('a flow step accepts one', () {
      final step = ProfileStep.fromJson(flowStepJson(limiter: {'value': 0.1}));

      expect(step.limiter, equals(const StepLimiter(value: 0.1, range: 0)));
    });

    test('an absent limiter is still null, not defaulted', () {
      final step = ProfileStep.fromJson(flowStepJson(limiter: null));

      expect(step.limiter, isNull);
      expect(step.toJson()['limiter'], isNull);
    });
  });

  group('profile hash', () {
    test('a rangeless limiter hashes as an explicit range 0', () {
      final defaulted = profileWithLimiter({'value': 2.5});
      final explicit = profileWithLimiter({'value': 2.5, 'range': 0});

      expect(
        ProfileHash.calculateProfileHash(defaulted),
        equals(ProfileHash.calculateProfileHash(explicit)),
      );
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
