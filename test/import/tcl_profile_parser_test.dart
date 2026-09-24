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
  });
}
