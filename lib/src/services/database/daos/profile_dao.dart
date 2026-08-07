import 'package:drift/drift.dart';
import 'package:reaprime/src/services/database/database.dart';
import 'package:reaprime/src/services/database/tables/profile_tables.dart';

part 'profile_dao.g.dart';

@DriftAccessor(tables: [ProfileRecords])
class ProfileDao extends DatabaseAccessor<AppDatabase> with _$ProfileDaoMixin {
  ProfileDao(super.db);

  Future<List<ProfileRecord>> getAllProfiles({String? visibility}) {
    final query = select(profileRecords);
    if (visibility != null) {
      query.where((p) => p.visibility.equals(visibility));
    }
    query.orderBy([(p) => OrderingTerm.desc(p.updatedAt)]);
    return query.get();
  }

  Stream<List<ProfileRecord>> watchAllProfiles({String? visibility}) {
    final query = select(profileRecords);
    if (visibility != null) {
      query.where((p) => p.visibility.equals(visibility));
    }
    query.orderBy([(p) => OrderingTerm.desc(p.updatedAt)]);
    return query.watch();
  }

  Future<ProfileRecord?> getProfileById(String id) {
    return (select(
      profileRecords,
    )..where((p) => p.id.equals(id))).getSingleOrNull();
  }

  Future<bool> profileExists(String id) async {
    final result = await (select(
      profileRecords,
    )..where((p) => p.id.equals(id))).getSingleOrNull();
    return result != null;
  }

  Future<List<String>> getAllProfileIds() async {
    final query = selectOnly(profileRecords)..addColumns([profileRecords.id]);
    final rows = await query.get();
    return rows.map((row) => row.read(profileRecords.id)!).toList();
  }

  Future<List<ProfileRecord>> getByParentId(String parentId) {
    return (select(
      profileRecords,
    )..where((p) => p.parentId.equals(parentId))).get();
  }

  Future<int> countProfiles({String? visibility}) async {
    final countExpr = profileRecords.id.count();
    final query = selectOnly(profileRecords)..addColumns([countExpr]);
    if (visibility != null) {
      query.where(profileRecords.visibility.equals(visibility));
    }
    final result = await query.getSingle();
    return result.read(countExpr) ?? 0;
  }

  Future<void> insertProfile(ProfileRecordsCompanion profile) {
    return into(profileRecords).insert(profile);
  }

  Future<void> insertAllProfiles(List<ProfileRecordsCompanion> profiles) {
    return batch((b) {
      b.insertAll(profileRecords, profiles);
    });
  }

  Future<void> updateProfile(ProfileRecordsCompanion profile) {
    return (update(
      profileRecords,
    )..where((p) => p.id.equals(profile.id.value))).write(profile);
  }

  Future<void> deleteProfile(String id) {
    return (delete(profileRecords)..where((p) => p.id.equals(id))).go();
  }

  Future<void> clearAll() {
    return delete(profileRecords).go();
  }
}
