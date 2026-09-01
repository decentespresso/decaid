import 'package:reaprime/src/models/data/shot_record.dart' as domain;
import 'package:reaprime/src/models/data/steam_record.dart' as domain_steam;
import 'package:reaprime/src/models/data/workflow.dart' as domain_wf;
import 'package:reaprime/src/services/database/database.dart';
import 'package:reaprime/src/services/database/mappers/shot_mapper.dart';
import 'package:reaprime/src/services/database/mappers/steam_mapper.dart';
import 'package:reaprime/src/services/database/mappers/workflow_mapper.dart';
import 'package:reaprime/src/services/storage/storage_service.dart';

class DriftStorageService implements StorageService {
  final AppDatabase _db;

  DriftStorageService(this._db);

  @override
  Future<void> storeShot(domain.ShotRecord record) {
    final now = DateTime.now().toUtc();
    return _db.shotDao.insertShot(
      ShotMapper.toCompanion(
        record.copyWith(
          createdAt: record.createdAt ?? now,
          updatedAt: record.updatedAt ?? now,
        ),
      ),
    );
  }

  @override
  Future<void> updateShot(domain.ShotRecord record) {
    return _db.shotDao.updateShot(ShotMapper.toCompanion(record));
  }

  @override
  Future<void> deleteShot(String id) {
    return _db.shotDao.deleteShot(id);
  }

  @override
  Future<List<String>> getShotIds() {
    return _db.shotDao.getAllShotIds();
  }

  @override
  Future<List<domain.ShotRecord>> getAllShots() async {
    final rows = await _db.shotDao.getAllShots();
    return rows.map(ShotMapper.fromRow).toList();
  }

  @override
  Future<domain.ShotRecord?> getShot(String id) async {
    final row = await _db.shotDao.getShotById(id);
    return row == null ? null : ShotMapper.fromRow(row);
  }

  @override
  Future<void> storeCurrentWorkflow(domain_wf.Workflow workflow) {
    return _db.workflowDao.saveCurrentWorkflow(
      WorkflowMapper.toCompanion(workflow),
    );
  }

  @override
  Future<domain_wf.Workflow?> loadCurrentWorkflow() async {
    final row = await _db.workflowDao.loadCurrentWorkflow();
    return row == null ? null : WorkflowMapper.fromRow(row);
  }

  @override
  Future<List<domain.ShotRecord>> getShotsPaginated({
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
  }) async {
    final rows = await _db.shotDao.getShotsPaginated(
      limit: limit,
      offset: offset,
      grinderId: grinderId,
      grinderModel: grinderModel,
      beanBatchId: beanBatchId,
      beanBatchIds: beanBatchIds,
      coffeeName: coffeeName,
      coffeeRoaster: coffeeRoaster,
      profileTitle: profileTitle,
      search: search,
      ascending: ascending,
    );
    return rows.map(ShotMapper.fromRow).toList();
  }

  @override
  Future<int> countShots({
    String? grinderId,
    String? grinderModel,
    String? beanBatchId,
    List<String>? beanBatchIds,
    String? coffeeName,
    String? coffeeRoaster,
    String? profileTitle,
    String? search,
  }) {
    return _db.shotDao.countShots(
      grinderId: grinderId,
      grinderModel: grinderModel,
      beanBatchId: beanBatchId,
      beanBatchIds: beanBatchIds,
      coffeeName: coffeeName,
      coffeeRoaster: coffeeRoaster,
      profileTitle: profileTitle,
      search: search,
    );
  }

  @override
  Future<domain.ShotRecord?> getLatestShot() async {
    final row = await _db.shotDao.getLatestShot();
    return row == null ? null : ShotMapper.fromRow(row);
  }

  @override
  Future<domain.ShotRecord?> getLatestShotMeta() async {
    final row = await _db.shotDao.getLatestShotMeta();
    return row == null ? null : ShotMapper.fromRow(row);
  }

  @override
  Future<void> storeSteam(domain_steam.SteamRecord record) {
    return _db.steamDao.insertSteam(SteamMapper.toCompanion(record));
  }

  @override
  Future<void> updateSteam(domain_steam.SteamRecord record) {
    return _db.steamDao.updateSteam(SteamMapper.toCompanion(record));
  }

  @override
  Future<void> deleteSteam(String id) {
    return _db.steamDao.deleteSteam(id);
  }

  @override
  Future<List<String>> getSteamIds() {
    return _db.steamDao.getAllSteamIds();
  }

  @override
  Future<List<domain_steam.SteamRecord>> getAllSteams() async {
    final rows = await _db.steamDao.getAllSteams();
    return rows.map(SteamMapper.fromRow).toList();
  }

  @override
  Future<domain_steam.SteamRecord?> getSteam(String id) async {
    final row = await _db.steamDao.getSteamById(id);
    return row == null ? null : SteamMapper.fromRow(row);
  }

  @override
  Future<domain_steam.SteamRecord?> getLatestSteam() async {
    final row = await _db.steamDao.getLatestSteam();
    return row == null ? null : SteamMapper.fromRow(row);
  }

  @override
  Future<domain_steam.SteamRecord?> getLatestSteamMeta() async {
    final row = await _db.steamDao.getLatestSteamMeta();
    return row == null ? null : SteamMapper.fromRow(row);
  }
}
