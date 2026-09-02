import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/persistence_controller.dart';
import 'package:reaprime/src/models/data/shot_annotations.dart';
import 'package:reaprime/src/models/data/shot_record.dart';
import 'package:reaprime/src/models/data/shot_snapshot.dart';
import 'package:reaprime/src/models/data/steam_record.dart';
import 'package:reaprime/src/models/data/workflow.dart';
import 'package:reaprime/src/models/data/profile.dart';
import 'package:reaprime/src/models/device/machine.dart';
import 'package:reaprime/src/services/storage/storage_service.dart';
import 'package:reaprime/src/services/webserver/data_export/data_export_section.dart';
import 'package:reaprime/src/services/webserver/data_export/shot_export_section.dart';
import 'package:reaprime/src/util/incremental_json_parser.dart';

import 'streaming_test_helpers.dart';

class _TestShotStorage {
  final Map<String, Map<String, dynamic>> shots = {};
  int stored = 0;
  int updated = 0;
  int shotsChangedNotifications = 0;

  final List<int> pageSizes = [];

  StorageService get service => _service;
  late final StorageService _service = _FakeStorage(this);
}

class _FakeStorage implements StorageService {
  final _TestShotStorage owner;

  _FakeStorage(this.owner);

  @override
  Future<List<ShotRecord>> getAllShots() async {
    throw StateError('getAllShots must not be called during streaming export');
  }

  @override
  Future<List<ShotRecord>> getShotsPaginated({
    int limit = 20,
    int offset = 0,
    String? grinderId,
    String? grinderModel,
    String? beanBatchId,
    List<String>? beanBatchIds,
    String? coffeeName,
    String? coffeeRoaster,
    String? profileTitle,
    String? search,
    bool ascending = false,
  }) async {
    throw StateError('offset paging must not be used for export');
  }

  @override
  Future<void> storeShot(ShotRecord record) async {
    owner.shots[record.id] = record.toJson();
    owner.stored++;
  }

  @override
  Future<void> updateShot(ShotRecord record) async {
    owner.shots[record.id] = record.toJson();
    owner.updated++;
  }

  @override
  Future<ShotRecord?> getShot(String id) async {
    final json = owner.shots[id];
    return json == null ? null : ShotRecord.fromJson(json);
  }

  @override
  Future<void> deleteShot(String id) async {
    owner.shots.remove(id);
  }

  @override
  Future<List<String>> getShotIds() async => owner.shots.keys.toList();

  @override
  Future<void> storeCurrentWorkflow(Workflow workflow) async {}

  @override
  Future<Workflow?> loadCurrentWorkflow() async => null;

  @override
  Future<int> countShots({
    String? grinderId,
    String? grinderModel,
    String? beanBatchId,
    List<String>? beanBatchIds,
    String? coffeeName,
    String? coffeeRoaster,
    String? profileTitle,
    String? search,
  }) async => owner.shots.length;

  @override
  Future<ShotRecord?> getLatestShot() async => null;

  @override
  Future<ShotRecord?> getLatestShotMeta() async => null;

  @override
  Future<void> storeSteam(SteamRecord record) async {}
  @override
  Future<void> updateSteam(SteamRecord record) async {}
  @override
  Future<void> deleteSteam(String id) async {}
  @override
  Future<List<String>> getSteamIds() async => [];
  @override
  Future<List<SteamRecord>> getAllSteams() async => [];
  @override
  Future<SteamRecord?> getSteam(String id) async => null;
  @override
  Future<SteamRecord?> getLatestSteam() async => null;
  @override
  Future<SteamRecord?> getLatestSteamMeta() async => null;
}

Map<String, dynamic> makeWorkflowJson() => Workflow(
  id: 'workflow-1',
  name: 'Test Workflow',
  description: '',
  profile: Profile(
    version: '2',
    title: 'Test Profile',
    author: 'Test Author',
    notes: '',
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
    tankTemperature: 0.0,
    targetWeight: 36.0,
    targetVolumeCountStart: 0,
  ),
  steamSettings: SteamSettings.defaults(),
  hotWaterData: HotWaterData.defaults(),
  rinseData: RinseData.defaults(),
).toJson();

