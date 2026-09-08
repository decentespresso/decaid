import 'dart:io';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:reaprime/src/services/database/database.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite3;

class _ThrowingCloseInterceptor extends QueryInterceptor {
  int closeCalls = 0;

  @override
  Future<void> close(QueryExecutor inner) async {
    closeCalls++;
    throw StateError('close failed');
  }
}

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('reaprime_db_startup');
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  File incompatibleLegacyFile() {
    final file = File(
      '${tempDir.path}/incompatible_${DateTime.now().microsecondsSinceEpoch}.db',
    );
    final legacy = sqlite3.sqlite3.open(file.path);
    try {
      legacy.execute(
        'CREATE TABLE shot_records (id TEXT NOT NULL PRIMARY KEY, '
        'updated_at TEXT NOT NULL)',
      );
      legacy.execute('PRAGMA user_version = 4');
      legacy.execute(
        'INSERT INTO shot_records (id, updated_at) VALUES (?, ?)',
        ['legacy-1', '2025-02-01T00:00:00.000Z'],
      );
    } finally {
      legacy.close();
    }
    return file;
  }

  group('AppDatabase.openForStartup', () {
    test('returns null on a fresh database and opens at schema 5', () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final startupError = await db.openForStartup(Logger('StartupTest'));
      expect(startupError, isNull);
      final version = await db.customSelect('PRAGMA user_version').getSingle();
      expect(version.data['user_version'], 5);
    });

    test(
      'returns the error, logs once with stack, and closes the executor after '
      'migration failure',
      () async {
        final executor = NativeDatabase(incompatibleLegacyFile());
        addTearDown(executor.close);
        final db = AppDatabase(executor);
        final log = Logger('StartupFailureTest');
        final severe = <LogRecord>[];
        final subscription = log.onRecord.listen((r) {
          if (r.level >= Level.SEVERE) severe.add(r);
        });
        addTearDown(subscription.cancel);

        final startupError = await db.openForStartup(log);
        expect(startupError, isNotNull);
        expect(severe, hasLength(1));
        expect(severe.single.error, same(startupError));
        expect(severe.single.stackTrace, isNotNull);

        await expectLater(
          db.customSelect('SELECT 1').get(),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              contains("Can't re-open a database after closing it"),
            ),
          ),
        );
      },
    );

    test('a failing close does not mask the original startup error', () async {
      final executor = NativeDatabase(incompatibleLegacyFile());
      addTearDown(executor.close);
      final interceptor = _ThrowingCloseInterceptor();
      final db = AppDatabase(executor.interceptWith(interceptor));
      final log = Logger('CloseFailureTest');
      final records = <LogRecord>[];
      final subscription = log.onRecord.listen(records.add);
      addTearDown(subscription.cancel);

      final startupError = await db.openForStartup(log);
      expect(startupError, isNotNull);
      expect(interceptor.closeCalls, 1);
      final severe = records.where((r) => r.level >= Level.SEVERE).toList();
      final warnings = records.where((r) => r.level == Level.WARNING).toList();
      expect(severe, hasLength(1));
      expect(severe.single.error, same(startupError));
      expect(
        warnings.map((r) => r.message).join('\n'),
        contains('Failed to close database after startup failure'),
      );
      expect(warnings.single.error, isA<StateError>());
      expect(warnings.single.stackTrace, isNotNull);
    });
  });
}
