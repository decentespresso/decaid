import 'package:drift/drift.dart';
import 'package:reaprime/src/services/database/database.dart';
import 'package:reaprime/src/services/database/tables/grinder_tables.dart';

part 'grinder_dao.g.dart';

@DriftAccessor(tables: [Grinders])
class GrinderDao extends DatabaseAccessor<AppDatabase> with _$GrinderDaoMixin {
  GrinderDao(super.db);

  Future<List<Grinder>> getAllGrinders({bool includeArchived = false}) {
    final query = select(grinders);
    if (!includeArchived) {
      query.where((g) => g.archived.equals(false));
    }
    query.orderBy([(g) => OrderingTerm.desc(g.updatedAt)]);
    return query.get();
  }

  Future<List<Grinder>> getGrindersForExport({
    int limit = 200,
    DateTime? cursorCreatedAt,
    String? cursorId,
  }) {
    final query = select(grinders)
      ..orderBy([
        (g) => OrderingTerm.asc(g.createdAt),
        (g) => OrderingTerm.asc(g.id),
      ])
      ..limit(limit);
    if (cursorCreatedAt != null) {
      query.where(
        (g) =>
            g.createdAt.isBiggerThanValue(cursorCreatedAt) |
            (g.createdAt.equals(cursorCreatedAt) &
                g.id.isBiggerThanValue(cursorId!)),
      );
    }
    return query.get();
  }

  Stream<List<Grinder>> watchAllGrinders({bool includeArchived = false}) {
    final query = select(grinders);
    if (!includeArchived) {
      query.where((g) => g.archived.equals(false));
    }
    query.orderBy([(g) => OrderingTerm.desc(g.updatedAt)]);
    return query.watch();
  }

  Future<Grinder?> getGrinderById(String id) {
    return (select(grinders)..where((g) => g.id.equals(id))).getSingleOrNull();
  }

  Future<void> insertGrinder(GrindersCompanion grinder) {
    return into(grinders).insert(grinder);
  }

  Future<void> updateGrinder(GrindersCompanion grinder) {
    return (update(
      grinders,
    )..where((g) => g.id.equals(grinder.id.value))).write(grinder);
  }

  Future<void> deleteGrinder(String id) {
    return (delete(grinders)..where((g) => g.id.equals(id))).go();
  }
}
