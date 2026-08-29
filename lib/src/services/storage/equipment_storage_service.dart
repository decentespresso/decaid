import 'package:reaprime/src/models/data/equipment.dart';

abstract class EquipmentStorageService {
  Future<List<Equipment>> getAllEquipment({
    bool includeArchived = false,
    EquipmentType? type,
  });
  Stream<List<Equipment>> watchAllEquipment({bool includeArchived = false});
  Future<Equipment?> getEquipmentById(String id);
  Future<void> insertEquipment(Equipment equipment);
  Future<void> updateEquipment(Equipment equipment);
  Future<void> deleteEquipment(String id);
}
