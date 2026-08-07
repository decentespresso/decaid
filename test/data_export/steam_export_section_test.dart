import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/persistence_controller.dart';
import 'package:reaprime/src/models/data/steam_record.dart';
import 'package:reaprime/src/models/data/workflow.dart';
import 'package:reaprime/src/models/data/shot_record.dart';
import 'package:reaprime/src/services/storage/storage_service.dart';
import 'package:reaprime/src/services/webserver/data_export/data_export_section.dart';
import 'package:reaprime/src/services/webserver/data_export/steam_export_section.dart';
import 'package:reaprime/src/util/incremental_json_parser.dart';

import 'shot_export_section_test.dart' show makeWorkflowJson;
import 'streaming_test_helpers.dart';

class _RecordingSteamStorage implements StorageService {
  final Map<String, Map<String, dynamic>> records = {};
  int stored = 0;
  int updated = 0;
  int steamsChangedNotifications = 0;

  @override
  Future<SteamRecord?> getSteam(String id) async {
    final json = records[id];
    return json == null ? null : SteamRecord.fromJson(json);
  }

  @override
  Future<void> storeSteam(SteamRecord record) async {
    records[record.id] = record.toJson();
    stored++;
  }

  @override
  Future<void> updateSteam(SteamRecord record) async {
    records[record.id] = record.toJson();
    updated++;
  }

  @override
  Future<void> deleteSteam(String id) async {
    records.remove(id);
  }

  @override
  Future<List<String>> getSteamIds() async => records.keys.toList();

  @override
  Future<List<SteamRecord>> getAllSteams() async =>
      records.values.map(SteamRecord.fromJson).toList();

  @override
  Future<SteamRecord?> getLatestSteam() async => null;

  @override
  Future<SteamRecord?> getLatestSteamMeta() async => null;

  @override
  Future<void> storeShot(ShotRecord record) async {}
  @override
  Future<void> updateShot(ShotRecord record) async {}
  @override
  Future<void> deleteShot(String id) async {}
  @override
  Future<List<String>> getShotIds() async => [];
  @override
  Future<List<ShotRecord>> getAllShots() async => [];
  @override
  Future<ShotRecord?> getShot(String id) async => null;
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
  }) async => [];
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
  }) async => 0;
  @override
  Future<ShotRecord?> getLatestShot() async => null;
  @override
  Future<ShotRecord?> getLatestShotMeta() async => null;
  @override
  Future<void> storeCurrentWorkflow(Workflow workflow) async {}
  @override
  Future<Workflow?> loadCurrentWorkflow() async => null;
}

Map<String, dynamic> makeSteam(int i) => {
  'id': 'steam-$i',
  'timestamp': DateTime(2024, 1, 1).add(Duration(minutes: i)).toIso8601String(),
  'workflow': makeWorkflowJson(),
  'measurements': <Object?>[],
};

void main() {
  group('SteamExportSection', () {
    test('streams records in bounded pages and encodes a JSON array', () async {
      final pages = <int>[];
      final section = SteamExportSection(
        controller: PersistenceController(
          storageService: _RecordingSteamStorage(),
        ),
        pageSteams: (limit, {afterTimestamp, afterCreatedAt, afterId}) async {
          pages.add(limit);
          final all =
              List.generate(250, (i) => SteamRecord.fromJson(makeSteam(i)))
                ..sort((a, b) {
                  final c = a.timestamp.compareTo(b.timestamp);
                  return c != 0 ? c : a.id.compareTo(b.id);
                });
          final start = all.indexWhere(
            (s) =>
                afterTimestamp == null ||
                s.timestamp.isAfter(afterTimestamp) ||
                (s.timestamp == afterTimestamp && s.id.compareTo(afterId!) > 0),
          );
          final from = start < 0 ? all.length : start;
          return all.skip(from).take(limit).toList();
        },
        pageSize: 100,
      );

      final sink = CapturingJsonSink();
      await section.exportJson(sink);
      expect(pages, everyElement(100));
      expect(pages, hasLength(3));
      final decoded = jsonDecode(sink.json) as List;
      expect(decoded, hasLength(250));
      expect(decoded.last['id'], 'steam-249');
    });

    test('imports records incrementally with skip and overwrite', () async {
      final storage = _RecordingSteamStorage();
      final section = SteamExportSection(
        controller: PersistenceController(storageService: storage),
        pageSteams: (limit, {afterTimestamp, afterCreatedAt, afterId}) async =>
            [],
      );
      final result = await importSectionJson(
        section,
        jsonEncode(List.generate(30, (i) => makeSteam(i))),
        ConflictStrategy.skip,
      );
      expect(result.imported, 30);
      expect(result.errors, isEmpty);
      expect(storage.records, hasLength(30));

      final overwrite = await importSectionJson(
        section,
        jsonEncode([makeSteam(0)]),
        ConflictStrategy.overwrite,
      );
      expect(overwrite.imported, 1);
      expect(storage.updated, 1);
    });

    test('individually invalid records keep partial results', () async {
      final section = SteamExportSection(
        controller: PersistenceController(
          storageService: _RecordingSteamStorage(),
        ),
        pageSteams: (limit, {afterTimestamp, afterCreatedAt, afterId}) async =>
            [],
      );
      final result = await importSectionJson(
        section,
        '[${jsonEncode(makeSteam(1))},'
        '{"id":"bad","timestamp":null},'
        '${jsonEncode(makeSteam(2))}]',
        ConflictStrategy.skip,
      );
      expect(result.imported, 2);
      expect(result.errors, hasLength(1));
    });

    test(
      'rejects malformed and non-array payloads without importing',
      () async {
        final storage = _RecordingSteamStorage();
        final section = SteamExportSection(
          controller: PersistenceController(storageService: storage),
          pageSteams:
              (limit, {afterTimestamp, afterCreatedAt, afterId}) async => [],
        );
        await expectLater(
          importSectionJson(
            section,
            '[${jsonEncode(makeSteam(1))}, ',
            ConflictStrategy.skip,
          ),
          throwsA(isA<JsonStreamFormatException>()),
        );
        final nonArray = await importSectionJson(
          section,
          '{"a": 1}',
          ConflictStrategy.skip,
        );
        expect(nonArray.errors, hasLength(1));
        expect(storage.stored, 0);
      },
    );
  });
}
