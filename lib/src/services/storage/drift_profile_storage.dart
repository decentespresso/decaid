import 'package:reaprime/src/models/data/profile_record.dart' as domain;
import 'package:reaprime/src/services/database/database.dart';
import 'package:reaprime/src/services/database/mappers/profile_mapper.dart';
import 'package:reaprime/src/services/storage/profile_storage_service.dart';

/// Drift/SQLite implementation of [ProfileStorageService].
class DriftProfileStorageService implements ProfileStorageService {
  final AppDatabase _db;

  DriftProfileStorageService(this._db);

  @override
  Future<void> initialize() async {}

  @override
  Future<void> store(domain.ProfileRecord record) {
    return _db.profileDao.insertProfile(ProfileMapper.toCompanion(record));
  }

  @override
  Future<domain.ProfileRecord?> get(String id) async {
    final row = await _db.profileDao.getProfileById(id);
    return row == null ? null : ProfileMapper.fromRow(row);
  }

  @override
  Future<List<domain.ProfileRecord>> getAll({
    domain.Visibility? visibility,
  }) async {
    final rows = await _db.profileDao.getAllProfiles(
      visibility: visibility?.name,
    );
    return rows.map(ProfileMapper.fromRow).toList();
  }

  @override
  Future<void> update(domain.ProfileRecord record) {
    return _db.profileDao.updateProfile(ProfileMapper.toCompanion(record));
  }

  @override
  Future<void> delete(String id) {
    return _db.profileDao.deleteProfile(id);
  }

  @override
  Future<bool> exists(String id) {
    return _db.profileDao.profileExists(id);
  }

  @override
  Future<List<String>> getAllIds() {
    return _db.profileDao.getAllProfileIds();
  }

  @override
  Future<List<domain.ProfileRecord>> getByParentId(String parentId) async {
    final rows = await _db.profileDao.getByParentId(parentId);
    return rows.map(ProfileMapper.fromRow).toList();
  }

  @override
  Future<void> storeAll(List<domain.ProfileRecord> records) {
    return _db.profileDao.insertAllProfiles(
      records.map(ProfileMapper.toCompanion).toList(),
    );
  }

  @override
  Future<void> clear() {
    return _db.profileDao.clearAll();
  }

  @override
  Future<int> count({domain.Visibility? visibility}) {
    return _db.profileDao.countProfiles(visibility: visibility?.name);
  }
}
