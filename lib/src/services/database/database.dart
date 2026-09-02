import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';
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
          await m.addColumn(shotRecords, shotRecords.createdAt);
          await m.addColumn(shotRecords, shotRecords.updatedAt);
          await customStatement(
            'UPDATE shot_records SET created_at = timestamp, '
            'updated_at = timestamp',
          );
        }
      },
      beforeOpen: (details) async {
        await customStatement('PRAGMA foreign_keys = ON');
      },
    );
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
