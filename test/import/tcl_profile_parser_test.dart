import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/import/parsers/tcl_profile_parser.dart';
import 'package:reaprime/src/models/data/profile.dart';

void main() {
  group('TclProfileParser', () {
    group('parses a legacy advanced-shot (settings_2c) profile', () {
      late String content;

      setUpAll(() async {
        content = await File(
          'test/fixtures/de1app/profiles/legacy_lever.tcl',
        ).readAsString();
      });

      test('title, author, notes come from the flat fields', () {
        final record = TclProfileParser.parse(content);
        expect(record.profile.title, equals('Legacy Lever'));
        expect(record.profile.author, equals('Test Author'));
        expect(
          record.profile.notes,
          equals('A pre-v2 profile that only exists as a legacy .tcl file.'),
        );
      });

      test('parses all advanced_shot frames as steps', () {
        final record = TclProfileParser.parse(content);
        expect(record.profile.steps, hasLength(3));
        expect(record.profile.steps.first.name, equals('preinfusion start'));
      });

      test('parses an exit condition on a frame', () {
        final record = TclProfileParser.parse(content);
        final withExit = record.profile.steps[1];
        expect(withExit.exit, isNotNull);
        expect(withExit.exit!.type, equals(ExitType.pressure));
        expect(withExit.exit!.condition, equals(ExitCondition.over));
        expect(withExit.exit!.value, equals(3.0));
      });

      test('frame without exit_if has no exit condition', () {
        final record = TclProfileParser.parse(content);
        expect(record.profile.steps.first.exit, isNull);
      });

      test('parses a limiter from max_flow_or_pressure_range', () {
        final record = TclProfileParser.parse(content);
        expect(record.profile.steps.first.limiter, isNotNull);
        expect(record.profile.steps.first.limiter!.range, equals(0.6));
      });

      test('target weight and beverage type come through', () {
        final record = TclProfileParser.parse(content);
        expect(record.profile.targetWeight, equals(36));
        expect(record.profile.beverageType, equals(BeverageType.espresso));
      });
    });

    group('advanced_shot with a single frame', () {
      // TclParser.parse's generic value-collapsing strips the single
      // frame's own wrapping braces (nothing to disambiguate it from a
      // plain string), so the profile parser has to recognize that its
      // whole `advanced_shot` value is already one frame instead of
      // re-splitting it into several bogus ones.
      const content = '''
advanced_shot {{name {Single shot} pump pressure pressure 9 transition fast temperature 90 sensor coffee seconds 5 volume 0 weight 0}}
author Test Author
profile_title {Single Frame}
settings_profile_type settings_2c
''';

      test('keeps the single frame intact instead of splitting its fields', () {
        final record = TclProfileParser.parse(content);
        expect(record.profile.steps, hasLength(1));
        expect(record.profile.steps.first.name, equals('Single shot'));
        expect(record.profile.steps.first.getTarget(), equals(9.0));
      });
    });

    group('title/notes text that looks like an even-length key/value list', () {
      const content = '''
advanced_shot {{name step pump pressure pressure 9 transition fast temperature 90 sensor coffee seconds 5 volume 0 weight 0}}
profile_title {My Best Coffee Shot}
profile_notes {One Two Three Four}
settings_profile_type settings_2c
''';

      test('reconstructs the flat title instead of parsing it as a map', () {
        final record = TclProfileParser.parse(content);
        expect(record.profile.title, equals('My Best Coffee Shot'));
        expect(record.profile.notes, equals('One Two Three Four'));
      });
    });

    group('malformed advanced_shot frame', () {
      test('rejects the whole profile when a frame has too few tokens', () {
        const content = '''
advanced_shot {{name} {name ramp pump pressure pressure 9 transition fast temperature 90 sensor coffee seconds 5 volume 0 weight 0}}
settings_profile_type settings_2c
''';
        expect(
          () => TclProfileParser.parse(content),
          throwsA(isA<MalformedProfileFrameException>()),
        );
      });

      test('rejects the whole profile when a middle frame has an odd '
          'trailing key', () {
        const content = '''
advanced_shot {{name ramp pump pressure pressure 9 transition fast temperature 90 sensor coffee seconds 5 volume 0 weight 0} {name second pump pressure pressure 9 transition} {name third pump pressure pressure 9 transition fast temperature 90 sensor coffee seconds 5 volume 0 weight 0}}
settings_profile_type settings_2c
''';
        expect(
          () => TclProfileParser.parse(content),
          throwsA(isA<MalformedProfileFrameException>()),
        );
      });
    });

    group('profile type aliases', () {
      test('rejects settings_2a profiles', () {
        const content = '''
profile_title {Pressure profile}
settings_profile_type settings_2a
espresso_pressure 9.0
''';
        expect(
          () => TclProfileParser.parse(content),
          throwsA(isA<UnsupportedProfileTypeException>()),
        );
      });

      test('rejects settings_2b profiles', () {
        const content = '''
profile_title {Flow profile}
settings_profile_type settings_2b
flow_profile_hold 2
''';
        expect(
          () => TclProfileParser.parse(content),
          throwsA(isA<UnsupportedProfileTypeException>()),
        );
      });

      test('rejects the settings_2/settings_profile_pressure alias for '
          'settings_2a', () {
        for (final alias in ['settings_2', 'settings_profile_pressure']) {
          final content =
              '''
settings_profile_type $alias
''';
          expect(
            () => TclProfileParser.parse(content),
            throwsA(isA<UnsupportedProfileTypeException>()),
            reason: 'alias: $alias',
          );
        }
      });

      test('rejects the settings_profile_flow alias for settings_2b', () {
        const content = '''
settings_profile_type settings_profile_flow
''';
        expect(
          () => TclProfileParser.parse(content),
          throwsA(isA<UnsupportedProfileTypeException>()),
        );
      });

      test('accepts the settings_2c2/settings_profile_advanced aliases for '
          'settings_2c', () {
        for (final alias in ['settings_2c2', 'settings_profile_advanced']) {
          final content =
              '''
advanced_shot {{name ramp pump pressure pressure 9 transition fast temperature 90 sensor coffee seconds 5 volume 0 weight 0}}
profile_title Alias
settings_profile_type $alias
''';
          final record = TclProfileParser.parse(content);
          expect(record.profile.steps, hasLength(1), reason: 'alias: $alias');
        }
      });

      test('rejects an unrecognized profile type', () {
        const content = '''
settings_profile_type something_unknown
''';
        expect(
          () => TclProfileParser.parse(content),
          throwsA(isA<UnsupportedProfileTypeException>()),
        );
      });
    });

    group('beverage type mapping', () {
      const stepsOnly = '''
advanced_shot {{name ramp pump pressure pressure 9 transition fast temperature 90 sensor coffee seconds 5 volume 0 weight 0}}
profile_title Beverage
settings_profile_type settings_2c
''';

      test('maps tea, filter, and tea_portafilter to pourover', () {
        for (final alias in ['tea', 'filter', 'tea_portafilter']) {
          final content = '$stepsOnly\nbeverage_type $alias\n';
          final record = TclProfileParser.parse(content);
          expect(
            record.profile.beverageType,
            equals(BeverageType.pourover),
            reason: 'alias: $alias',
          );
        }
      });

      test('maps descale to cleaning', () {
        final content = '$stepsOnly\nbeverage_type descale\n';
        final record = TclProfileParser.parse(content);
        expect(record.profile.beverageType, equals(BeverageType.cleaning));
      });

      test('rejects an unrecognized beverage type instead of defaulting to '
          'espresso', () {
        final content = '$stepsOnly\nbeverage_type not_a_real_type\n';
        expect(
          () => TclProfileParser.parse(content),
          throwsA(isA<UnsupportedBeverageTypeException>()),
        );
      });
    });
  });
}
