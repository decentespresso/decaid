import 'package:drift/drift.dart';
import 'package:reaprime/src/services/database/converters/json_converters.dart';

class Workflows extends Table {
  TextColumn get id => text()();
  TextColumn get workflowJson => text().map(const JsonMapConverter())();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}
