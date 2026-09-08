import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/workflow_controller.dart';
import 'package:reaprime/src/services/database/database.dart';
import 'package:reaprime/src/services/database/mappers/shot_mapper.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite3;

// v4 shot_records DDL: the v5 CREATE TABLE minus the created_at/updated_at
// columns added by the from<5 migration step.
const _v4Columns = [
  '"id" TEXT NOT NULL',
  '"timestamp" TEXT NOT NULL',
  '"profile_title" TEXT NULL',
  '"grinder_id" TEXT NULL',
  '"grinder_model" TEXT NULL',
  '"grinder_setting" TEXT NULL',
  '"bean_batch_id" TEXT NULL',
  '"coffee_name" TEXT NULL',
  '"coffee_roaster" TEXT NULL',
  '"target_dose_weight" REAL NULL',
  '"target_yield" REAL NULL',
  '"enjoyment" REAL NULL',
  '"espresso_notes" TEXT NULL',
  '"stop_reason" TEXT NULL',
  '"workflow_json" TEXT NOT NULL',
  '"annotations_json" TEXT NULL',
  '"measurements_json" TEXT NOT NULL',
];

const _createdAtColumn = '"created_at" TEXT NULL';
const _updatedAtColumn = '"updated_at" TEXT NULL';

Map<String, Object?> _row({
  required String id,
  required String timestamp,
  Object? createdAt,
  Object? updatedAt,
}) {
  return {
    'id': id,
    'timestamp': timestamp,
    'created_at': createdAt,
    'updated_at': updatedAt,
    'workflow_json': jsonEncode(WorkflowController().currentWorkflow.toJson()),
    'measurements_json': '[]',
  };
}

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('reaprime_v5_migration');
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  String createLegacyDb({
    int userVersion = 4,
    List<String> baseColumns = _v4Columns,
    List<String> extraColumns = const [],
    List<Map<String, Object?>> rows = const [],
    String? extraDdl,
    String primaryKey = '"id"',
  }) {
    final dbFile = File(
      '${tempDir.path}/legacy_${DateTime.now().microsecondsSinceEpoch}.db',
    );
    final legacy = sqlite3.sqlite3.open(dbFile.path);
    try {
      legacy.execute(
        'CREATE TABLE "shot_records" ('
        '${[...baseColumns, ...extraColumns].join(', ')}, '
        'PRIMARY KEY ($primaryKey))',
      );
      legacy.execute('PRAGMA user_version = $userVersion');
      final columnNames = {'id', 'timestamp'};
      for (final def in baseColumns) {
        columnNames.add(RegExp(r'^"(\w+)"').firstMatch(def)!.group(1)!);
      }
      for (final def in extraColumns) {
        columnNames.add(RegExp(r'^"(\w+)"').firstMatch(def)!.group(1)!);
      }
      for (final row in rows) {
        final columns = row.keys.where(columnNames.contains).toList();
        final placeholders = List.filled(columns.length, '?').join(', ');
        legacy.execute(
          'INSERT INTO shot_records (${columns.join(', ')}) '
          'VALUES ($placeholders)',
          [for (final c in columns) row[c]],
        );
      }
      if (extraDdl != null) {
        legacy.execute(extraDdl);
      }
    } finally {
      legacy.close();
    }
    return dbFile.path;
  }

  Future<void> expectUserVersion(AppDatabase db, int expected) async {
    final result = await db.customSelect('PRAGMA user_version').get();
    expect(result.single.data['user_version'], expected);
  }

  Future<List<Map<String, Object?>>> shotColumnInfo(AppDatabase db) async {
    final rows = await db.customSelect('PRAGMA table_info(shot_records)').get();
    return rows.map((r) => r.data).toList();
  }

  Future<void> expectV5ColumnsExactlyOnce(AppDatabase db) async {
    final info = await shotColumnInfo(db);
    final names = info.map((c) => c['name']).toList();
    expect(names.where((n) => n == 'created_at').length, 1, reason: '$names');
    expect(names.where((n) => n == 'updated_at').length, 1, reason: '$names');
  }

  Future<Map<String, Map<String, Object?>>> readRevisionColumns(
    AppDatabase db,
  ) async {
    final rows = await db
        .customSelect(
          'SELECT id, created_at, updated_at FROM shot_records ORDER BY id',
        )
        .get();
    return {
      for (final r in rows)
        r.data['id'] as String: {
          'created_at': r.data['created_at'],
          'updated_at': r.data['updated_at'],
        },
    };
  }

  Future<void> expectRecoveredV5(
    String dbPath, {
    required Map<String, Map<String, Object?>> expectedRevisions,
    required String mapperId,
    required DateTime mapperCreatedAt,
    required DateTime mapperUpdatedAt,
  }) async {
    final db = AppDatabase(NativeDatabase(File(dbPath)));
    try {
      await db.initialize();
      await expectUserVersion(db, 5);
      await expectV5ColumnsExactlyOnce(db);
      expect(await readRevisionColumns(db), expectedRevisions);
      final shot = ShotMapper.fromRow(
        (await db.shotDao.getShotById(mapperId))!,
      );
      expect(shot.createdAt, mapperCreatedAt);
      expect(shot.updatedAt, mapperUpdatedAt);
    } finally {
      await db.close();
    }
  }

  group('v4 -> v5 migration', () {
    final cases =
        <
          ({
            String name,
            List<String> extraColumns,
            List<Map<String, Object?>> rows,
            Map<String, Map<String, Object?>> expectedRevisions,
            String mapperId,
            DateTime mapperCreatedAt,
            DateTime mapperUpdatedAt,
          })
        >[
          (
            name:
                'clean v4: neither v5 column exists, both added and backfilled',
            extraColumns: const [],
            rows: [
              _row(id: 'legacy-1', timestamp: '2025-03-01T12:00:00.000Z'),
              _row(id: 'legacy-2', timestamp: '2025-03-02T08:30:00.000Z'),
            ],
            expectedRevisions: {
              'legacy-1': {
                'created_at': '2025-03-01T12:00:00.000Z',
                'updated_at': '2025-03-01T12:00:00.000Z',
              },
              'legacy-2': {
                'created_at': '2025-03-02T08:30:00.000Z',
                'updated_at': '2025-03-02T08:30:00.000Z',
              },
            },
            mapperId: 'legacy-1',
            mapperCreatedAt: DateTime.utc(2025, 3, 1, 12),
            mapperUpdatedAt: DateTime.utc(2025, 3, 1, 12),
          ),
          (
            name:
                'partial v5 (created only): existing created_at kept, updated_at added',
            extraColumns: const [_createdAtColumn],
            rows: [
              _row(
                id: 'legacy-1',
                timestamp: '2025-03-01T12:00:00.000Z',
                createdAt: '2025-02-01T00:00:00.000Z',
              ),
              _row(
                id: 'legacy-2',
                timestamp: '2025-03-02T08:30:00.000Z',
                createdAt: '2025-02-02T00:00:00.000Z',
              ),
            ],
            expectedRevisions: {
              'legacy-1': {
                'created_at': '2025-02-01T00:00:00.000Z',
                'updated_at': '2025-03-01T12:00:00.000Z',
              },
              'legacy-2': {
                'created_at': '2025-02-02T00:00:00.000Z',
                'updated_at': '2025-03-02T08:30:00.000Z',
              },
            },
            mapperId: 'legacy-1',
            mapperCreatedAt: DateTime.utc(2025, 2, 1),
            mapperUpdatedAt: DateTime.utc(2025, 3, 1, 12),
          ),
          (
            name:
                'partial v5 (updated only): existing updated_at kept, created_at added',
            extraColumns: const [_updatedAtColumn],
            rows: [
              _row(
                id: 'legacy-1',
                timestamp: '2025-03-01T12:00:00.000Z',
                updatedAt: '2025-02-10T00:00:00.000Z',
              ),
            ],
            expectedRevisions: {
              'legacy-1': {
                'created_at': '2025-03-01T12:00:00.000Z',
                'updated_at': '2025-02-10T00:00:00.000Z',
              },
            },
            mapperId: 'legacy-1',
            mapperCreatedAt: DateTime.utc(2025, 3, 1, 12),
            mapperUpdatedAt: DateTime.utc(2025, 2, 10),
          ),
          (
            name:
                'partial v5 (both columns present at user_version 4) completes',
            extraColumns: const [_createdAtColumn, _updatedAtColumn],
            rows: [
              _row(
                id: 'legacy-1',
                timestamp: '2025-03-01T12:00:00.000Z',
                createdAt: '2025-01-01T00:00:00.000Z',
                updatedAt: '2025-01-02T00:00:00.000Z',
              ),
            ],
            expectedRevisions: {
              'legacy-1': {
                'created_at': '2025-01-01T00:00:00.000Z',
                'updated_at': '2025-01-02T00:00:00.000Z',
              },
            },
            mapperId: 'legacy-1',
            mapperCreatedAt: DateTime.utc(2025, 1, 1),
            mapperUpdatedAt: DateTime.utc(2025, 1, 2),
          ),
          (
            name:
                'partial backfill: NULL revision values filled from timestamp',
            extraColumns: const [_createdAtColumn, _updatedAtColumn],
            rows: [
              _row(id: 'legacy-1', timestamp: '2025-03-01T12:00:00.000Z'),
              _row(
                id: 'legacy-2',
                timestamp: '2025-03-02T08:30:00.000Z',
                createdAt: null,
                updatedAt: '2025-02-02T00:00:00.000Z',
              ),
              _row(
                id: 'legacy-3',
                timestamp: '2025-03-03T10:00:00.000Z',
                createdAt: '2025-01-03T00:00:00.000Z',
              ),
            ],
            expectedRevisions: {
              'legacy-1': {
                'created_at': '2025-03-01T12:00:00.000Z',
                'updated_at': '2025-03-01T12:00:00.000Z',
              },
              'legacy-2': {
                'created_at': '2025-03-02T08:30:00.000Z',
                'updated_at': '2025-02-02T00:00:00.000Z',
              },
              'legacy-3': {
                'created_at': '2025-01-03T00:00:00.000Z',
                'updated_at': '2025-03-03T10:00:00.000Z',
              },
            },
            mapperId: 'legacy-1',
            mapperCreatedAt: DateTime.utc(2025, 3, 1, 12),
            mapperUpdatedAt: DateTime.utc(2025, 3, 1, 12),
          ),
          (
            name:
                'preserve completed work: non-NULL revisions survive, NULLs filled',
            extraColumns: const [_createdAtColumn, _updatedAtColumn],
            rows: [
              _row(
                id: 'legacy-1',
                timestamp: '2025-03-01T12:00:00.000Z',
                createdAt: '2025-01-01T00:00:00.000Z',
                updatedAt: '2025-01-02T00:00:00.000Z',
              ),
              _row(
                id: 'legacy-2',
                timestamp: '2025-03-02T08:30:00.000Z',
                createdAt: '2025-02-01T00:00:00.000Z',
              ),
              _row(id: 'legacy-3', timestamp: '2025-03-03T10:00:00.000Z'),
            ],
            expectedRevisions: {
              'legacy-1': {
                'created_at': '2025-01-01T00:00:00.000Z',
                'updated_at': '2025-01-02T00:00:00.000Z',
              },
              'legacy-2': {
                'created_at': '2025-02-01T00:00:00.000Z',
                'updated_at': '2025-03-02T08:30:00.000Z',
              },
              'legacy-3': {
                'created_at': '2025-03-03T10:00:00.000Z',
                'updated_at': '2025-03-03T10:00:00.000Z',
              },
            },
            mapperId: 'legacy-1',
            mapperCreatedAt: DateTime.utc(2025, 1, 1),
            mapperUpdatedAt: DateTime.utc(2025, 1, 2),
          ),
          (
            name: 'compatible existing nullable TEXT DEFAULT NULL is reused',
            extraColumns: const ['"created_at" TEXT DEFAULT NULL'],
            rows: [
              _row(id: 'legacy-1', timestamp: '2025-03-01T12:00:00.000Z'),
              _row(
                id: 'legacy-2',
                timestamp: '2025-03-02T08:30:00.000Z',
                createdAt: '2025-02-02T00:00:00.000Z',
              ),
            ],
            expectedRevisions: {
              'legacy-1': {
                'created_at': '2025-03-01T12:00:00.000Z',
                'updated_at': '2025-03-01T12:00:00.000Z',
              },
              'legacy-2': {
                'created_at': '2025-02-02T00:00:00.000Z',
                'updated_at': '2025-03-02T08:30:00.000Z',
              },
            },
            mapperId: 'legacy-1',
            mapperCreatedAt: DateTime.utc(2025, 3, 1, 12),
            mapperUpdatedAt: DateTime.utc(2025, 3, 1, 12),
          ),
        ];

    for (final testCase in cases) {
      test(testCase.name, () async {
        await expectRecoveredV5(
          createLegacyDb(
            extraColumns: testCase.extraColumns,
            rows: testCase.rows,
          ),
          expectedRevisions: testCase.expectedRevisions,
          mapperId: testCase.mapperId,
          mapperCreatedAt: testCase.mapperCreatedAt,
          mapperUpdatedAt: testCase.mapperUpdatedAt,
        );
      });
    }
  });

  group('legacy schema upgrades through v5', () {
    test(
      'v3 shot_records (no stop_reason) upgrades through v4 to v5',
      () async {
        final v3Columns = _v4Columns
            .where((c) => !c.contains('"stop_reason"'))
            .toList();
        final dbPath = createLegacyDb(
          userVersion: 3,
          baseColumns: v3Columns,
          rows: [_row(id: 'legacy-1', timestamp: '2025-03-01T12:00:00.000Z')],
        );

        final db = AppDatabase(NativeDatabase(File(dbPath)));
        try {
          await db.initialize();
          await expectUserVersion(db, 5);
          await expectV5ColumnsExactlyOnce(db);

          final info = await shotColumnInfo(db);
          expect(info.map((c) => c['name']), contains('stop_reason'));

          final shot = ShotMapper.fromRow(
            (await db.shotDao.getShotById('legacy-1'))!,
          );
          expect(shot.createdAt, DateTime.utc(2025, 3, 1, 12));
          expect(shot.stopReason, isNull);
        } finally {
          await db.close();
        }
      },
    );
  });

  group('v5 migration failure modes', () {
    (List<Map<String, Object?>>, List<Map<String, Object?>>) snapshotDb(
      String dbPath,
    ) {
      final raw = sqlite3.sqlite3.open(dbPath);
      try {
        final schema = raw
            .select('PRAGMA table_info(shot_records)')
            .map((r) => Map<String, Object?>.from(r))
            .toList();
        final data = raw
            .select('SELECT * FROM shot_records ORDER BY id')
            .map((r) => Map<String, Object?>.from(r))
            .toList();
        return (schema, data);
      } finally {
        raw.close();
      }
    }

    final incompatibleCases =
        <
          ({
            String name,
            List<String> extraColumns,
            String? primaryKey,
            List<Map<String, Object?>> rows,
            String incompatibleColumn,
          })
        >[
          (
            name: 'NOT NULL column',
            extraColumns: const ['"updated_at" TEXT NOT NULL'],
            primaryKey: null,
            rows: [
              _row(
                id: 'legacy-1',
                timestamp: '2025-03-01T12:00:00.000Z',
                updatedAt: '2025-02-01T00:00:00.000Z',
              ),
            ],
            incompatibleColumn: 'updated_at',
          ),
          (
            name: 'wrong column type',
            extraColumns: const ['"created_at" INTEGER'],
            primaryKey: null,
            rows: [_row(id: 'legacy-1', timestamp: '2025-03-01T12:00:00.000Z')],
            incompatibleColumn: 'created_at',
          ),
          (
            name: 'non-null default',
            extraColumns: const ['"created_at" TEXT DEFAULT CURRENT_TIMESTAMP'],
            primaryKey: null,
            rows: [_row(id: 'legacy-1', timestamp: '2025-03-01T12:00:00.000Z')],
            incompatibleColumn: 'created_at',
          ),
          (
            name: 'column in the primary key',
            extraColumns: const ['"created_at" TEXT'],
            primaryKey: '"id", "created_at"',
            rows: [
              _row(
                id: 'legacy-1',
                timestamp: '2025-03-01T12:00:00.000Z',
                createdAt: '2025-02-01T00:00:00.000Z',
              ),
            ],
            incompatibleColumn: 'created_at',
          ),
        ];

    for (final testCase in incompatibleCases) {
      test(
        'rejects incompatible ${testCase.name} and leaves the DB untouched',
        () async {
          final dbPath = createLegacyDb(
            extraColumns: testCase.extraColumns,
            primaryKey: testCase.primaryKey ?? '"id"',
            rows: testCase.rows,
          );
          final before = snapshotDb(dbPath);

          final db = AppDatabase(NativeDatabase(File(dbPath)));
          try {
            await expectLater(
              db.initialize(),
              throwsA(
                isA<StateError>().having(
                  (e) => e.message,
                  'message',
                  contains('incompatible definition'),
                ),
              ),
            );
          } finally {
            await db.close();
          }

          final raw = sqlite3.sqlite3.open(dbPath);
          try {
            final version =
                raw.select('PRAGMA user_version').first.values.first as int;
            expect(version, 4);

            final after = snapshotDb(dbPath);
            expect(after.$1, before.$1);
            expect(after.$2, before.$2);
            final names = after.$1.map((c) => c['name']).toList();
            expect(names, contains(testCase.incompatibleColumn));
          } finally {
            raw.close();
          }
        },
      );
    }

    test('failed migration rolls back partial ALTER work', () async {
      final dbPath = createLegacyDb(
        rows: [_row(id: 'legacy-1', timestamp: '2025-03-01T12:00:00.000Z')],
        extraDdl:
            'CREATE TRIGGER abort_backfill BEFORE UPDATE ON shot_records '
            'BEGIN SELECT RAISE(ABORT, "intentional"); END',
      );
      final before = snapshotDb(dbPath);

      final db = AppDatabase(NativeDatabase(File(dbPath)));
      try {
        await expectLater(
          db.initialize(),
          throwsA(
            isA<sqlite3.SqliteException>().having(
              (e) => e.message,
              'message',
              contains('intentional'),
            ),
          ),
        );
      } finally {
        await db.close();
      }

      final raw = sqlite3.sqlite3.open(dbPath);
      try {
        final version =
            raw.select('PRAGMA user_version').first.values.first as int;
        expect(version, 4);

        final columns = raw
            .select('PRAGMA table_info(shot_records)')
            .map((r) => r['name'] as String);
        expect(columns, isNot(contains('created_at')));
        expect(columns, isNot(contains('updated_at')));

        final after = snapshotDb(dbPath);
        expect(after.$1, before.$1);
        expect(after.$2, before.$2);
      } finally {
        raw.close();
      }
    });
  });
}
