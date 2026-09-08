import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';
import 'package:logging/logging.dart';
import 'package:reaprime/src/services/database/converters/json_converters.dart';
import 'package:reaprime/src/services/database/daos/bean_dao.dart';
import 'package:reaprime/src/services/database/daos/grinder_dao.dart';
import 'package:reaprime/src/services/database/daos/profile_dao.dart';
import 'package:reaprime/src/services/database/daos/shot_dao.dart';
import 'package:reaprime/src/services/database/daos/steam_dao.dart';
import 'package:reaprime/src/services/database/daos/workflow_dao.dart';
import 'package:reaprime/src/services/database/tables/bean_tables.dart';
import 'package:reaprime/src/services/database/tables/grinder_tables.dart';
import 'package:reaprime/src/services/database/tables/profile_tables.dart';
import 'package:reaprime/src/services/database/tables/shot_tables.dart';
import 'package:reaprime/src/services/database/tables/steam_tables.dart';
import 'package:reaprime/src/services/database/tables/workflow_tables.dart';
import 'package:reaprime/src/services/storage/app_directories.dart';

part 'database.g.dart';

@DriftDatabase(
  tables: [
    Beans,
    BeanBatches,
    Grinders,
    ShotRecords,
    SteamRecords,
    Workflows,
    ProfileRecords,
  ],
  daos: [BeanDao, GrinderDao, ShotDao, SteamDao, WorkflowDao, ProfileDao],
)
class AppDatabase extends _$AppDatabase {
  static final Logger _log = Logger('AppDatabase');

  AppDatabase(super.e);

  factory AppDatabase.defaults() {
    return AppDatabase(
      driftDatabase(
        name: 'streamline_bridge',
        native: DriftNativeOptions(
          databasePath: () => AppDirectories.driftFile,
        ),
      ),
    );
  }

  Future<void> initialize() async {
    await customSelect('PRAGMA user_version').get();
  }

  Future<Object?> openForStartup(Logger log) async {
    try {
      await initialize();
      return null;
    } catch (error, stackTrace) {
      log.severe(
        'Local database could not be safely opened or updated',
        error,
        stackTrace,
      );
      try {
        await close();
      } catch (closeError, closeStackTrace) {
        log.warning(
          'Failed to close database after startup failure',
          closeError,
          closeStackTrace,
        );
      }
      return error;
    }
  }

  @override
  int get schemaVersion => 5;

  @override
  MigrationStrategy get migration {
    return MigrationStrategy(
      onCreate: (Migrator m) async {
        await m.createAll();
        await customStatement('PRAGMA foreign_keys = ON');
        await _createIndices();
      },
      onUpgrade: (Migrator m, int from, int to) async {
        _log.info(
          'db migration $from -> $to starting; '
          'user_version=${await _userVersion()}',
        );
        await transaction(() async {
          if (from < 2) {
            await _createIndices();
          }
          if (from < 3) {
            await m.createTable(steamRecords);
            await _createSteamIndices();
          }
          if (from < 4) {
            await m.addColumn(shotRecords, shotRecords.stopReason);
          }
          if (from < 5) {
            await _upgradeToSchema5(m);
          }
        });
        _log.info('db migration $from -> $to completed');
      },
      beforeOpen: (details) async {
        await customStatement('PRAGMA foreign_keys = ON');
      },
    );
  }

  Future<int> _userVersion() async {
    final result = await customSelect('PRAGMA user_version').getSingle();
    return result.data['user_version'] as int;
  }

  Future<void> _upgradeToSchema5(Migrator m) async {
    final columns = await _shotRecordColumnInfo();
    _log.info(
      'db migration to 5; shot_records columns: ${columns.keys.join(', ')}; '
      'created_at=${_columnSummary(columns['created_at'])}, '
      'updated_at=${_columnSummary(columns['updated_at'])}',
    );
    for (final column in <String>['created_at', 'updated_at']) {
      if (columns.containsKey(column)) {
        _validateExistingV5Column(column, columns[column]!);
      }
    }
    if (!columns.containsKey('created_at')) {
      await m.addColumn(shotRecords, shotRecords.createdAt);
    }
    if (!columns.containsKey('updated_at')) {
      await m.addColumn(shotRecords, shotRecords.updatedAt);
    }
    await customStatement(
      'UPDATE shot_records '
      'SET created_at = COALESCE(created_at, timestamp), '
      'updated_at = COALESCE(updated_at, timestamp) '
      'WHERE created_at IS NULL OR updated_at IS NULL',
    );
  }

  static void _validateExistingV5Column(
    String name,
    Map<String, Object?> column,
  ) {
    final type = column['type'] as String?;
    final defaultValue = column['dflt_value'];
    final nullLiteral =
        defaultValue == null ||
        (defaultValue is String && defaultValue.trim().toUpperCase() == 'NULL');
    final reusable =
        type?.toUpperCase() == 'TEXT' &&
        column['notnull'] == 0 &&
        column['pk'] == 0 &&
        nullLiteral;
    if (!reusable) {
      throw StateError(
        'shot_records.$name already exists with an incompatible definition '
        '(${_columnSummary(column)}); refusing to reshape it. '
        'Preserve the database for assisted recovery.',
      );
    }
  }

  static String _columnSummary(Map<String, Object?>? column) {
    if (column == null) return 'absent';
    return 'type=${column['type']}, notNull=${column['notnull']}, '
        'dflt=${column['dflt_value']}, pk=${column['pk']}';
  }

  Future<Map<String, Map<String, Object?>>> _shotRecordColumnInfo() async {
    final rows = await customSelect('PRAGMA table_info(shot_records)').get();
    return {for (final row in rows) row.data['name'] as String: row.data};
  }

  Future<void> _createIndices() async {
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_shot_records_timestamp '
      'ON shot_records (timestamp DESC)',
    );
    await _createSteamIndices();
  }

  Future<void> _createSteamIndices() async {
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_steam_records_timestamp '
      'ON steam_records (timestamp DESC)',
    );
  }
}
