import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/profile_controller.dart';
import 'package:reaprime/src/models/data/profile.dart';
import 'package:reaprime/src/models/data/profile_record.dart';
import 'package:reaprime/src/services/storage/profile_storage_service.dart';

class InMemoryProfileStorage implements ProfileStorageService {
  final Map<String, ProfileRecord> records = {};
  @override
  Future<void> initialize() async {}
  @override
  Future<void> store(ProfileRecord record) async => records[record.id] = record;
  @override
  Future<ProfileRecord?> get(String id) async => records[id];
  @override
  Future<List<ProfileRecord>> getAll({Visibility? visibility}) async => records
      .values
      .where((r) => visibility == null || r.visibility == visibility)
      .toList();
  @override
  Future<void> update(ProfileRecord record) async =>
      records[record.id] = record;
  @override
  Future<void> replace(String oldId, ProfileRecord replacement) async {
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
      records.values.where((r) => r.parentId == parentId).toList();
  @override
  Future<void> storeAll(List<ProfileRecord> recs) async {
    for (final r in recs) {
      records[r.id] = r;
    }
  }

  @override
  Future<void> clear() async => records.clear();
  @override
  Future<int> count({Visibility? visibility}) async =>
      (await getAll(visibility: visibility)).length;
}

Future<Map<String, dynamic>> _bundledJson(String filename) async =>
    jsonDecode(await rootBundle.loadString('assets/defaultProfiles/$filename'))
        as Map<String, dynamic>;

const _milkyFile = 'Flow_profile_for_milky_drinks.json';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'M2: a default whose file was removed from the manifest is hidden',
    () async {
      final storage = InMemoryProfileStorage();
      final base = Profile.fromJson(await _bundledJson(_milkyFile));
      final removed = ProfileRecord.create(
        profile: base,
        isDefault: true,
        metadata: {'source': 'bundled', 'filename': 'deleted_profile.json'},
      );
      await storage.store(removed);

      await ProfileController(storage: storage).initialize();

      expect(
        storage.records[removed.id]!.visibility,
        Visibility.hidden,
        reason: 'removed-from-manifest default should be hidden',
      );
    },
  );

  test(
    'M2: a stale prior version of a changed default is hidden, current stays visible',
    () async {
      final storage = InMemoryProfileStorage();
      final json = await _bundledJson(_milkyFile);
      (json['steps'] as List).first['seconds'] = '999';
      final stale = ProfileRecord.create(
        profile: Profile.fromJson(json),
        isDefault: true,
        metadata: {'source': 'bundled', 'filename': _milkyFile},
      );
      await storage.store(stale);

      await ProfileController(storage: storage).initialize();

      final current = Profile.fromJson(await _bundledJson(_milkyFile));
      final currentId = ProfileRecord.create(profile: current).id;
      expect(
        stale.id == currentId,
        isFalse,
        reason: 'precondition: ids differ',
      );
      expect(storage.records[currentId]?.visibility, Visibility.visible);
      expect(storage.records[stale.id]!.visibility, Visibility.hidden);
    },
  );

  test(
    'M1: an existing default with stale metadata gets its title refreshed',
    () async {
      final storage = InMemoryProfileStorage();
      final json = await _bundledJson(_milkyFile);
      json['title'] = 'OLD STALE TITLE';
      final staleMeta = ProfileRecord.create(
        profile: Profile.fromJson(json),
        isDefault: true,
        metadata: {'source': 'bundled', 'filename': _milkyFile},
      );
      await storage.store(staleMeta);

      await ProfileController(storage: storage).initialize();

      final refreshed = storage.records[staleMeta.id]!;
      expect(refreshed.profile.title, 'Flow profile for milky drinks');
      expect(refreshed.visibility, Visibility.visible);
    },
  );

  test('user profiles (not default) are never touched by retirement', () async {
    final storage = InMemoryProfileStorage();
    final json = await _bundledJson(_milkyFile);
    (json['steps'] as List).first['seconds'] = '777';
    final userProfile = ProfileRecord.create(
      profile: Profile.fromJson(json),
      isDefault: false,
    );
    await storage.store(userProfile);

    await ProfileController(storage: storage).initialize();

    expect(storage.records[userProfile.id]!.visibility, Visibility.visible);
    expect(storage.records[userProfile.id]!.isDefault, isFalse);
  });

  test('M3: a default the user hid stays hidden across a reseed', () async {
    final storage = InMemoryProfileStorage();
    final current = Profile.fromJson(await _bundledJson(_milkyFile));
    final hidden = ProfileRecord.create(
      profile: current,
      isDefault: true,
      metadata: {'source': 'bundled', 'filename': _milkyFile},
    ).copyWith(visibility: Visibility.hidden);
    await storage.store(hidden);

    await ProfileController(storage: storage).initialize();

    expect(
      storage.records[hidden.id]!.visibility,
      Visibility.hidden,
      reason: 'a user-hidden default must not be un-hidden by the reseed',
    );
    expect(storage.records[hidden.id]!.isDefault, isTrue);
  });

  test(
    'M3: a hidden default still gets curated metadata refreshed but stays hidden',
    () async {
      final storage = InMemoryProfileStorage();
      final json = await _bundledJson(_milkyFile);
      json['title'] = 'OLD STALE TITLE';
      final hiddenStale = ProfileRecord.create(
        profile: Profile.fromJson(json),
        isDefault: true,
        metadata: {'source': 'bundled', 'filename': _milkyFile},
      ).copyWith(visibility: Visibility.hidden);
      await storage.store(hiddenStale);

      await ProfileController(storage: storage).initialize();

      final refreshed = storage.records[hiddenStale.id]!;
      expect(
        refreshed.profile.title,
        'Flow profile for milky drinks',
        reason: 'curation metadata refresh still applies to hidden defaults',
      );
      expect(
        refreshed.visibility,
        Visibility.hidden,
        reason: 'refreshing metadata must not un-hide the profile',
      );
    },
  );

  test(
    'P1: a bundled profile with a parent_id gets its parentId linked',
    () async {
      final storage = InMemoryProfileStorage();
      final controller = ProfileController(storage: storage);
      await controller.initialize();

      final v2 = Profile.fromJson(await _bundledJson('best_practice.json'));
      final v3 = Profile.fromJson(await _bundledJson('best_practice_v3.json'));
      final v2Id = ProfileRecord.create(profile: v2).id;
      final v3Id = ProfileRecord.create(profile: v3).id;
      expect(v2Id == v3Id, isFalse, reason: 'precondition: v3 differs from v2');

      final v3Json = await _bundledJson('best_practice_v3.json');
      expect(
        v3Json['parent_id'],
        v2Id,
        reason: 'bundled parent_id must match v2\'s immutable content hash',
      );

      expect(storage.records[v3Id]!.parentId, v2Id);

      final lineage = await controller.getLineage(v3Id);
      expect(
        lineage.map((r) => r.id).toList(),
        [v2Id, v3Id],
        reason: 'lineage walks from v3 back to its v2 parent',
      );
    },
  );
}
