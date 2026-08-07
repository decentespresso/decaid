import 'package:drift/drift.dart';
import 'package:reaprime/src/services/database/database.dart';
import 'package:reaprime/src/services/database/tables/steam_tables.dart';

part 'steam_dao.g.dart';

@DriftAccessor(tables: [SteamRecords])
class SteamDao extends DatabaseAccessor<AppDatabase> with _$SteamDaoMixin {
  SteamDao(super.db);

  Future<List<String>> getAllSteamIds() async {
    final query = selectOnly(steamRecords)..addColumns([steamRecords.id]);
    final rows = await query.get();
    return rows.map((row) => row.read(steamRecords.id)!).toList();
  }

  Future<SteamRecord?> getSteamById(String id) {
    return (select(
      steamRecords,
    )..where((s) => s.id.equals(id))).getSingleOrNull();
  }

  Future<List<SteamRecord>> getAllSteams() {
    return (select(
      steamRecords,
    )..orderBy([(s) => OrderingTerm.desc(s.timestamp)])).get();
  }

  Future<List<SteamRecord>> getSteamsForExport({
    int limit = 200,
    DateTime? cursorTimestamp,
    String? cursorId,
  }) {
    final query = select(steamRecords)
      ..orderBy([
        (s) => OrderingTerm.asc(s.timestamp),
        (s) => OrderingTerm.asc(s.id),
      ])
      ..limit(limit);
    if (cursorTimestamp != null) {
      query.where(
        (s) =>
            s.timestamp.isBiggerThanValue(cursorTimestamp) |
            (s.timestamp.equals(cursorTimestamp) &
                s.id.isBiggerThanValue(cursorId!)),
      );
    }
    return query.get();
  }

  Future<SteamRecord?> getLatestSteam() {
    return (select(steamRecords)
          ..orderBy([(s) => OrderingTerm.desc(s.timestamp)])
          ..limit(1))
        .getSingleOrNull();
  }

  Future<SteamRecord?> getLatestSteamMeta() async {
    final cols = steamRecords.$columns
        .where((c) => c.$name != 'measurements_json')
        .map((c) => c.$name)
        .join(', ');
    final result = await customSelect(
      "SELECT $cols, '[]' AS measurements_json "
      'FROM steam_records ORDER BY timestamp DESC LIMIT 1',
      readsFrom: {steamRecords},
    ).getSingleOrNull();
    if (result == null) return null;
    return steamRecords.map(result.data);
  }

  Future<void> insertSteam(SteamRecordsCompanion record) {
    return into(steamRecords).insert(record);
  }

  Future<void> upsertSteam(SteamRecordsCompanion record) {
    return into(steamRecords).insertOnConflictUpdate(record);
  }

  Future<void> updateSteam(SteamRecordsCompanion record) {
    return (update(
      steamRecords,
    )..where((s) => s.id.equals(record.id.value))).write(record);
  }

  Future<void> deleteSteam(String id) {
    return (delete(steamRecords)..where((s) => s.id.equals(id))).go();
  }
}
