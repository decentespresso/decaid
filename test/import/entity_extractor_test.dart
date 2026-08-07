import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/import/entity_extractor.dart';
import 'package:reaprime/src/import/parsers/shot_v2_json_parser.dart';
import 'package:reaprime/src/models/data/grinder.dart';
import 'package:reaprime/src/models/data/profile.dart';
import 'package:reaprime/src/models/data/shot_record.dart';
import 'package:reaprime/src/models/data/workflow.dart';

ParsedShot makeShot({
  String? beanBrand,
  String? beanType,
  String? beanNotes,
  String? roastDate,
  String? roastLevel,
  String? grinderModel,
  String? grinderSetting,
}) {
  final profile = Profile(
    version: '2',
    title: 'Test Profile',
    notes: '',
    author: 'Test',
    beverageType: BeverageType.espresso,
    steps: const [],
    targetVolumeCountStart: 0,
    tankTemperature: 0,
  );

  final workflow = Workflow(
    id: 'test-workflow-id',
    name: 'Test Workflow',
    profile: profile,
    steamSettings: SteamSettings.defaults(),
    hotWaterData: HotWaterData.defaults(),
    rinseData: RinseData.defaults(),
  );

  final shot = ShotRecord(
    id: 'test-shot-${DateTime.now().microsecondsSinceEpoch}',
    timestamp: DateTime.now(),
    measurements: const [],
    workflow: workflow,
  );

  return ParsedShot(
    shot: shot,
    beanBrand: beanBrand,
    beanType: beanType,
    beanNotes: beanNotes,
    roastDate: roastDate,
    roastLevel: roastLevel,
    grinderModel: grinderModel,
    grinderSetting: grinderSetting,
  );
}

