// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'equipment_dao.dart';

// ignore_for_file: type=lint
mixin _$EquipmentDaoMixin on DatabaseAccessor<AppDatabase> {
  $EquipmentRecordsTable get equipmentRecords =>
      attachedDatabase.equipmentRecords;
  EquipmentDaoManager get managers => EquipmentDaoManager(this);
}

class EquipmentDaoManager {
  final _$EquipmentDaoMixin _db;
  EquipmentDaoManager(this._db);
  $$EquipmentRecordsTableTableManager get equipmentRecords =>
      $$EquipmentRecordsTableTableManager(
        _db.attachedDatabase,
        _db.equipmentRecords,
      );
}
