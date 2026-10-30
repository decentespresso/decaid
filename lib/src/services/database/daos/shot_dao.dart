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

  Expression<bool>? _shotFilter({
    String? grinderId,
    String? grinderModel,
    String? beanBatchId,
    List<String>? beanBatchIds,
    String? coffeeName,
    String? coffeeRoaster,
    String? profileTitle,
    String? search,
    double? minEnjoyment,
  }) {
    final pattern = search == null || search.isEmpty ? null : '%$search%';
    final predicates = <Expression<bool>>[
      if (grinderId != null) shotRecords.grinderId.equals(grinderId),
      if (grinderModel != null) shotRecords.grinderModel.equals(grinderModel),
      if (beanBatchId != null) shotRecords.beanBatchId.equals(beanBatchId),
      if (beanBatchIds != null) shotRecords.beanBatchId.isIn(beanBatchIds),
      if (coffeeName != null) shotRecords.coffeeName.equals(coffeeName),
      if (coffeeRoaster != null)
        shotRecords.coffeeRoaster.equals(coffeeRoaster),
      if (profileTitle != null) shotRecords.profileTitle.equals(profileTitle),
      if (pattern != null)
        shotRecords.coffeeName.like(pattern) |
            shotRecords.coffeeRoaster.like(pattern) |
            shotRecords.profileTitle.like(pattern) |
            shotRecords.grinderModel.like(pattern) |
            shotRecords.espressoNotes.like(pattern),
      if (minEnjoyment != null)
        shotRecords.enjoyment.isBiggerOrEqualValue(minEnjoyment),
    ];
    if (predicates.isEmpty) return null;
    return predicates.reduce((a, b) => a & b);
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
    double? minEnjoyment,
    bool ascending = false,
  }) {
    if (beanBatchIds != null && beanBatchIds.isEmpty) return Future.value([]);

    final query = select(shotRecords);
    final filter = _shotFilter(
      grinderId: grinderId,
      grinderModel: grinderModel,
      beanBatchId: beanBatchId,
      beanBatchIds: beanBatchIds,
      coffeeName: coffeeName,
      coffeeRoaster: coffeeRoaster,
      profileTitle: profileTitle,
      search: search,
      minEnjoyment: minEnjoyment,
    );
    if (filter != null) {
      query.where((_) => filter);
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
    double? minEnjoyment,
  }) async {
    if (beanBatchIds != null && beanBatchIds.isEmpty) return 0;

    final countExpr = shotRecords.id.count();
    final query = selectOnly(shotRecords)..addColumns([countExpr]);
    final filter = _shotFilter(
      grinderId: grinderId,
      grinderModel: grinderModel,
      beanBatchId: beanBatchId,
      beanBatchIds: beanBatchIds,
      coffeeName: coffeeName,
      coffeeRoaster: coffeeRoaster,
      profileTitle: profileTitle,
      search: search,
      minEnjoyment: minEnjoyment,
    );
    if (filter != null) {
      query.where(filter);
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
