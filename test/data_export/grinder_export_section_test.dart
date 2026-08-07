import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/data/grinder.dart';
import 'package:reaprime/src/services/storage/grinder_storage_service.dart';
import 'package:reaprime/src/services/webserver/data_export/data_export_section.dart';
import 'package:reaprime/src/services/webserver/data_export/grinder_export_section.dart';
import 'package:reaprime/src/util/incremental_json_parser.dart';

import 'streaming_test_helpers.dart';

class MockGrinderStorage implements GrinderStorageService {
  final List<Grinder> grinders = [];

  @override
  Future<List<Grinder>> getAllGrinders({bool includeArchived = false}) async {
    throw StateError(
      'getAllGrinders must not be called during streaming export',
    );
  }

  @override
  Stream<List<Grinder>> watchAllGrinders({bool includeArchived = false}) =>
      const Stream.empty();

  @override
  Future<Grinder?> getGrinderById(String id) async =>
      grinders.where((g) => g.id == id).firstOrNull;

  @override
  Future<void> insertGrinder(Grinder grinder) async => grinders.add(grinder);

  @override
  Future<void> updateGrinder(Grinder grinder) async {
    grinders.removeWhere((g) => g.id == grinder.id);
    grinders.add(grinder);
  }

  @override
  Future<void> deleteGrinder(String id) async =>
      grinders.removeWhere((g) => g.id == id);
}

Grinder makeGrinder(int i) => Grinder(
  id: 'grinder-$i',
  model: 'Niche $i',
  createdAt: DateTime(2024, 1, 1).add(Duration(days: i)),
  updatedAt: DateTime(2024, 1, 1).add(Duration(days: i)),
);

void main() {
  group('GrinderExportSection', () {
    test(
      'streams grinders in bounded pages and encodes a JSON array',
      () async {
        final pageSizes = <int>[];
        final section = GrinderExportSection(
          storage: MockGrinderStorage(),
          pageGrinders:
              (limit, {afterTimestamp, afterCreatedAt, afterId}) async {
                pageSizes.add(limit);
                final all = List.generate(120, makeGrinder)
                  ..sort((a, b) {
                    final c = a.createdAt.compareTo(b.createdAt);
                    return c != 0 ? c : a.id.compareTo(b.id);
                  });
                final start = all.indexWhere(
                  (g) =>
                      afterCreatedAt == null ||
                      g.createdAt.isAfter(afterCreatedAt) ||
                      (g.createdAt == afterCreatedAt &&
                          g.id.compareTo(afterId!) > 0),
                );
                final from = start < 0 ? all.length : start;
                return all.skip(from).take(limit).toList();
              },
          pageSize: 100,
        );

        final sink = CapturingJsonSink();
        await section.exportJson(sink);
        expect(pageSizes, [100, 100]);
        final decoded = jsonDecode(sink.json) as List;
        expect(decoded, hasLength(120));
        expect(decoded.last['id'], 'grinder-119');
      },
    );

    test('imports grinders with skip/overwrite semantics', () async {
      final storage = MockGrinderStorage()..grinders.add(makeGrinder(0));
      final section = GrinderExportSection(
        storage: storage,
        pageGrinders:
            (limit, {afterTimestamp, afterCreatedAt, afterId}) async => [],
      );
      final json = jsonEncode([
        makeGrinder(0).toJson(),
        makeGrinder(1).toJson(),
      ]);
      final skip = await importSectionJson(
        section,
        json,
        ConflictStrategy.skip,
      );
      expect(skip.imported, 1);
      expect(skip.skipped, 1);

      final overwrite = await importSectionJson(
        section,
        jsonEncode([makeGrinder(0).toJson()]),
        ConflictStrategy.overwrite,
      );
      expect(overwrite.imported, 1);
    });

    test('rejects malformed and non-array payloads', () async {
      final storage = MockGrinderStorage();
      final section = GrinderExportSection(
        storage: storage,
        pageGrinders:
            (limit, {afterTimestamp, afterCreatedAt, afterId}) async => [],
      );
      await expectLater(
        importSectionJson(section, '[{"id":', ConflictStrategy.skip),
        throwsA(isA<JsonStreamFormatException>()),
      );
      final nonArray = await importSectionJson(
        section,
        '{"grinders": []}',
        ConflictStrategy.skip,
      );
      expect(nonArray.errors, hasLength(1));
      expect(storage.grinders, isEmpty);
    });
  });
}