void main() {
  late EntityExtractor extractor;

  setUp(() {
    extractor = EntityExtractor();
  });

  group('EntityExtractor.extract', () {
    group('bean deduplication', () {
      test('deduplicates beans by brand+type (3 shots, 2 unique beans)', () {
        final shots = [
          makeShot(beanBrand: 'Roaster A', beanType: 'Ethiopia'),
          makeShot(beanBrand: 'Roaster A', beanType: 'Ethiopia'),
          makeShot(beanBrand: 'Roaster B', beanType: 'Colombia'),
        ];

        final result = extractor.extract(shots);

        expect(result.beans.length, 2);
        final brands = result.beans.map((b) => b.roaster).toSet();
        expect(brands, containsAll(['Roaster A', 'Roaster B']));
      });

      test('deduplication is case-insensitive', () {
        final shots = [
          makeShot(beanBrand: 'Roaster A', beanType: 'ethiopia'),
          makeShot(beanBrand: 'ROASTER A', beanType: 'ETHIOPIA'),
        ];

        final result = extractor.extract(shots);

        expect(result.beans.length, 1);
      });

      test('creates one BeanBatch per unique (bean, roastDate)', () {
        final shots = [
          makeShot(
            beanBrand: 'Roaster A',
            beanType: 'Ethiopia',
            roastDate: '2024-01-01',
          ),
          makeShot(
            beanBrand: 'Roaster A',
            beanType: 'Ethiopia',
            roastDate: '2024-02-01',
          ),
          makeShot(
            beanBrand: 'Roaster A',
            beanType: 'Ethiopia',
            roastDate: '2024-01-01',
          ),
        ];

        final result = extractor.extract(shots);

        expect(result.beans.length, 1);
        expect(result.batches.length, 2);

        final batchBeanIds = result.batches.map((b) => b.beanId).toSet();
        expect(batchBeanIds.length, 1);
        expect(batchBeanIds.first, result.beans.first.id);
      });

      test('batches have correct beanId linkage', () {
        final shots = [
          makeShot(beanBrand: 'Alpha', beanType: 'Kenya'),
          makeShot(beanBrand: 'Beta', beanType: 'Brazil'),
        ];

        final result = extractor.extract(shots);

        final beanIds = result.beans.map((b) => b.id).toSet();
        for (final batch in result.batches) {
          expect(beanIds, contains(batch.beanId));
        }
      });
    });

    group('grinder deduplication', () {
      test('deduplicates grinders by model', () {
        final shots = [
          makeShot(grinderModel: 'Niche Zero'),
          makeShot(grinderModel: 'Niche Zero'),
          makeShot(grinderModel: 'EK43'),
        ];

        final result = extractor.extract(shots);

        expect(result.grinders.length, 2);
        final models = result.grinders.map((g) => g.model).toSet();
        expect(models, containsAll(['Niche Zero', 'EK43']));
      });

      test('deduplication is case-insensitive', () {
        final shots = [
          makeShot(grinderModel: 'niche zero'),
          makeShot(grinderModel: 'NICHE ZERO'),
        ];

        final result = extractor.extract(shots);

        expect(result.grinders.length, 1);
      });
    });

    group('skipping shots with no info', () {
      test('skips shots with null beanBrand', () {
        final shots = [
          makeShot(beanBrand: null, beanType: 'Ethiopia'),
          makeShot(beanBrand: 'Roaster A', beanType: 'Ethiopia'),
        ];

        final result = extractor.extract(shots);

        expect(result.beans.length, 1);
        expect(result.batches.length, 1);
      });

      test('skips shots with null beanType', () {
        final shots = [
          makeShot(beanBrand: 'Roaster A', beanType: null),
          makeShot(beanBrand: 'Roaster A', beanType: 'Colombia'),
        ];

        final result = extractor.extract(shots);

        expect(result.beans.length, 1);
      });

      test('skips shots with empty beanBrand', () {
        final shots = [
          makeShot(beanBrand: '', beanType: 'Ethiopia'),
          makeShot(beanBrand: 'Roaster A', beanType: 'Ethiopia'),
        ];

        final result = extractor.extract(shots);

        expect(result.beans.length, 1);
      });

      test('skips shots with empty beanType', () {
        final shots = [
          makeShot(beanBrand: 'Roaster A', beanType: ''),
          makeShot(beanBrand: 'Roaster A', beanType: 'Ethiopia'),
        ];

        final result = extractor.extract(shots);

        expect(result.beans.length, 1);
      });

      test('skips shots with null grinderModel', () {
        final shots = [
          makeShot(grinderModel: null),
          makeShot(grinderModel: 'Niche Zero'),
        ];

        final result = extractor.extract(shots);

        expect(result.grinders.length, 1);
      });

      test('skips shots with empty grinderModel', () {
        final shots = [
          makeShot(grinderModel: ''),
          makeShot(grinderModel: 'Niche Zero'),
        ];

        final result = extractor.extract(shots);

        expect(result.grinders.length, 1);
      });
    });

    group('shot index mapping', () {
      test('maps shot indices to BeanBatch IDs', () {
        final shots = [
          makeShot(beanBrand: 'Roaster A', beanType: 'Ethiopia'),
          makeShot(beanBrand: 'Roaster B', beanType: 'Colombia'),
          makeShot(beanBrand: 'Roaster A', beanType: 'Ethiopia'),
        ];

        final result = extractor.extract(shots);

        expect(result.shotBeanBatchIds[0], isNotNull);
        expect(result.shotBeanBatchIds[1], isNotNull);
        expect(result.shotBeanBatchIds[2], isNotNull);
        expect(result.shotBeanBatchIds[0], result.shotBeanBatchIds[2]);
        expect(result.shotBeanBatchIds[1], isNot(result.shotBeanBatchIds[0]));
      });

      test('maps shot index to null when shot has no bean info', () {
        final shots = [
          makeShot(beanBrand: null, beanType: null),
          makeShot(beanBrand: 'Roaster A', beanType: 'Ethiopia'),
        ];

        final result = extractor.extract(shots);

        expect(result.shotBeanBatchIds[0], isNull);
        expect(result.shotBeanBatchIds[1], isNotNull);
      });

      test('maps shot indices to Grinder IDs', () {
        final shots = [
          makeShot(grinderModel: 'Niche Zero'),
          makeShot(grinderModel: 'EK43'),
          makeShot(grinderModel: 'Niche Zero'),
        ];

        final result = extractor.extract(shots);

        expect(result.shotGrinderIds[0], isNotNull);
        expect(result.shotGrinderIds[1], isNotNull);
        expect(result.shotGrinderIds[2], isNotNull);
        expect(result.shotGrinderIds[0], result.shotGrinderIds[2]);
        expect(result.shotGrinderIds[1], isNot(result.shotGrinderIds[0]));
      });

      test('maps shot index to null when shot has no grinder info', () {
        final shots = [
          makeShot(grinderModel: null),
          makeShot(grinderModel: 'Niche Zero'),
        ];

        final result = extractor.extract(shots);

        expect(result.shotGrinderIds[0], isNull);
        expect(result.shotGrinderIds[1], isNotNull);
      });

      test('batch IDs reference existing batches', () {
        final shots = [makeShot(beanBrand: 'Roaster A', beanType: 'Ethiopia')];

        final result = extractor.extract(shots);

        final batchId = result.shotBeanBatchIds[0];
        expect(result.batches.map((b) => b.id), contains(batchId));
      });

      test('grinder IDs reference existing grinders', () {
        final shots = [makeShot(grinderModel: 'Niche Zero')];

        final result = extractor.extract(shots);

        final grinderId = result.shotGrinderIds[0];
        expect(result.grinders.map((g) => g.id), contains(grinderId));
      });
    });

    group('empty input', () {
      test('returns empty result for empty shots list', () {
        final result = extractor.extract([]);

        expect(result.beans, isEmpty);
        expect(result.batches, isEmpty);
        expect(result.grinders, isEmpty);
        expect(result.shotBeanBatchIds, isEmpty);
        expect(result.shotGrinderIds, isEmpty);
      });
    });
  });

  group('EntityExtractor.mergeGrinderSpecs', () {
    test('enriches existing grinder with DYE data when model matches', () {
      final fromShots = [Grinder.create(model: 'Niche Zero')];
      final fromDye = [
        Grinder.create(
          model: 'Niche Zero',
          burrs: '63mm conical',
          settingSmallStep: 1.0,
          settingBigStep: 5.0,
        ),
      ];

      final merged = extractor.mergeGrinderSpecs(fromShots, fromDye);

      expect(merged.length, 1);
      final grinder = merged.first;
      expect(grinder.id, fromShots.first.id);
      expect(grinder.model, 'Niche Zero');
      expect(grinder.burrs, '63mm conical');
      expect(grinder.settingSmallStep, 1.0);
      expect(grinder.settingBigStep, 5.0);
    });

    test('matching is case-insensitive', () {
      final fromShots = [Grinder.create(model: 'niche zero')];
      final fromDye = [
        Grinder.create(model: 'NICHE ZERO', burrs: '63mm conical'),
      ];

      final merged = extractor.mergeGrinderSpecs(fromShots, fromDye);

      expect(merged.length, 1);
      expect(merged.first.burrs, '63mm conical');
    });

    test('adds DYE-only grinders not found in shots', () {
      final fromShots = [Grinder.create(model: 'Niche Zero')];
      final fromDye = [
        Grinder.create(
          model: 'EK43',
          burrs: '98mm flat',
          settingSmallStep: 0.5,
          settingBigStep: 3.0,
        ),
      ];

      final merged = extractor.mergeGrinderSpecs(fromShots, fromDye);

      expect(merged.length, 2);
      final models = merged.map((g) => g.model).toSet();
      expect(models, containsAll(['Niche Zero', 'EK43']));
    });

    test('keeps shot grinders that have no DYE match', () {
      final fromShots = [Grinder.create(model: 'Unknown Grinder')];
      final fromDye = <Grinder>[];

      final merged = extractor.mergeGrinderSpecs(fromShots, fromDye);

      expect(merged.length, 1);
      expect(merged.first.model, 'Unknown Grinder');
    });

    test('does not change grinder ID when enriching', () {
      final original = Grinder.create(model: 'Niche Zero');
      final fromDye = [
        Grinder.create(model: 'Niche Zero', burrs: '63mm conical'),
      ];

      final merged = extractor.mergeGrinderSpecs([original], fromDye);

      expect(merged.first.id, original.id);
    });

    test('handles empty fromShots list', () {
      final fromDye = [Grinder.create(model: 'EK43', burrs: '98mm flat')];

      final merged = extractor.mergeGrinderSpecs([], fromDye);

      expect(merged.length, 1);
      expect(merged.first.model, 'EK43');
    });

    test('handles both lists empty', () {
      final merged = extractor.mergeGrinderSpecs([], []);
      expect(merged, isEmpty);
    });
  });
}
