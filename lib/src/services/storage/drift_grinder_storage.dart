import 'package:reaprime/src/models/data/grinder.dart' as domain;
import 'package:reaprime/src/services/database/database.dart';
import 'package:reaprime/src/services/database/mappers/grinder_mapper.dart';
import 'package:reaprime/src/services/storage/grinder_storage_service.dart';

class DriftGrinderStorageService implements GrinderStorageService {
  final AppDatabase _db;

  DriftGrinderStorageService(this._db);

  @override
  Future<List<domain.Grinder>> getAllGrinders({
    bool includeArchived = false,
  }) async {
    final rows = await _db.grinderDao.getAllGrinders(
      includeArchived: includeArchived,
    );
    return rows.map(GrinderMapper.fromRow).toList();
  }

  @override
  Stream<List<domain.Grinder>> watchAllGrinders({
    bool includeArchived = false,
  }) {
    return _db.grinderDao
        .watchAllGrinders(includeArchived: includeArchived)
        .map((rows) => rows.map(GrinderMapper.fromRow).toList());
  }

  @override
  Future<domain.Grinder?> getGrinderById(String id) async {
    final row = await _db.grinderDao.getGrinderById(id);
    return row == null ? null : GrinderMapper.fromRow(row);
  }

  @override
  Future<void> insertGrinder(domain.Grinder grinder) {
    return _db.grinderDao.insertGrinder(GrinderMapper.toCompanion(grinder));
  }

  @override
  Future<void> updateGrinder(domain.Grinder grinder) {
    return _db.grinderDao.updateGrinder(GrinderMapper.toCompanion(grinder));
  }

  @override
  Future<void> deleteGrinder(String id) {
    return _db.grinderDao.deleteGrinder(id);
  }
}