ShotRecord makeShot(int i) => ShotRecord.fromJson({
  'id': 'shot-$i',
  'timestamp': DateTime(2024, 1, 1).add(Duration(minutes: i)).toIso8601String(),
  'measurements': <Object?>[],
  'workflow': makeWorkflowJson(),
});

ShotSnapshot _snapshot() => ShotSnapshot(
  machine: MachineSnapshot(
    timestamp: DateTime.utc(2026, 5, 18, 12),
    state: const MachineStateSnapshot(
      state: MachineState.steam,
      substate: MachineSubstate.pouring,
    ),
    flow: 0,
    pressure: 0,
    targetFlow: 0,
    targetPressure: 0,
    mixTemperature: 90,
    groupTemperature: 90,
    targetMixTemperature: 93,
    targetGroupTemperature: 93,
    profileFrame: 0,
    steamTemperature: 140,
  ),
  volume: 0,
);

void main() {
  group('ShotExportSection', () {
    test('streams records in bounded pages and encodes a JSON array', () async {
      final storage = _TestShotStorage();
      for (var i = 0; i < 250; i++) {
        storage.shots['shot-$i'] = makeShot(i).toJson();
      }
      final section = ShotExportSection(
        controller: PersistenceController(storageService: storage.service),
        pageShots: (limit, {afterTimestamp, afterCreatedAt, afterId}) async {
          storage.pageSizes.add(limit);
          final all = storage.shots.values.map(ShotRecord.fromJson).toList()
            ..sort((a, b) {
              final c = b.timestamp.compareTo(a.timestamp);
              return c != 0 ? c : b.id.compareTo(a.id);
            });
          final start = all.indexWhere(
            (s) =>
                afterTimestamp == null ||
                s.timestamp.isBefore(afterTimestamp) ||
                (s.timestamp == afterTimestamp && s.id.compareTo(afterId!) < 0),
          );
          final from = start < 0 ? all.length : start;
          return all.skip(from).take(limit).toList();
        },
        pageSize: 100,
      );

      final sink = CapturingJsonSink();
      await section.exportJson(sink);

      expect(storage.pageSizes, everyElement(100));
      expect(storage.pageSizes.length, 3);

      final decoded = jsonDecode(sink.json) as List;
      expect(decoded, hasLength(250));
      expect(decoded.first['id'], 'shot-249');
      expect(decoded.last['id'], 'shot-0');
    });

    test('a lazy source is pulled only until exhausted', () async {
      var calls = 0;
      final section = ShotExportSection(
        controller: PersistenceController(
          storageService: _TestShotStorage().service,
        ),
        pageShots: (limit, {afterTimestamp, afterCreatedAt, afterId}) async {
          calls++;
          if (afterTimestamp == null) {
            return List.generate(limit, (i) => makeShot(i));
          }
          return [];
        },
        pageSize: 100,
      );
      final sink = CapturingJsonSink();
      await section.exportJson(sink);
      expect(calls, 2);
      expect(jsonDecode(sink.json), hasLength(100));
    });

    test('imports records incrementally with skip semantics', () async {
      final storage = _TestShotStorage();
      storage.shots['shot-1'] = makeShot(1).toJson();
      final section = ShotExportSection(
        controller: PersistenceController(storageService: storage.service),
        pageShots: (limit, {afterTimestamp, afterCreatedAt, afterId}) async =>
            [],
      );

      final json = jsonEncode(List.generate(50, (i) => makeShot(i).toJson()));
      final result = await importSectionJson(
        section,
        json,
        ConflictStrategy.skip,
      );
      expect(result.imported, 49);
      expect(result.skipped, 1);
      expect(result.errors, isEmpty);
      expect(storage.shots, hasLength(50));
    });

    test('imports records incrementally with overwrite semantics', () async {
      final storage = _TestShotStorage();
      storage.shots['shot-1'] = makeShot(1).toJson();
      final section = ShotExportSection(
        controller: PersistenceController(storageService: storage.service),
        pageShots: (limit, {afterTimestamp, afterCreatedAt, afterId}) async =>
            [],
      );

      final result = await importSectionJson(
        section,
        jsonEncode([makeShot(1).toJson()]),
        ConflictStrategy.overwrite,
      );
      expect(result.imported, 1);
      expect(storage.updated, 1);
    });

    test(
      'overwrite preserves createdAt and bumps updatedAt on content change',
      () async {
        final storage = _TestShotStorage();
        final existing = makeShot(1).copyWith(
          createdAt: DateTime.utc(2024, 1, 1, 8),
          updatedAt: DateTime.utc(2024, 1, 1, 8, 30),
          annotations: const ShotAnnotations(espressoNotes: 'old'),
        );
        storage.shots['shot-1'] = existing.toJson();
        final section = ShotExportSection(
          controller: PersistenceController(storageService: storage.service),
          pageShots: (limit, {afterTimestamp, afterCreatedAt, afterId}) async =>
              [],
        );

        final edited = makeShot(1).copyWith(
          createdAt: DateTime.utc(2020, 1, 1),
          updatedAt: DateTime.utc(2020, 1, 1),
          annotations: const ShotAnnotations(espressoNotes: 'new'),
        );
        final result = await importSectionJson(
          section,
          jsonEncode([edited.toJson()]),
          ConflictStrategy.overwrite,
        );
        expect(result.imported, 1);

        final stored = storage.shots['shot-1']!;
        expect(
          stored['createdAt'],
          existing.createdAt!.toUtc().toIso8601String(),
        );
        expect(stored['annotations']['espressoNotes'], 'new');
        expect(stored['updatedAt'], endsWith('Z'));
        expect(
          DateTime.parse(
            stored['updatedAt'] as String,
          ).isAfter(DateTime.utc(2024, 1, 1, 8, 30)),
          isTrue,
        );
      },
    );

    test('no-op overwrite preserves updatedAt', () async {
      final storage = _TestShotStorage();
      final existing = makeShot(1).copyWith(
        createdAt: DateTime.utc(2024, 1, 1, 8),
        updatedAt: DateTime.utc(2024, 1, 1, 8, 30),
        annotations: const ShotAnnotations(espressoNotes: 'same'),
      );
      storage.shots['shot-1'] = existing.toJson();
      final section = ShotExportSection(
        controller: PersistenceController(storageService: storage.service),
        pageShots: (limit, {afterTimestamp, afterCreatedAt, afterId}) async =>
            [],
      );

      final result = await importSectionJson(
        section,
        jsonEncode([existing.toJson()]),
        ConflictStrategy.overwrite,
      );
      expect(result.imported, 1);

      final stored = storage.shots['shot-1']!;
      expect(
        stored['createdAt'],
        existing.createdAt!.toUtc().toIso8601String(),
      );
      expect(
        stored['updatedAt'],
        existing.updatedAt!.toUtc().toIso8601String(),
      );
    });

    test(
      'overwrite confined to bookkeeping extras does not advance updatedAt',
      () async {
        final storage = _TestShotStorage();
        final existing = makeShot(1).copyWith(
          createdAt: DateTime.utc(2024, 1, 1, 8),
          updatedAt: DateTime.utc(2024, 1, 1, 8, 30),
          annotations: const ShotAnnotations(
            extras: {'favorite': true, 'uploaded_to_decent': 1},
          ),
        );
        storage.shots['shot-1'] = existing.toJson();
        final section = ShotExportSection(
          controller: PersistenceController(storageService: storage.service),
          pageShots: (limit, {afterTimestamp, afterCreatedAt, afterId}) async =>
              [],
        );

        final reimported = makeShot(1).copyWith(
          createdAt: DateTime.utc(2020, 1, 1),
          updatedAt: DateTime.utc(2020, 1, 1),
          annotations: const ShotAnnotations(
            extras: {'favorite': true, 'uploaded_to_decent': 2},
          ),
        );
        final result = await importSectionJson(
          section,
          jsonEncode([reimported.toJson()]),
          ConflictStrategy.overwrite,
        );
        expect(result.imported, 1);

        final stored = storage.shots['shot-1']!;
        expect(stored['annotations']['extras']['uploaded_to_decent'], 2);
        expect(
          stored['updatedAt'],
          existing.updatedAt!.toUtc().toIso8601String(),
        );
      },
    );

    test(
      'overwrite differing only in measurements advances updatedAt',
      () async {
        final storage = _TestShotStorage();
        final existing = makeShot(1).copyWith(
          createdAt: DateTime.utc(2024, 1, 1, 8),
          updatedAt: DateTime.utc(2024, 1, 1, 8, 30),
          measurements: [_snapshot().copyWith(volume: 36)],
        );
        storage.shots['shot-1'] = existing.toJson();
        final section = ShotExportSection(
          controller: PersistenceController(storageService: storage.service),
          pageShots: (limit, {afterTimestamp, afterCreatedAt, afterId}) async =>
              [],
        );

        final reimported = makeShot(1).copyWith(
          createdAt: DateTime.utc(2020, 1, 1),
          updatedAt: DateTime.utc(2020, 1, 1),
          measurements: [_snapshot().copyWith(volume: 42)],
        );
        final result = await importSectionJson(
          section,
          jsonEncode([reimported.toJson()]),
          ConflictStrategy.overwrite,
        );
        expect(result.imported, 1);

        final stored = storage.shots['shot-1']!;
        expect((stored['measurements'] as List).single['volume'], 42);
        expect(stored['updatedAt'], endsWith('Z'));
        expect(
          DateTime.parse(
            stored['updatedAt'] as String,
          ).isAfter(DateTime.utc(2024, 1, 1, 8, 30)),
          isTrue,
        );
      },
    );

    test('individually invalid records keep partial-result behavior', () async {
      final storage = _TestShotStorage();
      final section = ShotExportSection(
        controller: PersistenceController(storageService: storage.service),
        pageShots: (limit, {afterTimestamp, afterCreatedAt, afterId}) async =>
            [],
      );

      final workflowJson = jsonEncode(makeWorkflowJson());
      final json =
          '[{"id":"ok-1","timestamp":"2024-01-01T00:00:00Z","measurements":[],"workflow":$workflowJson},'
          '{"id":"bad","timestamp":null,"measurements":{},"workflow":$workflowJson},'
          '{"id":"ok-2","timestamp":"2024-01-02T00:00:00Z","measurements":[],"workflow":$workflowJson}]';
      final result = await importSectionJson(
        section,
        json,
        ConflictStrategy.skip,
      );
      expect(result.imported, 2);
      expect(result.errors, hasLength(1));
    });

    test('bounds semantic record errors', () async {
      final storage = _TestShotStorage();
      final section = ShotExportSection(
        controller: PersistenceController(storageService: storage.service),
        pageShots: (limit, {afterTimestamp, afterCreatedAt, afterId}) async =>
            [],
      );

      final result = await importSectionJson(
        section,
        jsonEncode(List.generate(101, (_) => <String, dynamic>{})),
        ConflictStrategy.skip,
      );

      expect(result.errors, hasLength(101));
      expect(result.errors.last, '1 additional error omitted');
    });

    test('rejects a structurally malformed section payload', () async {
      final storage = _TestShotStorage();
      final section = ShotExportSection(
        controller: PersistenceController(storageService: storage.service),
        pageShots: (limit, {afterTimestamp, afterCreatedAt, afterId}) async =>
            [],
      );
      final workflowJson = jsonEncode(makeWorkflowJson());
      await expectLater(
        importSectionJson(
          section,
          '[{"id":"a","timestamp":"2024-01-01T00:00:00Z","measurements":[],"workflow":$workflowJson}, {"id":',
          ConflictStrategy.skip,
        ),
        throwsA(isA<JsonStreamFormatException>()),
      );
      expect(storage.shots, isEmpty);
    });

    test('rejects a non-array payload without importing', () async {
      final storage = _TestShotStorage();
      final section = ShotExportSection(
        controller: PersistenceController(storageService: storage.service),
        pageShots: (limit, {afterTimestamp, afterCreatedAt, afterId}) async =>
            [],
      );
      final result = await importSectionJson(
        section,
        '{"a": 1}',
        ConflictStrategy.skip,
      );
      expect(result.errors, hasLength(1));
      expect(storage.shots, isEmpty);
    });
  });
}
