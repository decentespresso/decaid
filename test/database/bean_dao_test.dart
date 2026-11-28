import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/services/database/database.dart';

void main() {
  late AppDatabase db;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
  });

  BeansCompanion makeBean({
    String id = 'bean-1',
    String roaster = 'Test Roaster',
    String name = 'Test Bean',
    bool archived = false,
  }) {
    final now = DateTime.now();
    return BeansCompanion(
      id: Value(id),
      roaster: Value(roaster),
      name: Value(name),
      archived: Value(archived),
      createdAt: Value(now),
      updatedAt: Value(now),
    );
  }

  BeanBatchesCompanion makeBatch({
    String id = 'batch-1',
    String beanId = 'bean-1',
    double? weight,
    double? weightRemaining,
    bool archived = false,
    String? roastLevel,
    String? notes,
    String? currency,
    double? qualityScore,
    bool frozen = false,
    double? price,
    Map<String, dynamic>? extras,
  }) {
    final now = DateTime.now();
    return BeanBatchesCompanion(
      id: Value(id),
      beanId: Value(beanId),
      roastDate: Value(DateTime.utc(2025, 12, 1)),
      roastLevel: Value(roastLevel),
      qualityScore: Value(qualityScore),
      price: Value(price),
      currency: Value(currency),
      weight: Value(weight),
      weightRemaining: Value(weightRemaining),
      buyDate: Value(DateTime.utc(2025, 12, 2)),
      openDate: Value(DateTime.utc(2025, 12, 3)),
      bestBeforeDate: Value(DateTime.utc(2026, 3, 1)),
      frozen: Value(frozen),
      archived: Value(archived),
      notes: Value(notes),
      createdAt: Value(now),
      updatedAt: Value(now),
      extras: Value(extras),
    );
  }

  Future<List<Map<String, Object?>>> rawRows(
    String table,
    String column,
    String value,
  ) async {
    final rows = await db
        .customSelect(
          'SELECT * FROM $table WHERE $column = ? ORDER BY id',
          variables: [Variable<String>(value)],
        )
        .get();
    return rows.map((row) => Map<String, Object?>.from(row.data)).toList();
  }

  Future<List<Map<String, Object?>>> allRawRows(String table) async {
    final rows = await db
        .customSelect('SELECT * FROM $table ORDER BY id')
        .get();
    return rows.map((row) => Map<String, Object?>.from(row.data)).toList();
  }

  Future<int> pragmaForeignKeys() async {
    final row = await db.customSelect('PRAGMA foreign_keys').getSingle();
    return row.data['foreign_keys'] as int;
  }

  ShotRecordsCompanion makeHistoricalShot({
    required String id,
    required String beanBatchId,
    required DateTime timestamp,
  }) {
    return ShotRecordsCompanion.insert(
      id: id,
      timestamp: timestamp,
      createdAt: Value(timestamp),
      updatedAt: Value(timestamp.add(const Duration(seconds: 42))),
      beanBatchId: Value(beanBatchId),
      coffeeName: const Value('issue-911 coffee'),
      coffeeRoaster: const Value('issue-911 roaster'),
      enjoyment: const Value(8.5),
      espressoNotes: const Value('recorded shot notes'),
      workflowJson: {
        'id': 'wf-911',
        'name': 'issue-911 workflow',
        'description': '',
        'context': {
          'beanBatchId': beanBatchId,
          'coffeeName': 'issue-911 coffee',
          'coffeeRoaster': 'issue-911 roaster',
        },
        'profile': {
          'title': 'issue-911 profile',
          'author': 'issue-911',
          'notes': '',
          'beverage_type': 'espresso',
          'steps': <Map<String, dynamic>>[],
          'tank_temperature': 0.0,
          'target_weight': 36.0,
          'target_volume_count_start': 0,
          'version': '2',
        },
        'steamSettings': {
          'targetTemperature': 150,
          'duration': 50,
          'flow': 0.8,
        },
        'hotWaterData': {
          'targetTemperature': 90,
          'duration': 15,
          'volume': 100,
          'flow': 4.0,
        },
        'rinseData': {'targetTemperature': 90, 'duration': 10, 'flow': 6.0},
      },
      annotationsJson: const Value({
        'enjoyment': 8.5,
        'espressoNotes': 'recorded shot notes',
        'extras': {'favorite': true, 'issue': 911},
      }),
      measurementsJson: jsonEncode([
        _measurementAt(timestamp, 18.2),
        _measurementAt(timestamp.add(const Duration(seconds: 1)), 24.6),
      ]),
    );
  }

  group('BeanDao - Beans', () {
    test('inserts and retrieves a bean', () async {
      await db.beanDao.insertBean(makeBean());
      final beans = await db.beanDao.getAllBeans();
      expect(beans, hasLength(1));
      expect(beans.first.roaster, 'Test Roaster');
      expect(beans.first.name, 'Test Bean');
    });

    test('filters archived beans by default', () async {
      await db.beanDao.insertBean(makeBean(id: 'b1'));
      await db.beanDao.insertBean(makeBean(id: 'b2', archived: true));

      final active = await db.beanDao.getAllBeans();
      expect(active, hasLength(1));
      expect(active.first.id, 'b1');

      final all = await db.beanDao.getAllBeans(includeArchived: true);
      expect(all, hasLength(2));
    });

    test('gets bean by ID', () async {
      await db.beanDao.insertBean(makeBean(id: 'b1', name: 'Special'));
      final bean = await db.beanDao.getBeanById('b1');
      expect(bean, isNotNull);
      expect(bean!.name, 'Special');
    });

    test('returns null for missing bean', () async {
      final bean = await db.beanDao.getBeanById('nonexistent');
      expect(bean, isNull);
    });

    test('updates a bean', () async {
      await db.beanDao.insertBean(makeBean(id: 'b1', name: 'Original'));
      await db.beanDao.updateBean(
        BeansCompanion(
          id: const Value('b1'),
          name: const Value('Updated'),
          updatedAt: Value(DateTime.now()),
        ),
      );
      final bean = await db.beanDao.getBeanById('b1');
      expect(bean!.name, 'Updated');
    });

    test('deletes a bean', () async {
      await db.beanDao.insertBean(makeBean(id: 'b1'));
      await db.beanDao.deleteBean('b1');
      final beans = await db.beanDao.getAllBeans(includeArchived: true);
      expect(beans, isEmpty);
    });

    test('watches bean changes', () async {
      final stream = db.beanDao.watchAllBeans();

      await db.beanDao.insertBean(makeBean(id: 'b1'));
      await db.beanDao.insertBean(makeBean(id: 'b2'));

      final beans = await stream.first;
      expect(beans, hasLength(2));
    });
  });

  group('BeanDao - BeanBatches', () {
    test('lists batches across beans and filters archived records', () async {
      await db.beanDao.insertBean(makeBean(id: 'bean-1'));
      await db.beanDao.insertBean(makeBean(id: 'bean-2'));
      await db.beanDao.insertBean(makeBean(id: 'bean-3', archived: true));
      await db.beanDao.insertBatch(makeBatch(id: 'b1'));
      await db.beanDao.insertBatch(makeBatch(id: 'b2', beanId: 'bean-2'));
      await db.beanDao.insertBatch(
        makeBatch(id: 'b3', beanId: 'bean-2', archived: true),
      );
      await db.beanDao.insertBatch(makeBatch(id: 'b4', beanId: 'bean-3'));

      final active = await db.beanDao.getAllBatches();
      expect(active.map((batch) => batch.id).toSet(), {'b1', 'b2'});

      final all = await db.beanDao.getAllBatches(includeArchived: true);
      expect(all.map((batch) => batch.id).toSet(), {'b1', 'b2', 'b3', 'b4'});
    });

    test('inserts and retrieves batches for a bean', () async {
      await db.beanDao.insertBean(makeBean(id: 'bean-1'));
      await db.beanDao.insertBatch(makeBatch(id: 'batch-1'));
      await db.beanDao.insertBatch(makeBatch(id: 'batch-2', beanId: 'bean-1'));

      final batches = await db.beanDao.getBatchesForBean('bean-1');
      expect(batches, hasLength(2));
    });

    test('filters archived batches by default', () async {
      await db.beanDao.insertBean(makeBean(id: 'bean-1'));
      await db.beanDao.insertBatch(makeBatch(id: 'b1'));
      await db.beanDao.insertBatch(makeBatch(id: 'b2', archived: true));

      final active = await db.beanDao.getBatchesForBean('bean-1');
      expect(active, hasLength(1));

      final all = await db.beanDao.getBatchesForBean(
        'bean-1',
        includeArchived: true,
      );
      expect(all, hasLength(2));
    });

    test('decrements batch weight', () async {
      await db.beanDao.insertBean(makeBean(id: 'bean-1'));
      await db.beanDao.insertBatch(
        makeBatch(id: 'batch-1', weight: 250.0, weightRemaining: 250.0),
      );

      await db.beanDao.decrementBatchWeight('batch-1', 18.0);

      final batch = await db.beanDao.getBatchById('batch-1');
      expect(batch!.weightRemaining, closeTo(232.0, 0.01));
    });

    test('weight does not go below zero', () async {
      await db.beanDao.insertBean(makeBean(id: 'bean-1'));
      await db.beanDao.insertBatch(
        makeBatch(id: 'batch-1', weight: 10.0, weightRemaining: 5.0),
      );

      await db.beanDao.decrementBatchWeight('batch-1', 20.0);

      final batch = await db.beanDao.getBatchById('batch-1');
      expect(batch!.weightRemaining, 0.0);
    });

    test(
      'foreign key enforced - cannot insert batch for nonexistent bean',
      () async {
        expect(
          () => db.beanDao.insertBatch(makeBatch(beanId: 'no-such-bean')),
          throwsA(anything),
        );
      },
    );
  });

  test('getBeansForExport pages with a stable keyset cursor', () async {
    final base = DateTime.parse('2024-01-15T10:00:00Z');
    for (var i = 0; i < 12; i++) {
      await db.beanDao.insertBean(
        BeansCompanion(
          id: Value('bean-$i'),
          roaster: Value('R'),
          name: Value('N$i'),
          createdAt: Value(base.add(Duration(minutes: i))),
          updatedAt: Value(base.add(Duration(minutes: i))),
        ),
      );
    }
    final collected = <String>[];
    DateTime? cursorCreatedAt;
    String? cursorId;
    while (true) {
      final page = await db.beanDao.getBeansForExport(
        limit: 5,
        cursorCreatedAt: cursorCreatedAt,
        cursorId: cursorId,
      );
      if (page.isEmpty) break;
      for (final b in page) {
        collected.add(b.id);
        cursorCreatedAt = b.createdAt;
        cursorId = b.id;
      }
    }
    expect(collected, hasLength(12));
    expect(collected.toSet(), hasLength(12));
  });

  group('BeanDao - bean deletion cascade (issue #911)', () {
    test('deletes a bean without batches', () async {
      await db.beanDao.insertBean(
        makeBean(id: 'bean-empty', name: '911 empty'),
      );
      await db.beanDao.insertBean(makeBean(id: 'bean-keep', name: '911 keep'));
      final keepBefore = await rawRows('beans', 'id', 'bean-keep');

      await db.beanDao.deleteBean('bean-empty');

      expect(await db.beanDao.getBeanById('bean-empty'), isNull);
      expect(await rawRows('beans', 'id', 'bean-keep'), equals(keepBefore));
      expect(await pragmaForeignKeys(), 1);
    });

    test('removes every batch, archived batches included, and leaves unrelated '
        'rows untouched', () async {
      await db.beanDao.insertBean(
        makeBean(id: 'bean-target', name: '911 target'),
      );
      await db.beanDao.insertBatch(
        makeBatch(
          id: 'target-batch-1',
          beanId: 'bean-target',
          weight: 250.0,
          weightRemaining: 240.0,
          roastLevel: 'light',
          notes: 'target active one',
          currency: 'EUR',
          qualityScore: 86.5,
          extras: {'issue': 911},
        ),
      );
      await db.beanDao.insertBatch(
        makeBatch(
          id: 'target-batch-2',
          beanId: 'bean-target',
          weight: 500.0,
          weightRemaining: 500.0,
          roastLevel: 'medium',
          frozen: true,
        ),
      );
      await db.beanDao.insertBatch(
        makeBatch(
          id: 'target-batch-archived',
          beanId: 'bean-target',
          roastLevel: 'dark',
          archived: true,
        ),
      );

      await db.beanDao.insertBean(makeBean(id: 'bean-keep', name: '911 keep'));
      await db.beanDao.insertBatch(
        makeBatch(
          id: 'keep-batch-1',
          beanId: 'bean-keep',
          weight: 250.0,
          weightRemaining: 250.0,
          roastLevel: 'light',
        ),
      );
      await db.beanDao.insertBatch(
        makeBatch(
          id: 'keep-batch-archived',
          beanId: 'bean-keep',
          roastLevel: 'medium',
          archived: true,
        ),
      );

      final keepBeanBefore = await rawRows('beans', 'id', 'bean-keep');
      final keepBatchesBefore = await rawRows(
        'bean_batches',
        'bean_id',
        'bean-keep',
      );
      expect(keepBatchesBefore, hasLength(2));

      await db.beanDao.deleteBean('bean-target');

      expect(await db.beanDao.getBeanById('bean-target'), isNull);
      expect(
        await db.beanDao.getBatchesForBean(
          'bean-target',
          includeArchived: true,
        ),
        isEmpty,
      );
      for (final id in const [
        'target-batch-1',
        'target-batch-2',
        'target-batch-archived',
      ]) {
        expect(await db.beanDao.getBatchById(id), isNull, reason: id);
      }
      final allBatches = await db.beanDao.getAllBatches(includeArchived: true);
      expect(allBatches.map((batch) => batch.id).toSet(), {
        'keep-batch-1',
        'keep-batch-archived',
      });
      expect(await rawRows('bean_batches', 'bean_id', 'bean-target'), isEmpty);
      expect(await rawRows('beans', 'id', 'bean-keep'), equals(keepBeanBefore));
      expect(
        await rawRows('bean_batches', 'bean_id', 'bean-keep'),
        equals(keepBatchesBefore),
      );
      expect(await pragmaForeignKeys(), 1);
    });

    test('preserves historical shots that reference deleted batches', () async {
      await db.beanDao.insertBean(makeBean(id: 'bean-shot', name: '911 shot'));
      await db.beanDao.insertBatch(
        makeBatch(id: 'batch-shot-active', beanId: 'bean-shot'),
      );
      await db.beanDao.insertBatch(
        makeBatch(
          id: 'batch-shot-archived',
          beanId: 'bean-shot',
          archived: true,
        ),
      );

      final timestamp = DateTime.utc(2026, 1, 5, 9, 30);
      await db.shotDao.insertShot(
        makeHistoricalShot(
          id: 'shot-active',
          beanBatchId: 'batch-shot-active',
          timestamp: timestamp,
        ),
      );
      await db.shotDao.insertShot(
        makeHistoricalShot(
          id: 'shot-archived',
          beanBatchId: 'batch-shot-archived',
          timestamp: timestamp.add(const Duration(days: 1)),
        ),
      );

      final shotsBefore = await allRawRows('shot_records');
      expect(shotsBefore, hasLength(2));

      await db.beanDao.deleteBean('bean-shot');

      expect(await allRawRows('shot_records'), equals(shotsBefore));

      final shot = await db.shotDao.getShotById('shot-active');
      expect(shot, isNotNull);
      expect(shot!.beanBatchId, 'batch-shot-active');
      expect(shot.coffeeName, 'issue-911 coffee');
      expect(shot.coffeeRoaster, 'issue-911 roaster');
      expect(shot.enjoyment, 8.5);
      expect(shot.espressoNotes, 'recorded shot notes');
      expect(shot.createdAt?.toUtc(), timestamp);
      expect(
        shot.updatedAt?.toUtc(),
        timestamp.add(const Duration(seconds: 42)),
      );
      expect(
        (shot.workflowJson['context'] as Map<String, dynamic>)['beanBatchId'],
        'batch-shot-active',
      );
      expect(shot.annotationsJson?['enjoyment'], 8.5);
      expect(
        (shot.annotationsJson?['extras'] as Map<String, dynamic>)['favorite'],
        isTrue,
      );
      expect(jsonDecode(shot.measurementsJson), hasLength(2));

      expect(await db.beanDao.getBatchById('batch-shot-active'), isNull);
      expect(await db.beanDao.getBatchById('batch-shot-archived'), isNull);
      expect(
        await db.shotDao.getAllShotIds(),
        containsAll(<String>['shot-active', 'shot-archived']),
      );
      final recordedBatchHistory = await db.shotDao.getShotsPaginated(
        beanBatchId: 'batch-shot-active',
      );
      expect(recordedBatchHistory.map((entry) => entry.id), ['shot-active']);
      expect(await pragmaForeignKeys(), 1);
    });

    test('rolls back the batch cascade when the parent delete fails', () async {
      await db.customStatement('''
          CREATE TRIGGER test_injected_bean_delete_failure
          BEFORE DELETE ON beans
          WHEN (SELECT COUNT(*) FROM bean_batches WHERE bean_id = OLD.id) = 0
          BEGIN
            SELECT RAISE(ABORT, 'injected bean delete failure');
          END
        ''');

      final injectedFailure = throwsA(
        predicate<Object>(
          (error) => error.toString().contains('injected bean delete failure'),
          'exception carrying the injected bean delete failure',
        ),
      );

      await db.beanDao.insertBean(
        makeBean(id: 'bean-probe', name: '911 probe'),
      );
      await expectLater(
        db.customStatement('DELETE FROM beans WHERE id = ?', ['bean-probe']),
        injectedFailure,
        reason: 'the injected trigger must fire once no batches remain',
      );
      expect(await db.beanDao.getBeanById('bean-probe'), isNotNull);

      await db.beanDao.insertBean(
        makeBean(id: 'bean-target', name: '911 target'),
      );
      await db.beanDao.insertBatch(
        makeBatch(id: 'target-batch-1', beanId: 'bean-target'),
      );
      await db.beanDao.insertBatch(
        makeBatch(
          id: 'target-batch-2',
          beanId: 'bean-target',
          roastLevel: 'medium',
        ),
      );
      await db.beanDao.insertBatch(
        makeBatch(
          id: 'target-batch-archived',
          beanId: 'bean-target',
          archived: true,
        ),
      );
      await db.shotDao.insertShot(
        makeHistoricalShot(
          id: 'shot-rollback',
          beanBatchId: 'target-batch-1',
          timestamp: DateTime.utc(2026, 1, 6, 8),
        ),
      );

      final beanBefore = await rawRows('beans', 'id', 'bean-target');
      final batchesBefore = await rawRows(
        'bean_batches',
        'bean_id',
        'bean-target',
      );
      final shotsBefore = await allRawRows('shot_records');
      expect(batchesBefore, hasLength(3));

      await expectLater(db.beanDao.deleteBean('bean-target'), injectedFailure);

      expect(await rawRows('beans', 'id', 'bean-target'), equals(beanBefore));
      expect(
        await rawRows('bean_batches', 'bean_id', 'bean-target'),
        equals(batchesBefore),
      );
      expect(await allRawRows('shot_records'), equals(shotsBefore));
      expect(
        await db.beanDao.getBatchesForBean(
          'bean-target',
          includeArchived: true,
        ),
        hasLength(3),
      );
      expect(await pragmaForeignKeys(), 1);

      await db.customStatement(
        'DROP TRIGGER test_injected_bean_delete_failure',
      );
      await db.beanDao.deleteBean('bean-target');
      expect(await db.beanDao.getBeanById('bean-target'), isNull);
      expect(
        await db.beanDao.getBatchesForBean(
          'bean-target',
          includeArchived: true,
        ),
        isEmpty,
      );
    });

    test(
      'keeps foreign-key enforcement enabled without a schema change',
      () async {
        expect(await pragmaForeignKeys(), 1);
        expect(
          db.schemaVersion,
          6,
          reason:
              'issue #911 asks for an explicit transaction, not a schema '
              'migration',
        );

        await db.beanDao.insertBean(makeBean(id: 'bean-fk'));
        await db.beanDao.insertBatch(
          makeBatch(id: 'fk-batch', beanId: 'bean-fk'),
        );

        await db.beanDao.deleteBean('bean-fk');

        expect(await pragmaForeignKeys(), 1);
        await expectLater(
          db.beanDao.insertBatch(makeBatch(id: 'orphan', beanId: 'gone-bean')),
          throwsA(anything),
        );
        expect(await db.beanDao.getBatchById('orphan'), isNull);

        await db.beanDao.insertBean(makeBean(id: 'bean-next'));
        await db.beanDao.insertBatch(
          makeBatch(id: 'next-batch', beanId: 'bean-next'),
        );
        expect(await db.beanDao.getBatchById('next-batch'), isNotNull);
      },
    );
  });
}

Map<String, dynamic> _measurementAt(DateTime timestamp, double weight) {
  return {
    'machine': {
      'timestamp': timestamp.toIso8601String(),
      'state': {'state': 'espresso', 'substate': 'pouring'},
      'flow': 1.4,
      'pressure': 9.1,
      'targetFlow': 1.5,
      'targetPressure': 9.0,
      'mixTemperature': 88.5,
      'groupTemperature': 92.0,
      'targetMixTemperature': 88.0,
      'targetGroupTemperature': 92.0,
      'profileFrame': 3,
      'steamTemperature': 0,
    },
    'scale': {
      'timestamp': timestamp.toIso8601String(),
      'weight': weight,
      'weightFlow': 0.7,
      'battery': 88,
      'timerValue': 1500,
    },
    'volume': 12.5,
  };
}
