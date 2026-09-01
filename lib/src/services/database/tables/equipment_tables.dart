import 'package:drift/drift.dart';
import 'package:reaprime/src/services/database/converters/json_converters.dart';

class EquipmentRecords extends Table {
  TextColumn get id => text()();
  TextColumn get type => text().withDefault(const Constant('other'))();
  TextColumn get name => text()();
  TextColumn get style => text().nullable()();
  RealColumn get diameterMm => real().nullable()();
  TextColumn get notes => text().nullable()();
  BoolColumn get archived => boolean().withDefault(const Constant(false))();
  TextColumn get tools =>
      text().map(const NullableStringListConverter()).nullable()();

  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
  TextColumn get extras =>
      text().map(const NullableJsonMapConverter()).nullable()();

  @override
  Set<Column> get primaryKey => {id};
}
