import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/profile_controller.dart';
import 'package:reaprime/src/models/data/profile.dart';
import 'package:reaprime/src/models/data/profile_record.dart';
import 'package:reaprime/src/services/storage/profile_storage_service.dart';
import 'package:reaprime/src/services/webserver/data_export/data_export_section.dart';
import 'package:reaprime/src/services/webserver/data_export/profile_export_section.dart';
import 'package:reaprime/src/util/incremental_json_parser.dart';

import 'streaming_test_helpers.dart';

class MockProfileStorage implements ProfileStorageService {
  final Map<String, ProfileRecord> records = {};
  int getAllIdsCalls = 0;

  @override
  Future<void> initialize() async {}

  @override
  Future<List<String>> getAllIds() async {
    getAllIdsCalls++;
    return records.keys.toList();
  }

  @override
  Future<ProfileRecord?> get(String id) async => records[id];

  @override
  Future<void> store(ProfileRecord record) async {
    records[record.id] = record;
  }

  @override
  Future<void> storeAll(List<ProfileRecord> records) async {
    for (final record in records) {
      this.records[record.id] = record;
    }
  }

  @override
  Future<List<ProfileRecord>> getAll({Visibility? visibility}) async =>
      records.values.toList();

  @override
  Future<void> update(ProfileRecord record) async {
    records[record.id] = record;
  }

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
  Future<List<ProfileRecord>> getByParentId(String parentId) async => [];

  @override
  Future<void> clear() async => records.clear();

  @override
  Future<int> count({Visibility? visibility}) async => records.length;
}

ProfileRecord makeProfile(int i) {
  final profile = Profile(
    version: '2',
    title: 'Profile $i',
    notes: '',
    author: 'Test',
    beverageType: BeverageType.espresso,
    steps: [
      ProfileStepPressure(
        name: 'pour',
        transition: TransitionType.fast,
        volume: 100,
        seconds: 30,
        temperature: 93,
        sensor: TemperatureSensor.coffee,
        pressure: 9,
      ),
    ],
    tankTemperature: 90.0 + i,
    targetWeight: 36.0,
    targetVolumeCountStart: 0,
  );
  return ProfileRecord.create(profile: profile, metadata: const {});
}

void main() {
  group('ProfileExportSection', () {
    test('loads the profile ID list once per export', () async {
      final storage = MockProfileStorage();
      for (var i = 0; i < 120; i++) {
        await storage.store(makeProfile(i));
      }
      final section = ProfileExportSection(controller: _controller(storage));

      final sink = CapturingJsonSink();
      await section.exportJson(sink);
      expect(storage.getAllIdsCalls, 1);
      final decoded = jsonDecode(sink.json) as List;
      expect(decoded, hasLength(120));
    });

    test('imports new profiles and skips duplicates', () async {
      final storage = MockProfileStorage();
      await storage.store(makeProfile(0));
      final section = ProfileExportSection(controller: _controller(storage));
      final json = jsonEncode([
        makeProfile(0).toJson(),
        makeProfile(1).toJson(),
      ]);
      final result = await importSectionJson(
        section,
        json,
        ConflictStrategy.skip,
      );
      expect(result.imported, 1);
      expect(result.skipped, 1);
      expect(storage.records, hasLength(2));
    });

    test('rejects malformed and non-array payloads', () async {
      final storage = MockProfileStorage();
      final section = ProfileExportSection(controller: _controller(storage));
      await expectLater(
        importSectionJson(section, '[{"id":', ConflictStrategy.skip),
        throwsA(isA<JsonStreamFormatException>()),
      );
      final nonArray = await importSectionJson(
        section,
        '{"profiles": []}',
        ConflictStrategy.skip,
      );
      expect(nonArray.errors, hasLength(1));
      expect(storage.records, isEmpty);
    });
  });
}

ProfileController _controller(MockProfileStorage storage) {
  return ProfileController(storage: storage);
}
