import 'package:drift/drift.dart';
import 'package:reaprime/src/services/database/converters/json_converters.dart';

/// Profile records with content-based hash IDs and version tracking.
class ProfileRecords extends Table {
  TextColumn get id => text()();
  TextColumn get metadataHash => text()();
  TextColumn get compoundHash => text()();
  TextColumn get parentId => text().nullable()();
  TextColumn get visibility => text().withDefault(const Constant('visible'))();
  BoolColumn get isDefault => boolean().withDefault(const Constant(false))();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();

  TextColumn get profileJson => text().map(const JsonMapConverter())();
  TextColumn get metadata =>
      text().map(const NullableJsonMapConverter()).nullable()();

  @override
  Set<Column> get primaryKey => {id};
}
