import 'package:reaprime/src/models/data/equipment.dart' as domain;
import 'package:reaprime/src/services/database/database.dart';
import 'package:reaprime/src/services/database/mappers/equipment_mapper.dart';
import 'package:reaprime/src/services/storage/equipment_storage_service.dart';

class DriftEquipmentStorageService implements EquipmentStorageService {
  final AppDatabase _db;

  DriftEquipmentStorageService(this._db);

  @override
  Future<List<domain.Equipment>> getAllEquipment({
    bool includeArchived = false,
    domain.EquipmentType? type,
  }) async {
    final rows = await _db.equipmentDao.getAllEquipment(
      includeArchived: includeArchived,
      type: type?.name,
    );
    return rows.map(EquipmentMapper.fromRow).toList();
  }

  @override
  Stream<List<domain.Equipment>> watchAllEquipment({
    bool includeArchived = false,
  }) {
    return _db.equipmentDao
        .watchAllEquipment(includeArchived: includeArchived)
        .map((rows) => rows.map(EquipmentMapper.fromRow).toList());
  }

  @override
  Future<domain.Equipment?> getEquipmentById(String id) async {
    final row = await _db.equipmentDao.getEquipmentById(id);
    return row == null ? null : EquipmentMapper.fromRow(row);
  }

  @override
  Future<void> insertEquipment(domain.Equipment equipment) {
    return _db.equipmentDao.insertEquipment(
      EquipmentMapper.toCompanion(equipment),
    );
  }

  @override
  Future<void> updateEquipment(domain.Equipment equipment) {
    return _db.equipmentDao.updateEquipment(
      EquipmentMapper.toCompanion(equipment),
    );
  }

  @override
  Future<void> deleteEquipment(String id) {
    return _db.equipmentDao.deleteEquipment(id);
  }
}
