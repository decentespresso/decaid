import 'package:drift/drift.dart';
import 'package:reaprime/src/services/database/database.dart';
import 'package:reaprime/src/services/database/tables/equipment_tables.dart';

part 'equipment_dao.g.dart';

@DriftAccessor(tables: [EquipmentRecords])
class EquipmentDao extends DatabaseAccessor<AppDatabase>
    with _$EquipmentDaoMixin {
  EquipmentDao(super.db);

  Future<List<EquipmentRecord>> getAllEquipment({
    bool includeArchived = false,
    String? type,
  }) {
    final query = select(equipmentRecords);
    if (!includeArchived) {
      query.where((e) => e.archived.equals(false));
    }
    if (type != null) {
      query.where((e) => e.type.equals(type));
    }
    query.orderBy([(e) => OrderingTerm.desc(e.updatedAt)]);
    return query.get();
  }

  Stream<List<EquipmentRecord>> watchAllEquipment({
    bool includeArchived = false,
  }) {
    final query = select(equipmentRecords);
    if (!includeArchived) {
      query.where((e) => e.archived.equals(false));
    }
    query.orderBy([(e) => OrderingTerm.desc(e.updatedAt)]);
    return query.watch();
  }

  Future<EquipmentRecord?> getEquipmentById(String id) {
    return (select(
      equipmentRecords,
    )..where((e) => e.id.equals(id))).getSingleOrNull();
  }

  Future<void> insertEquipment(EquipmentRecordsCompanion equipment) {
    return into(equipmentRecords).insert(equipment);
  }

  Future<void> updateEquipment(EquipmentRecordsCompanion equipment) {
    return (update(
      equipmentRecords,
    )..where((e) => e.id.equals(equipment.id.value))).write(equipment);
  }

  Future<void> deleteEquipment(String id) {
    return (delete(equipmentRecords)..where((e) => e.id.equals(id))).go();
  }
}
