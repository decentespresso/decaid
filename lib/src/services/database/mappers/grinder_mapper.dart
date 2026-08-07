import 'package:drift/drift.dart';
import 'package:reaprime/src/models/data/grinder.dart' as domain;
import 'package:reaprime/src/services/database/database.dart';

class GrinderMapper {
  static domain.Grinder fromRow(Grinder row) {
    return domain.Grinder(
      id: row.id,
      model: row.model,
      burrs: row.burrs,
      burrSize: row.burrSize,
      burrType: row.burrType,
      notes: row.notes,
      archived: row.archived,
      settingType: domain.GrinderSettingType.fromString(row.settingType),
      settingValues: row.settingValues,
      settingSmallStep: row.settingSmallStep,
      settingBigStep: row.settingBigStep,
      rpmSmallStep: row.rpmSmallStep,
      rpmBigStep: row.rpmBigStep,
      createdAt: row.createdAt,
      updatedAt: row.updatedAt,
      extras: row.extras,
    );
  }

  static GrindersCompanion toCompanion(domain.Grinder grinder) {
    return GrindersCompanion(
      id: Value(grinder.id),
      model: Value(grinder.model),
      burrs: Value(grinder.burrs),
      burrSize: Value(grinder.burrSize),
      burrType: Value(grinder.burrType),
      notes: Value(grinder.notes),
      archived: Value(grinder.archived),
      settingType: Value(grinder.settingType.name),
      settingValues: Value(grinder.settingValues),
      settingSmallStep: Value(grinder.settingSmallStep),
      settingBigStep: Value(grinder.settingBigStep),
      rpmSmallStep: Value(grinder.rpmSmallStep),
      rpmBigStep: Value(grinder.rpmBigStep),
      createdAt: Value(grinder.createdAt),
      updatedAt: Value(grinder.updatedAt),
      extras: Value(grinder.extras),
    );
  }
}
