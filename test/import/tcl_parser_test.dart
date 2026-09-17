import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/import/parsers/tcl_parser.dart';

void main() {
  group('TclParser', () {
    group('simple key-value pairs', () {
      test('parses integer value', () {
        final result = TclParser.parse('clock 1699432544\n');
        expect(result['clock'], equals('1699432544'));
      });

      test('parses string value without braces', () {
        final result = TclParser.parse('foo bar\n');
        expect(result['foo'], equals('bar'));
      });

      test('parses multiple simple pairs', () {
        final result = TclParser.parse('clock 1699432544\nversion 2\n');
        expect(result['clock'], equals('1699432544'));
        expect(result['version'], equals('2'));
      });

      test('ignores blank lines', () {
        final result = TclParser.parse('clock 1\n\nversion 2\n');
        expect(result.length, equals(2));
      });
    });

    group('braced values', () {
      test('parses numeric array from braces', () {
        final result = TclParser.parse('espresso_elapsed {0.0 0.25 0.5}\n');
        expect(result['espresso_elapsed'], equals(['0.0', '0.25', '0.5']));
      });

      test('parses single integer in braces as string', () {
        final result = TclParser.parse('espresso_enjoyment {80}\n');
        expect(result['espresso_enjoyment'], equals('80'));
      });

      test('parses single float in braces as string', () {
        final result = TclParser.parse('grinder_dose_weight {18.5}\n');
        expect(result['grinder_dose_weight'], equals('18.5'));
      });

      test('parses braced string (non-numeric) as String', () {
        final result = TclParser.parse('bean_brand {Banibeans}\n');
        expect(result['bean_brand'], equals('Banibeans'));
      });

      test('parses braced multi-word string as String', () {
        final result = TclParser.parse('bean_type {Colombia Huila}\n');
        expect(result['bean_type'], equals('Colombia Huila'));
      });

      test('empty braces produce empty string', () {
        final result = TclParser.parse('some_key {}\n');
        expect(result['some_key'], equals(''));
      });
    });

    group('nested multi-line blocks', () {
      test('parses nested block into a map', () {
        const input =
            'settings {\n'
            '\tbean_brand {Banibeans}\n'
            '\tbean_type {Colombia Huila}\n'
            '}\n';
        final result = TclParser.parse(input);
        expect(result['settings'], isA<Map>());
        final settings = result['settings'] as Map;
        expect(settings['bean_brand'], equals('Banibeans'));
        expect(settings['bean_type'], equals('Colombia Huila'));
      });

      test('parses numeric array inside nested block', () {
        const input =
            'settings {\n'
            '\tsome_list {1.0 2.0 3.0}\n'
            '}\n';
        final result = TclParser.parse(input);
        final settings = result['settings'] as Map;
        expect(settings['some_list'], equals(['1.0', '2.0', '3.0']));
      });

      test('parses numeric value inside nested block as string', () {
        const input =
            'settings {\n'
            '\tgrinder_dose_weight {18.5}\n'
            '}\n';
        final result = TclParser.parse(input);
        final settings = result['settings'] as Map;
        expect(settings['grinder_dose_weight'], equals('18.5'));
      });
    });

    group('backslash-escaped spaces in keys', () {
      test('unescapes backslash-space in key', () {
        final result = TclParser.parse(
          r'Niche\ Zero {setting_type numeric small_step 1}'
          '\n',
        );
        expect(result.containsKey('Niche Zero'), isTrue);
      });

      test('parses inline block as map when it has key-value pairs', () {
        final result = TclParser.parse(
          r'Niche\ Zero {setting_type numeric small_step 1 big_step 5}'
          '\n',
        );
        final entry = result['Niche Zero'] as Map;
        expect(entry['setting_type'], equals('numeric'));
        expect(entry['small_step'], equals('1'));
        expect(entry['big_step'], equals('5'));
      });

      test('parses nested braces within inline block', () {
        final result = TclParser.parse(
          r'Niche\ Zero {setting_type numeric burrs {63mm conical}}'
          '\n',
        );
        final entry = result['Niche Zero'] as Map;
        expect(entry['setting_type'], equals('numeric'));
        expect(entry['burrs'], equals('63mm conical'));
      });
    });

    group('number array detection', () {
      test('all-number tokens treated as list', () {
        final result = TclParser.parse('data {1.0 2.5 -3.0}\n');
        expect(result['data'], equals(['1.0', '2.5', '-3.0']));
      });

      test('mixed text tokens NOT treated as list', () {
        final result = TclParser.parse('burrs {63mm conical}\n');
        expect(result['burrs'], isA<String>());
        expect(result['burrs'], equals('63mm conical'));
      });

      test('single non-numeric token is a string', () {
        final result = TclParser.parse('profile_title {Default}\n');
        expect(result['profile_title'], isA<String>());
        expect(result['profile_title'], equals('Default'));
      });
    });

    group('full .shot fixture file', () {
      late Map<String, dynamic> parsed;

      setUpAll(() {
        final file = File('test/fixtures/de1app/history/20231108T091544.shot');
        parsed = TclParser.parse(file.readAsStringSync());
      });

      test('parses clock as string', () {
        expect(parsed['clock'], equals('1699432544'));
      });

      test('espresso_elapsed is a list of string numbers', () {
        expect(parsed['espresso_elapsed'], isA<List>());
        final list = parsed['espresso_elapsed'] as List;
        expect(list.first, equals('0.0'));
        expect(list.length, equals(9));
      });

      test('espresso_pressure is a list', () {
        expect(parsed['espresso_pressure'], isA<List>());
      });

      test('settings is a Map', () {
        expect(parsed['settings'], isA<Map>());
      });

      test('settings.bean_brand is a string', () {
        final settings = parsed['settings'] as Map;
        expect(settings['bean_brand'], equals('Banibeans'));
      });

      test('settings.bean_type is a string', () {
        final settings = parsed['settings'] as Map;
        expect(settings['bean_type'], equals('Colombia Huila'));
      });

      test('settings.grinder_dose_weight is a string', () {
        final settings = parsed['settings'] as Map;
        expect(settings['grinder_dose_weight'], equals('18.5'));
      });

      test('settings.drink_weight is a string', () {
        final settings = parsed['settings'] as Map;
        expect(settings['drink_weight'], equals('38.0'));
      });

      test('espresso_state_change is a list', () {
        expect(parsed['espresso_state_change'], isA<List>());
      });
    });

    group('splitList', () {
      test('splits a plain Tcl list', () {
        expect(TclParser.splitList('Coarse Fine Medium'), [
          'Coarse',
          'Fine',
          'Medium',
        ]);
      });

      test('keeps braced elements that contain spaces intact', () {
        expect(TclParser.splitList('{Extra Fine} Medium'), [
          'Extra Fine',
          'Medium',
        ]);
      });

      test('returns an empty list for an empty string', () {
        expect(TclParser.splitList(''), isEmpty);
      });
    });

    group('full .tdb fixture file', () {
      late Map<String, dynamic> parsed;

      setUpAll(() {
        final file = File('test/fixtures/de1app/plugins/DYE/grinders.tdb');
        parsed = TclParser.parse(file.readAsStringSync());
      });

      test('Niche Zero key exists', () {
        expect(parsed.containsKey('Niche Zero'), isTrue);
      });

      test('Eureka Mignon key exists', () {
        expect(parsed.containsKey('Eureka Mignon'), isTrue);
      });

      test('EK43 key exists (no escaping needed)', () {
        expect(parsed.containsKey('EK43'), isTrue);
      });

      test('Niche Zero has nested specs as Map', () {
        expect(parsed['Niche Zero'], isA<Map>());
      });

      test('Niche Zero is_numeric is 1', () {
        final niche = parsed['Niche Zero'] as Map;
        expect(niche['is_numeric'], equals('1'));
      });

      test('Niche Zero small_step is 1', () {
        final niche = parsed['Niche Zero'] as Map;
        expect(niche['small_step'], equals('1'));
      });

      test('Eureka Mignon small_step is 0.5', () {
        final eureka = parsed['Eureka Mignon'] as Map;
        expect(eureka['small_step'], equals('0.5'));
      });

      test('Baratza Encore values keeps its three settings', () {
        final encore = parsed['Baratza Encore'] as Map;
        expect(
          TclParser.splitList(encore['values'].toString()),
          equals(['Coarse', 'Fine', 'Medium']),
        );
      });
    });
  });
}
