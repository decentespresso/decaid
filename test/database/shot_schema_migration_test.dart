import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/workflow_controller.dart';
import 'package:reaprime/src/services/database/database.dart';
import 'package:reaprime/src/services/database/mappers/shot_mapper.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite3;

// v4 shot_records DDL: the v5 CREATE TABLE minus the created_at/updated_at
// columns added by the from<5 migration step.
const _v4ShotTableDdl =
    'CREATE TABLE "shot_records" ("id" TEXT NOT NULL, "timestamp" TEXT NOT '
    'NULL, "profile_title" TEXT NULL, "grinder_id" TEXT NULL, '
    '"grinder_model" TEXT NULL, "grinder_setting" TEXT NULL, '
    '"bean_batch_id" TEXT NULL, "coffee_name" TEXT NULL, "coffee_roaster" '
    'TEXT NULL, "target_dose_weight" REAL NULL, "target_yield" REAL NULL, '
    '"enjoyment" REAL NULL, "espresso_notes" TEXT NULL, "stop_reason" TEXT '
    'NULL, "workflow_json" TEXT NOT NULL, "annotations_json" TEXT NULL, '
    '"measurements_json" TEXT NOT NULL, PRIMARY KEY ("id"))';

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('reaprime_v4_migration');
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  test(
    'migration from schema 4 backfills createdAt and updatedAt from timestamp',
    () async {
      final dbFile = File('${tempDir.path}/legacy.db');
      final legacy = sqlite3.sqlite3.open(dbFile.path);
      try {
        legacy.execute(_v4ShotTableDdl);
        legacy.execute('PRAGMA user_version = 4');
        legacy.execute(
          'INSERT INTO shot_records '
          '(id, timestamp, workflow_json, measurements_json) '
          'VALUES (?, ?, ?, ?)',
          [
            'legacy-1',
            '2025-03-01T12:00:00.000Z',
            jsonEncode(WorkflowController().currentWorkflow.toJson()),
            '[]',
          ],
        );
      } finally {
        legacy.close();
      }

      final db = AppDatabase(NativeDatabase(dbFile));
      try {
        final version = (await db.customSelect('PRAGMA user_version').get())
            .single
            .data['user_version'];
        expect(version, 5);

        final raw =
            (await db
                    .customSelect(
                      'SELECT created_at, updated_at FROM shot_records WHERE id = ?',
                      variables: [const Variable('legacy-1')],
                    )
                    .get())
                .single
                .data;
        expect(raw['created_at'], '2025-03-01T12:00:00.000Z');
        expect(raw['updated_at'], '2025-03-01T12:00:00.000Z');

        final shot = ShotMapper.fromRow(
          (await db.shotDao.getShotById('legacy-1'))!,
        );
        expect(shot.createdAt, DateTime.utc(2025, 3, 1, 12));
        expect(shot.updatedAt, DateTime.utc(2025, 3, 1, 12));
      } finally {
        await db.close();
      }
    },
  );
}
