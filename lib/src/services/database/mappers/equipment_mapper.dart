import 'package:drift/drift.dart';
import 'package:reaprime/src/models/data/equipment.dart' as domain;
import 'package:reaprime/src/services/database/database.dart';

class EquipmentMapper {
  static domain.Equipment fromRow(EquipmentRecord row) {
    return domain.Equipment(
      id: row.id,
      type: domain.EquipmentType.fromString(row.type),
      name: row.name,
      style: row.style,
      diameterMm: row.diameterMm,
      notes: row.notes,
      archived: row.archived,
      tools: row.tools,
      createdAt: row.createdAt,
      updatedAt: row.updatedAt,
      extras: row.extras,
    );
  }

  static EquipmentRecordsCompanion toCompanion(domain.Equipment equipment) {
    return EquipmentRecordsCompanion(
      id: Value(equipment.id),
      type: Value(equipment.type.name),
      name: Value(equipment.name),
      style: Value(equipment.style),
      diameterMm: Value(equipment.diameterMm),
      notes: Value(equipment.notes),
      archived: Value(equipment.archived),
      tools: Value(equipment.tools),
      createdAt: Value(equipment.createdAt),
      updatedAt: Value(equipment.updatedAt),
      extras: Value(equipment.extras),
    );
  }
}
