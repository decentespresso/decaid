import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/services/database/database.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite3;

Future<File> _createCurrentDatabase(Directory tempDir, String name) async {
  final file = File('${tempDir.path}/$name.db');
  final db = AppDatabase(NativeDatabase(file));
  try {
    await db.initialize();
  } finally {
    await db.close();
  }
  return file;
}

String _quoteIdentifier(String identifier) =>
    '"${identifier.replaceAll('"', '""')}"';

Map<String, Object?> _schemaSnapshot(File file) {
  final db = sqlite3.sqlite3.open(file.path);
  try {
    final tableNames = db
        .select(
          "SELECT name FROM sqlite_schema "
          "WHERE type = 'table' AND name NOT LIKE 'sqlite_%' "
          'ORDER BY name',
        )
        .map((row) => row['name'] as String)
        .toList();

    final tables = <String, Object?>{};
    for (final table in tableNames) {
      final quoted = _quoteIdentifier(table);
      final columns = db
          .select('PRAGMA table_info($quoted)')
          .map(
            (row) => <String, Object?>{
              'name': row['name'],
              'type': (row['type'] as String).toUpperCase(),
              'notnull': row['notnull'],
              'default': row['dflt_value'],
              'pk': row['pk'],
            },
          )
          .toList()
        ..sort(
          (a, b) => (a['name'] as String).compareTo(b['name'] as String),
        );

      final foreignKeys = db
          .select('PRAGMA foreign_key_list($quoted)')
          .map(
            (row) => <String, Object?>{
              'table': row['table'],
              'from': row['from'],
              'to': row['to'],
              'on_update': row['on_update'],
              'on_delete': row['on_delete'],
              'match': row['match'],
            },
          )
          .toList()
        ..sort((a, b) {
          final byTable = (a['table'] as String).compareTo(b['table'] as String);
          if (byTable != 0) return byTable;
          return (a['from'] as String).compareTo(b['from'] as String);
        });

      tables[table] = {'columns': columns, 'foreignKeys': foreignKeys};
    }

    final schemaObjects = db
        .select(
          "SELECT type, name, tbl_name, sql FROM sqlite_schema "
          "WHERE type IN ('index', 'trigger') AND sql IS NOT NULL "
          'ORDER BY type, name',
        )
        .map(
          (row) => <String, Object?>{
            'type': row['type'],
            'name': row['name'],
            'table': row['tbl_name'],
            'sql': (row['sql'] as String)
                .replaceAll(RegExp(r'\s+'), ' ')
                .trim(),
          },
        )
        .toList();

    return {'tables': tables, 'schemaObjects': schemaObjects};
  } finally {
    db.close();
  }
}

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('reaprime_schema_parity');
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  test('v4 to v5 migration matches a freshly-created current schema', () async {
    final migratedFile = await _createCurrentDatabase(tempDir, 'migrated');
    final legacy = sqlite3.sqlite3.open(migratedFile.path);
    try {
      legacy.execute('ALTER TABLE shot_records DROP COLUMN created_at');
      legacy.execute('ALTER TABLE shot_records DROP COLUMN updated_at');
      legacy.execute('PRAGMA user_version = 4');
    } finally {
      legacy.close();
    }

    final migrated = AppDatabase(NativeDatabase(migratedFile));
    try {
      await migrated.initialize();
    } finally {
      await migrated.close();
    }

    final referenceFile = await _createCurrentDatabase(tempDir, 'reference');

    final migratedRaw = sqlite3.sqlite3.open(migratedFile.path);
    try {
      expect(
        migratedRaw.select('PRAGMA user_version').single.values.single,
        5,
      );
    } finally {
      migratedRaw.close();
    }

    expect(_schemaSnapshot(migratedFile), _schemaSnapshot(referenceFile));
  });
}
