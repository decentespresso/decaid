import 'package:reaprime/src/models/data/profile_record.dart';

abstract class ProfileStorageService {
  Future<void> initialize();

  Future<void> store(ProfileRecord record);

  Future<ProfileRecord?> get(String id);

  Future<List<ProfileRecord>> getAll({Visibility? visibility});

  Future<void> update(ProfileRecord record);

  Future<void> replace(String oldId, ProfileRecord replacement);

  Future<void> delete(String id);

  Future<bool> exists(String id);

  Future<List<String>> getAllIds();

  Future<List<ProfileRecord>> getByParentId(String parentId);

  Future<void> storeAll(List<ProfileRecord> records);

  Future<void> clear();

  Future<int> count({Visibility? visibility});
}
