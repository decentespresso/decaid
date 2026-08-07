import 'package:drift/drift.dart';
import 'package:reaprime/src/services/database/converters/json_converters.dart';

/// Grinder entity with model info and UI config for setting input.
class Grinders extends Table {
  TextColumn get id => text()();
  TextColumn get model => text()();
  TextColumn get burrs => text().nullable()();
  RealColumn get burrSize => real().nullable()();
  TextColumn get burrType => text().nullable()();
  TextColumn get notes => text().nullable()();
  BoolColumn get archived => boolean().withDefault(const Constant(false))();

  TextColumn get settingType => text().withDefault(const Constant('numeric'))();
  TextColumn get settingValues =>
      text().map(const NullableStringListConverter()).nullable()();
  RealColumn get settingSmallStep => real().nullable()();
  RealColumn get settingBigStep => real().nullable()();
  RealColumn get rpmSmallStep => real().nullable()();
  RealColumn get rpmBigStep => real().nullable()();

  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
  TextColumn get extras =>
      text().map(const NullableJsonMapConverter()).nullable()();

  @override
  Set<Column> get primaryKey => {id};
}
