import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/profile_controller.dart';
import 'package:reaprime/src/models/data/profile.dart';
import 'package:reaprime/src/models/data/profile_record.dart';
import 'package:reaprime/src/services/storage/profile_storage_service.dart';

class _ProfileStorage implements ProfileStorageService {
  final records = <String, ProfileRecord>{};
  String? failStoreForId;

  @override
  Future<void> initialize() async {}

  @override
  Future<void> store(ProfileRecord record) async {
    if (record.id == failStoreForId) {
      throw StateError('store failed');
    }
    if (records.containsKey(record.id)) {
      throw ArgumentError('Profile already exists: ${record.id}');
    }
    records[record.id] = record;
  }

  @override
  Future<ProfileRecord?> get(String id) async => records[id];

  @override
  Future<List<ProfileRecord>> getAll({Visibility? visibility}) async => records
      .values
      .where((record) => visibility == null || record.visibility == visibility)
      .toList();

  @override
  Future<void> update(ProfileRecord record) async {
    if (!records.containsKey(record.id)) {
      throw ArgumentError('Profile not found: ${record.id}');
    }
    records[record.id] = record;
  }

  @override
  Future<void> replace(String oldId, ProfileRecord replacement) async {
    if (!records.containsKey(oldId)) {
      throw ArgumentError('Profile not found: $oldId');
    }
    if (records.containsKey(replacement.id)) {
      throw ArgumentError('Profile already exists: ${replacement.id}');
    }
    if (replacement.id == failStoreForId) {
      throw StateError('store failed');
    }

    records[replacement.id] = replacement;
    records.remove(oldId);
  }

  @override
  Future<void> delete(String id) async => records.remove(id);

  @override
  Future<bool> exists(String id) async => records.containsKey(id);

  @override
  Future<List<String>> getAllIds() async => records.keys.toList();

  @override
  Future<List<ProfileRecord>> getByParentId(String parentId) async =>
      records.values.where((record) => record.parentId == parentId).toList();

  @override
  Future<void> storeAll(List<ProfileRecord> records) async {
    for (final record in records) {
      await store(record);
    }
  }

  @override
  Future<void> clear() async => records.clear();

  @override
  Future<int> count({Visibility? visibility}) async =>
      (await getAll(visibility: visibility)).length;
}

Profile _profile({required double tankTemperature, String title = 'Profile'}) {
  return Profile(
    version: '2',
    title: title,
    author: 'Test',
    notes: '',
    beverageType: BeverageType.espresso,
    steps: const [],
    tankTemperature: tankTemperature,
    targetVolumeCountStart: 0,
  );
}

void main() {
  group('ProfileController.update', () {
    late _ProfileStorage storage;
    late ProfileController controller;
    late ProfileRecord original;

    setUp(() async {
      storage = _ProfileStorage();
      controller = ProfileController(storage: storage);
      original = ProfileRecord.create(profile: _profile(tankTemperature: 93));
      await storage.store(original);
    });

    tearDown(() => controller.dispose());

    test('replaces a profile when execution changes its ID', () async {
      final replacement = _profile(tankTemperature: 94);

      final updated = await controller.update(
        original.id,
        profile: replacement,
      );

      expect(updated.id, isNot(original.id));
      expect(await storage.get(original.id), isNull);
      expect(await storage.get(updated.id), updated);
    });

    test('keeps the original when storing the replacement fails', () async {
      final replacement = _profile(tankTemperature: 94);
      final replacementId = ProfileRecord.create(profile: replacement).id;
      storage.failStoreForId = replacementId;

      await expectLater(
        controller.update(original.id, profile: replacement),
        throwsStateError,
      );

      expect(await storage.get(original.id), original);
      expect(await storage.get(replacementId), isNull);
    });

    test(
      'rejects a target ID collision without changing either profile',
      () async {
        final target = ProfileRecord.create(
          profile: _profile(tankTemperature: 94, title: 'Target'),
        );
        await storage.store(target);

        await expectLater(
          controller.update(original.id, profile: target.profile),
          throwsArgumentError,
        );

        expect(await storage.get(original.id), original);
        expect(await storage.get(target.id), target);
      },
    );

    test('updates metadata without changing the profile ID', () async {
      final updated = await controller.update(
        original.id,
        profile: original.profile.copyWith(title: 'Renamed'),
      );

      expect(updated.id, original.id);
      expect(updated.profile.title, 'Renamed');
      expect(await storage.get(original.id), updated);
      expect(storage.records, hasLength(1));
    });
  });
}
