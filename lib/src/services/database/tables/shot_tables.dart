import 'package:drift/drift.dart';
import 'package:reaprime/src/services/database/converters/json_converters.dart';

class ShotRecords extends Table {
  TextColumn get id => text()();
  DateTimeColumn get timestamp => dateTime()();

  TextColumn get profileTitle => text().nullable()();
  TextColumn get grinderId => text().nullable()();
  TextColumn get grinderModel => text().nullable()();
  TextColumn get grinderSetting => text().nullable()();
  TextColumn get beanBatchId => text().nullable()();
  TextColumn get coffeeName => text().nullable()();
  TextColumn get coffeeRoaster => text().nullable()();
  RealColumn get targetDoseWeight => real().nullable()();
  RealColumn get targetYield => real().nullable()();
  RealColumn get enjoyment => real().nullable()();
  TextColumn get espressoNotes => text().nullable()();

  TextColumn get stopReason => text().nullable()();

  DateTimeColumn get createdAt => dateTime().nullable()();
  DateTimeColumn get updatedAt => dateTime().nullable()();

  TextColumn get workflowJson => text().map(const JsonMapConverter())();
  TextColumn get annotationsJson =>
      text().map(const NullableJsonMapConverter()).nullable()();

  TextColumn get measurementsJson => text()();

  @override
  Set<Column> get primaryKey => {id};
}
