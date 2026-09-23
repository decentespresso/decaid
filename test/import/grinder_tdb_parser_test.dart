import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/import/parsers/grinder_tdb_parser.dart';
import 'package:reaprime/src/models/data/grinder.dart';

void main() {
  late String tdbContent;
  late List<Grinder> grinders;

  setUpAll(() {
    final file = File('test/fixtures/de1app/plugins/DYE/grinders.tdb');
    tdbContent = file.readAsStringSync();
    grinders = GrinderTdbParser.parse(tdbContent);
  });

  group('GrinderTdbParser', () {
    test('parses every model with a spec, skipping empty specs', () {
      final models = grinders.map((g) => g.model).toList();
      expect(
        models,
        containsAll(['Niche Zero', 'Eureka Mignon', 'EK43', 'Baratza Encore']),
      );
      expect(models, isNot(contains('Retired Grinder')));
      expect(grinders.length, 4);
    });

    test('maps is_numeric 1 to numeric setting type', () {
      for (final model in ['Niche Zero', 'Eureka Mignon', 'EK43']) {
        final grinder = grinders.firstWhere((g) => g.model == model);
        expect(grinder.settingType, GrinderSettingType.numeric);
      }
    });

    test('maps is_numeric 0 to preset setting type with its values', () {
      final encore = grinders.firstWhere((g) => g.model == 'Baratza Encore');
      expect(encore.settingType, GrinderSettingType.preset);
      expect(encore.settingValues, ['Coarse', 'Fine', 'Medium']);
    });

    test('leaves settingValues null for numeric grinders', () {
      final niche = grinders.firstWhere((g) => g.model == 'Niche Zero');
      expect(niche.settingValues, isNull);
    });

    test('parses step values correctly', () {
      final niche = grinders.firstWhere((g) => g.model == 'Niche Zero');
      expect(niche.settingSmallStep, 1.0);
      expect(niche.settingBigStep, 10.0);

      final eureka = grinders.firstWhere((g) => g.model == 'Eureka Mignon');
      expect(eureka.settingSmallStep, 0.5);
      expect(eureka.settingBigStep, 1.0);

      final ek43 = grinders.firstWhere((g) => g.model == 'EK43');
      expect(ek43.settingSmallStep, 0.5);
      expect(ek43.settingBigStep, 1.0);
    });

    test('leaves burr fields empty because DYE does not record them', () {
      for (final grinder in grinders) {
        expect(grinder.burrs, isNull);
      }
    });
    test('missing is_numeric does not default to numeric', () {
      final result = GrinderTdbParser.parse(
        'Unknown {default Medium values {Coarse Medium Fine}}',
      );

      expect(result, hasLength(1));
      expect(result.single.settingType, GrinderSettingType.preset);
      expect(result.single.settingValues, ['Coarse', 'Medium', 'Fine']);
    });

  });
}
