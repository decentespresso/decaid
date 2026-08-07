import 'package:drift/drift.dart';
import 'package:reaprime/src/services/database/database.dart';
import 'package:reaprime/src/services/database/tables/shot_tables.dart';

part 'shot_dao.g.dart';

@DriftAccessor(tables: [ShotRecords])
class ShotDao extends DatabaseAccessor<AppDatabase> with _$ShotDaoMixin {
  ShotDao(super.db);

  Future<List<String>> getAllShotIds() async {
    final query = selectOnly(shotRecords)..addColumns([shotRecords.id]);
    final rows = await query.get();
    return rows.map((row) => row.read(shotRecords.id)!).toList();
  }

  Future<ShotRecord?> getShotById(String id) {
    return (select(
      shotRecords,
    )..where((s) => s.id.equals(id))).getSingleOrNull();
  }

  Future<List<ShotRecord>> getAllShots() {
    return (select(
      shotRecords,
    )..orderBy([(s) => OrderingTerm.desc(s.timestamp)])).get();
  }

  Future<List<ShotRecord>> getShotsForExport({
    int limit = 200,
    DateTime? cursorTimestamp,
    String? cursorId,
  }) {
    final query = select(shotRecords)
      ..orderBy([
        (s) => OrderingTerm.desc(s.timestamp),
        (s) => OrderingTerm.desc(s.id),
      ])
      ..limit(limit);
    if (cursorTimestamp != null) {
      query.where(
        (s) =>
            s.timestamp.isSmallerThanValue(cursorTimestamp) |
            (s.timestamp.equals(cursorTimestamp) &
                s.id.isSmallerThanValue(cursorId!)),
      );
    }
    return query.get();
  }

  Future<List<ShotRecord>> getShotsPaginated({
    int limit = 20,
    int offset = 0,
    String? grinderId,
    String? grinderModel,
    String? beanBatchId,
    List<String>? beanBatchIds,
    String? coffeeName,
    String? coffeeRoaster,
    String? profileTitle,
    String? search,
    bool ascending = false,
  }) {
    final query = select(shotRecords);

    if (grinderId != null) {
      query.where((s) => s.grinderId.equals(grinderId));
    }
    if (grinderModel != null) {
      query.where((s) => s.grinderModel.equals(grinderModel));
    }
    if (beanBatchId != null) {
      query.where((s) => s.beanBatchId.equals(beanBatchId));
    }
    if (beanBatchIds != null) {
      if (beanBatchIds.isEmpty) return Future.value([]);
      query.where((s) => s.beanBatchId.isIn(beanBatchIds));
    }
    if (coffeeName != null) {
      query.where((s) => s.coffeeName.equals(coffeeName));
    }
    if (coffeeRoaster != null) {
      query.where((s) => s.coffeeRoaster.equals(coffeeRoaster));
    }
    if (profileTitle != null) {
      query.where((s) => s.profileTitle.equals(profileTitle));
    }
    if (search != null && search.isNotEmpty) {
      final pattern = '%$search%';
      query.where(
        (s) =>
            s.coffeeName.like(pattern) |
            s.coffeeRoaster.like(pattern) |
            s.profileTitle.like(pattern) |
            s.grinderModel.like(pattern) |
            s.espressoNotes.like(pattern),
      );
    }

    query
      ..orderBy([
        (s) => ascending
            ? OrderingTerm.asc(s.timestamp)
            : OrderingTerm.desc(s.timestamp),
      ])
      ..limit(limit, offset: offset);

    return query.get();
  }

  Future<int> countShots({
    String? grinderId,
    String? grinderModel,
    String? beanBatchId,
    List<String>? beanBatchIds,
    String? coffeeName,
    String? coffeeRoaster,
    String? profileTitle,
    String? search,
  }) async {
    final countExpr = shotRecords.id.count();
    final query = selectOnly(shotRecords)..addColumns([countExpr]);

    if (grinderId != null) {
      query.where(shotRecords.grinderId.equals(grinderId));
    }
    if (grinderModel != null) {
      query.where(shotRecords.grinderModel.equals(grinderModel));
    }
    if (beanBatchId != null) {
      query.where(shotRecords.beanBatchId.equals(beanBatchId));
    }
    if (beanBatchIds != null) {
      if (beanBatchIds.isEmpty) return 0;
      query.where(shotRecords.beanBatchId.isIn(beanBatchIds));
    }
    if (coffeeName != null) {
      query.where(shotRecords.coffeeName.equals(coffeeName));
    }
    if (coffeeRoaster != null) {
      query.where(shotRecords.coffeeRoaster.equals(coffeeRoaster));
    }
    if (profileTitle != null) {
      query.where(shotRecords.profileTitle.equals(profileTitle));
    }
    if (search != null && search.isNotEmpty) {
      final pattern = '%$search%';
      query.where(
        shotRecords.coffeeName.like(pattern) |
            shotRecords.coffeeRoaster.like(pattern) |
            shotRecords.profileTitle.like(pattern) |
            shotRecords.grinderModel.like(pattern) |
            shotRecords.espressoNotes.like(pattern),
      );
    }

    final result = await query.getSingle();
    return result.read(countExpr) ?? 0;
  }

  Stream<List<ShotRecord>> watchAllShots() {
    return (select(
      shotRecords,
    )..orderBy([(s) => OrderingTerm.desc(s.timestamp)])).watch();
  }

  Future<void> insertShot(ShotRecordsCompanion shot) {
    return into(shotRecords).insert(shot);
  }

  Future<void> upsertShot(ShotRecordsCompanion shot) {
    return into(shotRecords).insertOnConflictUpdate(shot);
  }

  Future<void> updateShot(ShotRecordsCompanion shot) {
    return (update(
      shotRecords,
    )..where((s) => s.id.equals(shot.id.value))).write(shot);
  }

  Future<void> deleteShot(String id) {
    return (delete(shotRecords)..where((s) => s.id.equals(id))).go();
  }

  Future<ShotRecord?> getLatestShot() {
    return (select(shotRecords)
          ..orderBy([(s) => OrderingTerm.desc(s.timestamp)])
          ..limit(1))
        .getSingleOrNull();
  }

  Future<ShotRecord?> getLatestShotMeta() async {
    final cols = shotRecords.$columns
        .where((c) => c.$name != 'measurements_json')
        .map((c) => c.$name)
        .join(', ');
    final result = await customSelect(
      "SELECT $cols, '[]' AS measurements_json "
      'FROM shot_records ORDER BY timestamp DESC LIMIT 1',
      readsFrom: {shotRecords},
    ).getSingleOrNull();
    if (result == null) return null;
    return shotRecords.map(result.data);
  }
}
