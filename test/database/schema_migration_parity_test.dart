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

List<Map<String, Object?>> _shotSchema(File file) {
  final db = sqlite3.sqlite3.open(file.path);
  try {
    final schema = db
        .select('PRAGMA table_info(shot_records)')
        .map(
          (row) => <String, Object?>{
            'name': row['name'],
            'type': (row['type'] as String).toUpperCase(),
            'notnull': row['notnull'],
            'default': row['dflt_value'],
            'pk': row['pk'],
          },
        )
        .toList();
    schema.sort(
      (a, b) => (a['name'] as String).compareTo(b['name'] as String),
    );
    return schema;
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

  test('v4 to v5 migration matches the current shot schema', () async {
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
    final raw = sqlite3.sqlite3.open(migratedFile.path);
    try {
      final version = raw.select('PRAGMA user_version').first.values.first;
      expect(version, 5);
    } finally {
      raw.close();
    }

    expect(_shotSchema(migratedFile), _shotSchema(referenceFile));
  });
}
