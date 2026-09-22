import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/workflow_controller.dart';
import 'package:reaprime/src/services/database/database.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite3;

// v5 shot_records DDL: the schema as it stood before the enjoyment rescale.
// v6 adds no columns, so this is also the current column set.
const _v5Columns = [
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
  '"created_at" TEXT NULL',
  '"updated_at" TEXT NULL',
  '"workflow_json" TEXT NOT NULL',
  '"annotations_json" TEXT NULL',
  '"measurements_json" TEXT NOT NULL',
];

const _importedAt = '2025-03-01T12:00:00.000Z';
const _editedAt = '2025-06-01T09:15:00.000Z';

Map<String, Object?> _row({
  required String id,
  double? enjoyment,
  String createdAt = _importedAt,
  String? updatedAt,
  String? annotationsJson,
}) {
  return {
    'id': id,
    'timestamp': _importedAt,
    'created_at': createdAt,
    'updated_at': updatedAt ?? createdAt,
    'enjoyment': enjoyment,
    'annotations_json':
        annotationsJson ??
        jsonEncode({
          'actualDoseWeight': 18.0,
          'enjoyment': ?enjoyment,
          'espressoNotes': 'unchanged',
        }),
    'workflow_json': jsonEncode(WorkflowController().currentWorkflow.toJson()),
    'measurements_json': '[]',
  };
}

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('reaprime_v6_migration');
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  String createV5Db(List<Map<String, Object?>> rows) {
    final dbFile = File(
      '${tempDir.path}/v5_${DateTime.now().microsecondsSinceEpoch}.db',
    );
    final legacy = sqlite3.sqlite3.open(dbFile.path);
    try {
      legacy.execute(
        'CREATE TABLE "shot_records" (${_v5Columns.join(', ')}, '
        'PRIMARY KEY ("id"))',
      );
      legacy.execute('PRAGMA user_version = 5');
      for (final row in rows) {
        final columns = row.keys.toList();
        legacy.execute(
          'INSERT INTO shot_records (${columns.join(', ')}) '
          'VALUES (${List.filled(columns.length, '?').join(', ')})',
          [for (final c in columns) row[c]],
        );
      }
    } finally {
      legacy.close();
    }
    return dbFile.path;
  }

  Future<Map<String, Map<String, Object?>>> migrateAndRead(
    List<Map<String, Object?>> rows,
  ) async {
    final path = createV5Db(rows);
    final db = AppDatabase(NativeDatabase(File(path)));
    try {
      await db.initialize();
      final version = await db.customSelect('PRAGMA user_version').getSingle();
      expect(version.data['user_version'], 6);
      final result = await db
          .customSelect(
            'SELECT id, enjoyment, annotations_json FROM shot_records '
            'ORDER BY id',
          )
          .get();
      return {
        for (final r in result)
          r.data['id'] as String: {
            'enjoyment': r.data['enjoyment'],
            'annotations': r.data['annotations_json'] == null
                ? null
                : jsonDecode(r.data['annotations_json'] as String),
          },
      };
    } finally {
      await db.close();
    }
  }

  group('v5 -> v6 enjoyment rescale', () {
    test(
      'rescales an untouched de1app import whose rating is inside 0-5',
      () async {
        // de1app's espresso_enjoyment is 0-100 with an increment of 1, so 4 is a
        // valid legacy rating. Provenance, not the value, identifies it.
        final rows = await migrateAndRead([
          _row(id: 'de1app-1234', enjoyment: 4),
        ]);

        expect(rows['de1app-1234']!['enjoyment'], 0.2);
        expect((rows['de1app-1234']!['annotations'] as Map)['enjoyment'], 0.2);
      },
    );

    test(
      'rescales an untouched de1app import whose rating exceeds 5',
      () async {
        final rows = await migrateAndRead([
          _row(id: 'de1app-5678', enjoyment: 87),
        ]);

        expect(rows['de1app-5678']!['enjoyment'], closeTo(4.35, 1e-9));
      },
    );

    test(
      'rescales any shot holding a rating above the canonical maximum',
      () async {
        // A back-synced native shot has no id prefix, but 80 cannot have been
        // written on the 0-5 scale by any writer.
        final rows = await migrateAndRead([
          _row(id: 'native-1', enjoyment: 80),
        ]);

        expect(rows['native-1']!['enjoyment'], 4.0);
      },
    );

    test('leaves a canonical rating on a native shot alone', () async {
      final rows = await migrateAndRead([_row(id: 'native-2', enjoyment: 4)]);

      expect(rows['native-2']!['enjoyment'], 4.0);
      expect((rows['native-2']!['annotations'] as Map)['enjoyment'], 4.0);
    });

    test('leaves an imported shot edited after import alone', () async {
      // Ambiguous at rest: the rating may have been re-rated on the 0-5 scale
      // since import, so it is not rewritten in either direction.
      final rows = await migrateAndRead([
        _row(id: 'de1app-9999', enjoyment: 4, updatedAt: _editedAt),
      ]);

      expect(rows['de1app-9999']!['enjoyment'], 4.0);
    });

    test('preserves the other annotation fields', () async {
      final rows = await migrateAndRead([
        _row(id: 'de1app-1111', enjoyment: 80),
      ]);

      final annotations = rows['de1app-1111']!['annotations'] as Map;
      expect(annotations['enjoyment'], 4.0);
      expect(annotations['actualDoseWeight'], 18.0);
      expect(annotations['espressoNotes'], 'unchanged');
    });

    test('leaves rows without a rating untouched', () async {
      final rows = await migrateAndRead([
        _row(id: 'de1app-2222', annotationsJson: jsonEncode({'drinkTds': 8.5})),
      ]);

      expect(rows['de1app-2222']!['enjoyment'], isNull);
      expect(rows['de1app-2222']!['annotations'], {'drinkTds': 8.5});
    });

    test(
      'keeps an unparseable annotations blob rather than replacing it',
      () async {
        final path = createV5Db([
          _row(id: 'de1app-3333', enjoyment: 80, annotationsJson: 'not json'),
        ]);
        final db = AppDatabase(NativeDatabase(File(path)));
        try {
          await db.initialize();
          final row = await db
              .customSelect(
                "SELECT enjoyment, annotations_json FROM shot_records "
                "WHERE id = 'de1app-3333'",
              )
              .getSingle();
          expect(row.data['enjoyment'], 4.0);
          expect(row.data['annotations_json'], 'not json');
        } finally {
          await db.close();
        }
      },
    );

    test('does not rescale a second time when reopened', () async {
      final path = createV5Db([_row(id: 'de1app-4444', enjoyment: 80)]);
      for (var open = 0; open < 2; open++) {
        final db = AppDatabase(NativeDatabase(File(path)));
        try {
          await db.initialize();
        } finally {
          await db.close();
        }
      }

      final raw = sqlite3.sqlite3.open(path);
      try {
        final value = raw.select(
          "SELECT enjoyment FROM shot_records WHERE id = ?",
          ['de1app-4444'],
        ).first['enjoyment'];
        expect(value, 4.0);
      } finally {
        raw.close();
      }
    });
  });
}
