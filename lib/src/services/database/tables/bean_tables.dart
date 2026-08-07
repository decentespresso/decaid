import 'package:drift/drift.dart';
import 'package:reaprime/src/services/database/converters/json_converters.dart';

class Beans extends Table {
  TextColumn get id => text()();
  TextColumn get roaster => text()();
  TextColumn get name => text()();
  TextColumn get species => text().nullable()();
  BoolColumn get decaf => boolean().withDefault(const Constant(false))();
  TextColumn get decafProcess => text().nullable()();
  TextColumn get country => text().nullable()();
  TextColumn get region => text().nullable()();
  TextColumn get producer => text().nullable()();
  TextColumn get variety =>
      text().map(const NullableStringListConverter()).nullable()();
  TextColumn get altitude =>
      text().map(const NullableIntListConverter()).nullable()();
  TextColumn get processing => text().nullable()();
  TextColumn get notes => text().nullable()();
  BoolColumn get archived => boolean().withDefault(const Constant(false))();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
  TextColumn get extras =>
      text().map(const NullableJsonMapConverter()).nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

class BeanBatches extends Table {
  TextColumn get id => text()();
  TextColumn get beanId => text().references(Beans, #id)();
  DateTimeColumn get roastDate => dateTime().nullable()();
  TextColumn get roastLevel => text().nullable()();
  TextColumn get harvestDate => text().nullable()();
  RealColumn get qualityScore => real().nullable()();
  RealColumn get price => real().nullable()();
  TextColumn get currency => text().nullable()();
  RealColumn get weight => real().nullable()();
  RealColumn get weightRemaining => real().nullable()();
  DateTimeColumn get buyDate => dateTime().nullable()();
  DateTimeColumn get openDate => dateTime().nullable()();
  DateTimeColumn get bestBeforeDate => dateTime().nullable()();
  DateTimeColumn get freezeDate => dateTime().nullable()();
  DateTimeColumn get unfreezeDate => dateTime().nullable()();
  BoolColumn get frozen => boolean().withDefault(const Constant(false))();
  BoolColumn get archived => boolean().withDefault(const Constant(false))();
  TextColumn get notes => text().nullable()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
  TextColumn get extras =>
      text().map(const NullableJsonMapConverter()).nullable()();

  @override
  Set<Column> get primaryKey => {id};
}
