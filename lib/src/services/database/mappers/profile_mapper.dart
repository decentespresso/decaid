import 'package:drift/drift.dart';
import 'package:reaprime/src/models/data/profile.dart';
import 'package:reaprime/src/models/data/profile_record.dart' as domain;
import 'package:reaprime/src/services/database/database.dart' as db;

class ProfileMapper {
  static domain.ProfileRecord fromRow(db.ProfileRecord row) {
    return domain.ProfileRecord(
      id: row.id,
      profile: Profile.fromJson(row.profileJson),
      metadataHash: row.metadataHash,
      compoundHash: row.compoundHash,
      parentId: row.parentId,
      visibility: domain.Visibility.values.firstWhere(
        (v) => v.name == row.visibility,
        orElse: () => domain.Visibility.visible,
      ),
      isDefault: row.isDefault,
      createdAt: row.createdAt,
      updatedAt: row.updatedAt,
      metadata: row.metadata,
    );
  }

  static db.ProfileRecordsCompanion toCompanion(domain.ProfileRecord record) {
    return db.ProfileRecordsCompanion(
      id: Value(record.id),
      metadataHash: Value(record.metadataHash),
      compoundHash: Value(record.compoundHash),
      parentId: Value(record.parentId),
      visibility: Value(record.visibility.name),
      isDefault: Value(record.isDefault),
      createdAt: Value(record.createdAt),
      updatedAt: Value(record.updatedAt),
      profileJson: Value(record.profile.toJson()),
      metadata: Value(record.metadata),
    );
  }
}
