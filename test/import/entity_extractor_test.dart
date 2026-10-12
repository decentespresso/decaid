import 'package:flutter_test/flutter_test.dart';

import 'de1app_importer_test.dart'
    show
        FakeStorageService,
        FakeBeanStorageService,
        FakeGrinderStorageService,
        importEntityShots,
        expectResolvedReferences;

void main() {
  group('imported entity identity rules', () {
    test('deduplicates brand + type and model', () async {
      final storage = FakeStorageService();
      final beans = FakeBeanStorageService();
      final grinders = FakeGrinderStorageService();
      final result = await importEntityShots(
        storage: storage,
        beans: beans,
        grinders: grinders,
        identities: [
          {'brand': 'Roaster A', 'type': 'Ethiopia', 'model': 'Niche Zero'},
          {
            'brand': ' ROASTER A ',
            'type': ' ETHIOPIA ',
            'model': ' NICHE ZERO ',
          },
          {'brand': 'Roaster A', 'type': 'Colombia', 'model': 'EK43'},
          {'brand': 'Roaster B', 'type': 'Ethiopia', 'model': 'EK43'},
        ],
      );
      expect(result.errors, isEmpty);
      expect(beans.beans, hasLength(3));
      expect(beans.batches, hasLength(3));
      expect(grinders.grinders, hasLength(2));
      expect(storage.shots, hasLength(4));
      for (final shot in storage.shots.values) {
        expect(shot.workflow.context!.beanBatchId, isNotNull);
        expect(shot.workflow.context!.grinderId, isNotNull);
      }
      final first = storage.shots['de1app-1710510622']!.workflow.context!;
      final second = storage.shots['de1app-1710510623']!.workflow.context!;
      expect(first.beanBatchId, second.beanBatchId);
      expect(first.grinderId, second.grinderId);
      await expectResolvedReferences(storage, beans, grinders);
    });

    test(
      'preserves entity display values independently of identity keys',
      () async {
        final storage = FakeStorageService();
        final beans = FakeBeanStorageService();
        final grinders = FakeGrinderStorageService();
        await importEntityShots(
          storage: storage,
          beans: beans,
          grinders: grinders,
          identities: [
            {
              'brand': 'Roaster A',
              'type': 'Ethiopia',
              'model': 'Custom Grinder',
            },
          ],
        );
        final bean = beans.beans.values.single;
        expect(bean.roaster, 'Roaster A');
        expect(bean.name, 'Ethiopia');
        expect(bean.notes, 'Fruity and floral');
        expect(beans.batches.values.single.roastLevel, 'Light');
        expect(grinders.grinders.values.single.model, 'Custom Grinder');
        final context = storage.shots.values.single.workflow.context!;
        expect(context.beanBatchId, beans.batches.values.single.id);
        expect(context.grinderId, grinders.grinders.values.single.id);
        await expectResolvedReferences(storage, beans, grinders);
      },
    );

    test('batch identity uses the same bean and roast date', () async {
      final storage = FakeStorageService();
      final beans = FakeBeanStorageService();
      final grinders = FakeGrinderStorageService();
      await importEntityShots(
        storage: storage,
        beans: beans,
        grinders: grinders,
        identities: [
          {'roast_date': '2024-01-01'},
          {'roast_date': '2024-02-01'},
          {'roast_date': ' 2024-01-01 '},
        ],
      );
      expect(beans.beans, hasLength(1));
      expect(beans.batches, hasLength(2));
      final contexts = [
        for (var i = 0; i < 3; i++)
          storage.shots['de1app-${1710510622 + i}']!.workflow.context!,
      ];
      for (final context in contexts) {
        expect(context.beanBatchId, isNotNull);
      }
      expect(contexts[0].beanBatchId, contexts[2].beanBatchId);
      expect(contexts[0].beanBatchId, isNot(contexts[1].beanBatchId));
      await expectResolvedReferences(storage, beans, grinders);
    });

    for (final field in ['brand', 'type', 'model']) {
      test('empty $field leaves only that reference unset', () async {
        final storage = FakeStorageService();
        final beans = FakeBeanStorageService();
        final grinders = FakeGrinderStorageService();
        final result = await importEntityShots(
          storage: storage,
          beans: beans,
          grinders: grinders,
          identities: [
            {field: '  '},
          ],
        );
        expect(result.errors, isEmpty);
        final context = storage.shots.values.single.workflow.context!;
        if (field == 'model') {
          expect(context.grinderId, isNull);
          expect(context.beanBatchId, isNotNull);
          expect(grinders.grinders, isEmpty);
        } else {
          expect(context.beanBatchId, isNull);
          expect(context.grinderId, isNotNull);
          expect(beans.beans, isEmpty);
          expect(beans.batches, isEmpty);
        }
        await expectResolvedReferences(storage, beans, grinders);
      });
    }

    test('missing roast dates share the unknown-date batch', () async {
      final storage = FakeStorageService();
      final beans = FakeBeanStorageService();
      final grinders = FakeGrinderStorageService();
      await importEntityShots(
        storage: storage,
        beans: beans,
        grinders: grinders,
        identities: [
          {'roast_date': ''},
          {'roast_date': ''},
        ],
      );
      expect(beans.batches, hasLength(1));
      expect(beans.batches.values.single.roastDate, isNull);
      expect(storage.shots, hasLength(2));
      for (final shot in storage.shots.values) {
        expect(
          shot.workflow.context!.beanBatchId,
          beans.batches.values.single.id,
        );
      }
      await expectResolvedReferences(storage, beans, grinders);
    });
  });
}
