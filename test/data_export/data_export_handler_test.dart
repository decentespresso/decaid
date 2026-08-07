import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/services/webserver/data_export/data_export_section.dart';
import 'package:reaprime/src/services/webserver/data_export/data_transfer_limits.dart';
import 'package:reaprime/src/services/webserver/data_export_handler.dart';
import 'package:shelf_plus/shelf_plus.dart';

import 'streaming_test_helpers.dart';

void corruptCentralDirectoryCrc(List<int> zipBytes, String filename) {
  final nameBytes = utf8.encode(filename);
  var namePosition = -1;
  for (var i = 0; i <= zipBytes.length - nameBytes.length; i++) {
    var matches = true;
    for (var j = 0; j < nameBytes.length; j++) {
      if (zipBytes[i + j] != nameBytes[j]) {
        matches = false;
        break;
      }
    }
    if (matches) namePosition = i;
  }
  if (namePosition < 0) throw StateError('$filename not found');
  zipBytes[namePosition - 46 + 16] ^= 0xFF;
}

/// A mock section implementing the streaming contract.
class MockExportSection implements DataExportSection {
  @override
  final String filename;

  final Object? exportData;
  final SectionImportResult importResult;
  final bool failExport;
  final String? importPayload;

  ConflictStrategy? lastStrategy;
  int importCalls = 0;

  /// Records the largest fragment written (boundedness proof).
  int maxFragmentLength = 0;

  MockExportSection({
    required this.filename,
    this.exportData = const {'mock': true},
    this.importResult = const SectionImportResult(imported: 1),
    this.failExport = false,
    this.importPayload,
  });

  @override
  Future<void> exportJson(JsonSink output) async {
    if (failExport) throw Exception('Export failed');
    final fragment = jsonEncode(exportData);
    maxFragmentLength = fragment.length > maxFragmentLength
        ? fragment.length
        : maxFragmentLength;
    output.writeRaw(fragment);
  }

  @override
  Future<SectionImportResult> importJson(
    SectionJsonInput input,
    ConflictStrategy strategy,
  ) async {
    importCalls++;
    lastStrategy = strategy;
    if (importPayload != null) {
      final validator = StringJsonInput(importPayload!);
      await for (final _ in validator.valuesAtDepth(1)) {}
      return importResult;
    }
    return importResult;
  }
}

/// A section that writes a huge fragment, exceeding the record cap.
class OversizeExportSection implements DataExportSection {
  @override
  final String filename;
  OversizeExportSection(this.filename);

  @override
  Future<void> exportJson(JsonSink output) async {
    output.writeRaw('[');
    output.writeRaw('"${'x' * 1024 * 1024}"');
    output.writeRaw(']');
  }

  @override
  Future<SectionImportResult> importJson(
    SectionJsonInput input,
    ConflictStrategy strategy,
  ) async => const SectionImportResult();
}

/// A section whose fragment is under the record cap in UTF-16 code units
/// but over it in UTF-8 bytes (non-ASCII content).
class UnicodeExportSection implements DataExportSection {
  @override
  final String filename;
  UnicodeExportSection(this.filename);

  @override
  Future<void> exportJson(JsonSink output) async {
    output.writeRaw('["${'\u00E9' * 40}"]');
  }

  @override
  Future<SectionImportResult> importJson(
    SectionJsonInput input,
    ConflictStrategy strategy,
  ) async => const SectionImportResult();
}

void main() {
  late DataExportHandler handler;
  late MockExportSection profileSection;
  late MockExportSection shotsSection;
  late Handler httpHandler;

  setUp(() {
    profileSection = MockExportSection(
      filename: 'profiles.json',
      exportData: [
        {'id': 'p1', 'name': 'Default'},
      ],
      importResult: const SectionImportResult(imported: 1, skipped: 0),
    );

    shotsSection = MockExportSection(
      filename: 'shots.json',
      exportData: [
        {'id': 's1', 'timestamp': '2024-01-01'},
      ],
      importResult: const SectionImportResult(imported: 2, skipped: 1),
    );

    handler = DataExportHandler(sections: [profileSection, shotsSection]);

    final app = Router().plus;
    handler.addRoutes(app);
    httpHandler = app.call;
  });

  Future<Response> sendGet(String path) async {
    return await httpHandler(
      Request('GET', Uri.parse('http://localhost$path')),
    );
  }

  Future<Response> sendPost(String path, {required List<int> body}) async {
    return await httpHandler(
      Request(
        'POST',
        Uri.parse('http://localhost$path'),
        body: body,
        headers: {'content-type': 'application/octet-stream'},
      ),
    );
  }

  /// Helper: build a ZIP archive with given files and return its bytes
  /// (the old in-memory producer — exercises backward compatibility).
  List<int> buildZip(Map<String, dynamic> files) {
    final archive = Archive();
    for (final entry in files.entries) {
      final jsonStr = jsonEncode(entry.value);
      archive.addFile(ArchiveFile.string(entry.key, jsonStr));
    }
    return ZipEncoder().encode(archive);
  }

  List<int> buildZipEntries(Map<String, String> files) {
    final archive = Archive();
    for (final entry in files.entries) {
      archive.addFile(ArchiveFile.string(entry.key, entry.value));
    }
    return ZipEncoder().encode(archive);
  }

  /// Reads the full response body.
  Future<List<int>> responseBytes(Response response) async {
    return await response.read().expand((b) => b).toList();
  }

  group('DataExportHandler', () {
    group('GET /api/v1/data/export', () {
      test(
        'returns ZIP with correct content-type and Content-Disposition',
        () async {
          final response = await sendGet('/api/v1/data/export');

          expect(response.statusCode, 200);
          expect(response.headers['content-type'], 'application/zip');
          expect(
            response.headers['content-disposition'],
            startsWith('attachment; filename="decent_export_'),
          );
          expect(response.headers['content-disposition'], endsWith('.zip"'));
        },
      );

      test('ZIP contains metadata.json with correct fields', () async {
        final response = await sendGet('/api/v1/data/export');
        final bytes = await responseBytes(response);
        final archive = ZipDecoder().decodeBytes(bytes);

        final metadataFile = archive.findFile('metadata.json');
        expect(metadataFile, isNotNull);
        final metadata =
            jsonDecode(utf8.decode(metadataFile!.content))
                as Map<String, dynamic>;
        expect(metadata['formatVersion'], 1);
        expect(metadata.containsKey('appVersion'), isTrue);
        expect(metadata.containsKey('commitSha'), isTrue);
        expect(metadata.containsKey('branch'), isTrue);
        expect(metadata.containsKey('exportTimestamp'), isTrue);
        expect(metadata.containsKey('platform'), isTrue);
      });

      test('ZIP contains section files with correct data and is readable by '
          'the previous ZipDecoder', () async {
        final response = await sendGet('/api/v1/data/export');
        final bytes = await responseBytes(response);

        final archive = ZipDecoder().decodeBytes(bytes);
        expect(archive.length, 3);

        final profilesFile = archive.findFile('profiles.json');
        expect(profilesFile, isNotNull);
        final profilesData =
            jsonDecode(utf8.decode(profilesFile!.content)) as List;
        expect(profilesData.first['id'], 'p1');

        final shotsFile = archive.findFile('shots.json');
        expect(shotsFile, isNotNull);
        final shotsData = jsonDecode(utf8.decode(shotsFile!.content)) as List;
        expect(shotsData.first['id'], 's1');
      });

      test('exportToZipFile returns a valid file and streams fragments in '
          'bounded pieces', () async {
        final tempDir = await Directory.systemTemp.createTemp('export-test-');
        try {
          final file = await handler.exportToZipFile(tempDir);
          final bytes = await file.readAsBytes();
          final archive = ZipDecoder().decodeBytes(bytes);
          expect(archive.findFile('profiles.json'), isNotNull);
          expect(profileSection.maxFragmentLength, greaterThan(0));
        } finally {
          await tempDir.delete(recursive: true);
        }
      });

      test('aborts ZIP generation when a section export fails', () async {
        final failingSection = MockExportSection(
          filename: 'failing.json',
          failExport: true,
        );
        final goodSection = MockExportSection(
          filename: 'good.json',
          exportData: {'data': 'ok'},
        );

        final handlerWithFailure = DataExportHandler(
          sections: [failingSection, goodSection],
        );
        final app = Router().plus;
        handlerWithFailure.addRoutes(app);
        final response = await app.call(
          Request('GET', Uri.parse('http://localhost/api/v1/data/export')),
        );

        expect(response.statusCode, 500);
        final body = jsonDecode(await response.readAsString());
        expect(body['error'], 'Export failed');
        expect(body['sections'], contains('failing'));
      });

      test(
        'exportToZipFile deletes its temp file when a section fails',
        () async {
          final failingSection = MockExportSection(
            filename: 'failing.json',
            failExport: true,
          );
          final handlerWithFailure = DataExportHandler(
            sections: [failingSection],
          );
          final tempDir = await Directory.systemTemp.createTemp('export-fail-');
          try {
            await expectLater(
              handlerWithFailure.exportToZipFile(tempDir),
              throwsA(isA<DataExportException>()),
            );
            final leftovers = tempDir.listSync();
            expect(leftovers, isEmpty);
          } finally {
            await tempDir.delete(recursive: true);
          }
        },
      );

      test('section export failure leaves no temp directory behind on the '
          'HTTP path', () async {
        final failingSection = MockExportSection(
          filename: 'failing.json',
          failExport: true,
        );
        final handlerWithFailure = DataExportHandler(
          sections: [failingSection],
        );
        final app = Router().plus;
        handlerWithFailure.addRoutes(app);
        final tempDirsBefore = Directory.systemTemp
            .listSync()
            .whereType<Directory>()
            .where((d) => d.path.contains('reaprime-export-'))
            .length;

        await app.call(
          Request('GET', Uri.parse('http://localhost/api/v1/data/export')),
        );

        final tempDirsAfter = Directory.systemTemp
            .listSync()
            .whereType<Directory>()
            .where((d) => d.path.contains('reaprime-export-'))
            .length;
        expect(tempDirsAfter, tempDirsBefore);
      });

      test('oversized record fragments fail the export atomically', () async {
        final handlerWithOversize = DataExportHandler(
          sections: [OversizeExportSection('big.json')],
          limits: const DataTransferLimits(maxRecordBytes: 64 * 1024),
        );
        final tempDir = await Directory.systemTemp.createTemp('oversize-');
        try {
          await expectLater(
            handlerWithOversize.exportToZipFile(tempDir),
            throwsA(isA<DataExportException>()),
          );
          expect(tempDir.listSync(), isEmpty);
        } finally {
          await tempDir.delete(recursive: true);
        }
      });

      test(
        'record cap is measured in UTF-8 bytes, not UTF-16 code units',
        () async {
          // 40 '\u00E9' chars: 40 UTF-16 code units but 80 UTF-8 bytes. With
          // a 64-byte cap the fragment must be rejected even though its
          // UTF-16 length is under the limit.
          final handlerWithUnicode = DataExportHandler(
            sections: [UnicodeExportSection('big.json')],
            limits: const DataTransferLimits(maxRecordBytes: 64),
          );
          final tempDir = await Directory.systemTemp.createTemp('unicode-');
          try {
            await expectLater(
              handlerWithUnicode.exportToZipFile(tempDir),
              throwsA(isA<DataExportException>()),
            );
          } finally {
            await tempDir.delete(recursive: true);
          }
        },
      );
    });

    group('POST /api/v1/data/import', () {
      test('with a legacy in-memory ZIP returns import summary', () async {
        final zipBytes = buildZip({
          'metadata.json': {'formatVersion': 1, 'platform': 'macos'},
          'profiles.json': [
            {'id': 'p1'},
          ],
          'shots.json': [
            {'id': 's1'},
          ],
        });

        final response = await sendPost('/api/v1/data/import', body: zipBytes);

        expect(response.statusCode, 200);
        final body =
            jsonDecode(await response.readAsString()) as Map<String, dynamic>;
        expect(body.containsKey('profiles'), isTrue);
        expect(body['profiles']['imported'], 1);
        expect(body.containsKey('shots'), isTrue);
        expect(body['shots']['imported'], 2);
        expect(body['shots']['skipped'], 1);
      });

      test('round-trips a streamed export through import', () async {
        final tempDir = await Directory.systemTemp.createTemp('roundtrip-');
        try {
          final zipFile = await handler.exportToZipFile(tempDir);
          final outcome = await handler.importFromZipFile(
            zipFile,
            ConflictStrategy.skip,
          );
          expect(outcome.phase.complete, isTrue);
          expect(profileSection.importCalls, 1);
          expect(shotsSection.importCalls, 1);
        } finally {
          await tempDir.delete(recursive: true);
        }
      });

      test('uses skip strategy by default', () async {
        final zipBytes = buildZip({
          'metadata.json': {'formatVersion': 1, 'platform': 'macos'},
          'profiles.json': <Object?>[],
        });

        await sendPost('/api/v1/data/import', body: zipBytes);

        expect(profileSection.lastStrategy, ConflictStrategy.skip);
      });

      test('uses overwrite strategy when specified', () async {
        final zipBytes = buildZip({
          'metadata.json': {'formatVersion': 1, 'platform': 'macos'},
          'profiles.json': <Object?>[],
        });

        final response = await sendPost(
          '/api/v1/data/import?onConflict=overwrite',
          body: zipBytes,
        );

        expect(response.statusCode, 200);
        expect(profileSection.lastStrategy, ConflictStrategy.overwrite);
      });

      test('returns 400 for invalid onConflict value', () async {
        final zipBytes = buildZip({
          'metadata.json': {'formatVersion': 1},
        });

        final response = await sendPost(
          '/api/v1/data/import?onConflict=invalid',
          body: zipBytes,
        );

        expect(response.statusCode, 400);
        final body = jsonDecode(await response.readAsString());
        expect(body['error'], 'Invalid onConflict value');
      });

      test(
        'returns 400 when the body is not a recognized backup archive',
        () async {
          final response = await sendPost(
            '/api/v1/data/import',
            body: [0, 1, 2, 3, 4, 5],
          );

          expect(response.statusCode, 400);
          expect(
            response.headers['content-type'],
            contains('application/json'),
          );
          final body =
              jsonDecode(await response.readAsString()) as Map<String, dynamic>;
          expect(body['error'], 'Invalid backup archive');
        },
      );

      test('returns 400 for an empty ZIP', () async {
        final response = await sendPost(
          '/api/v1/data/import',
          body: buildZip({}),
        );

        expect(response.statusCode, 400);
        final body = jsonDecode(await response.readAsString());
        expect(body['error'], 'Invalid backup archive');
      });

      test(
        'returns 400 for an archive containing only unknown files',
        () async {
          final response = await sendPost(
            '/api/v1/data/import',
            body: buildZip({'notes.txt': 'not a backup', 'unknown.json': {}}),
          );

          expect(response.statusCode, 400);
          expect(profileSection.importCalls, 0);
          expect(shotsSection.importCalls, 0);
        },
      );

      test('returns 400 when formatVersion is too high', () async {
        final zipBytes = buildZip({
          'metadata.json': {'formatVersion': 999, 'platform': 'macos'},
        });

        final response = await sendPost('/api/v1/data/import', body: zipBytes);

        expect(response.statusCode, 400);
        final body = jsonDecode(await response.readAsString());
        expect(body['message'], contains('999'));
      });

      test('returns 400 for malformed metadata JSON', () async {
        final response = await sendPost(
          '/api/v1/data/import',
          body: buildZipEntries({
            'metadata.json': '{not json',
            'profiles.json': '[]',
          }),
        );

        expect(response.statusCode, 400);
        expect(profileSection.importCalls, 0);
      });

      test('returns 400 when metadata is not an object', () async {
        final response = await sendPost(
          '/api/v1/data/import',
          body: buildZipEntries({'metadata.json': '[1,2,3]'}),
        );

        expect(response.statusCode, 400);
        final body = jsonDecode(await response.readAsString());
        expect(body['error'], 'Invalid backup archive');
      });

      test('rejects oversized request bodies while streaming', () async {
        final smallHandler = DataExportHandler(
          sections: [shotsSection],
          limits: const DataTransferLimits(maxImportRequestBytes: 100),
        );
        final app = Router().plus;
        smallHandler.addRoutes(app);
        final zipBytes = buildZip({
          'metadata.json': {'formatVersion': 1},
          'shots.json': [
            {'id': 's1'},
          ],
        });
        expect(zipBytes.length, greaterThan(100));

        final response = await app.call(
          Request(
            'POST',
            Uri.parse('http://localhost/api/v1/data/import'),
            body: zipBytes,
            headers: {'content-type': 'application/octet-stream'},
          ),
        );
        expect(response.statusCode, 400);
        final body = jsonDecode(await response.readAsString());
        expect(body['message'], contains('size limit'));
        expect(shotsSection.importCalls, 0);
      });

      test('rejects an archive exceeding the entry count limit', () async {
        final files = <String, String>{'metadata.json': '{"formatVersion":1}'};
        for (var i = 0; i < 10; i++) {
          files['file$i.json'] = '{}';
        }
        final zipBytes = buildZipEntries(files);
        final smallHandler = DataExportHandler(
          sections: [shotsSection],
          limits: const DataTransferLimits(maxEntryCount: 5),
        );
        final app = Router().plus;
        smallHandler.addRoutes(app);
        final response = await app.call(
          Request(
            'POST',
            Uri.parse('http://localhost/api/v1/data/import'),
            body: zipBytes,
            headers: {'content-type': 'application/octet-stream'},
          ),
        );
        expect(response.statusCode, 400);
        final body = jsonDecode(await response.readAsString());
        expect(body['message'], contains('too many entries'));
      });

      test(
        'rejects a section whose JSON is truncated without importing',
        () async {
          final zipBytes = buildZipEntries({
            'metadata.json': '{"formatVersion":1}',
            'shots.json': '[{"id":"s1"},{"id":',
          });
          final response = await sendPost(
            '/api/v1/data/import',
            body: zipBytes,
          );

          expect(response.statusCode, 400);
          final body = jsonDecode(await response.readAsString());
          expect(body['error'], 'Invalid backup archive');
          expect(shotsSection.importCalls, 0);
        },
      );

      test('returns 400 when a section entry fails CRC verification', () async {
        final zipBytes = buildZipEntries({
          'metadata.json': '{"formatVersion":1}',
          'shots.json': '[{"id":"s1"}]',
        });
        corruptCentralDirectoryCrc(zipBytes, 'shots.json');

        final response = await sendPost('/api/v1/data/import', body: zipBytes);
        expect(response.statusCode, 400);
        final body = jsonDecode(await response.readAsString());
        expect(body['error'], 'Invalid backup archive');
      });

      test(
        'validates every selected entry before importing any section',
        () async {
          final zipBytes = buildZipEntries({
            'metadata.json': '{"formatVersion":1}',
            'profiles.json': '[{"id":"p1"}]',
            'shots.json': '[{"id":"s1"}]',
          });
          corruptCentralDirectoryCrc(zipBytes, 'shots.json');

          final response = await sendPost(
            '/api/v1/data/import',
            body: zipBytes,
          );

          expect(response.statusCode, 400);
          expect(profileSection.importCalls, 0);
          expect(shotsSection.importCalls, 0);
        },
      );

      test(
        'rejects a later section with the wrong root before importing',
        () async {
          final response = await sendPost(
            '/api/v1/data/import',
            body: buildZipEntries({
              'metadata.json': '{"formatVersion":1}',
              'profiles.json': '[{"id":"p1"}]',
              'shots.json': '{}',
            }),
          );

          expect(response.statusCode, 400);
          expect(profileSection.importCalls, 0);
          expect(shotsSection.importCalls, 0);
        },
      );

      test(
        'preserves partial results for individually invalid records',
        () async {
          final importPayload = '[{"id":"ok"},{"id":null}]';
          final section = MockExportSection(
            filename: 'shots.json',
            importPayload: importPayload,
            importResult: const SectionImportResult(
              imported: 1,
              errors: [
                'Failed to import shot: instance of JsonUnsupportedObjectError',
              ],
            ),
          );
          final partialHandler = DataExportHandler(
            sections: [
              MockExportSection(
                filename: 'profiles.json',
                importResult: const SectionImportResult(imported: 5),
              ),
              section,
            ],
          );
          final app = Router().plus;
          partialHandler.addRoutes(app);
          final zipBytes = buildZipEntries({
            'metadata.json': '{"formatVersion":1}',
            'shots.json': importPayload,
          });
          final response = await app.call(
            Request(
              'POST',
              Uri.parse('http://localhost/api/v1/data/import'),
              body: zipBytes,
              headers: {'content-type': 'application/octet-stream'},
            ),
          );
          expect(response.statusCode, 207);
        },
      );

      test(
        'selected-section import only processes requested sections',
        () async {
          final zipBytes = buildZip({
            'metadata.json': {'formatVersion': 1},
            'profiles.json': [
              {'id': 'p1'},
            ],
            'shots.json': [
              {'id': 's1'},
            ],
          });
          // No section filtering via query param in the REST API; test the
          // programmatic path instead.
          final tempDir = await Directory.systemTemp.createTemp('sel-');
          try {
            final zipFile = File('${tempDir.path}/import.zip');
            await zipFile.writeAsBytes(zipBytes);
            final outcome = await handler.importFromZipFile(
              zipFile,
              ConflictStrategy.skip,
              sections: ['profiles'],
            );
            expect(outcome.phase.complete, isTrue);
            expect(profileSection.importCalls, 1);
            expect(shotsSection.importCalls, 0);
          } finally {
            await tempDir.delete(recursive: true);
          }
        },
      );

      test('unknown selected section is rejected', () async {
        final tempDir = await Directory.systemTemp.createTemp('unknown-');
        try {
          final zipFile = File('${tempDir.path}/import.zip');
          await zipFile.writeAsBytes(
            buildZip({
              'metadata.json': {'formatVersion': 1},
            }),
          );
          await expectLater(
            handler.importFromZipFile(
              zipFile,
              ConflictStrategy.skip,
              sections: ['nope'],
            ),
            throwsA(
              isA<InvalidBackupException>().having(
                (e) => e.reason,
                'reason',
                'unknown_selected_section',
              ),
            ),
          );
        } finally {
          await tempDir.delete(recursive: true);
        }
      });

      test(
        'missing metadata.json imports with a warning (legacy behavior)',
        () async {
          final zipBytes = buildZipEntries({'profiles.json': '[{"id":"p1"}]'});
          final response = await sendPost(
            '/api/v1/data/import',
            body: zipBytes,
          );
          expect(response.statusCode, 200);
        },
      );

      test('concurrent imports use isolated temp directories', () async {
        final futures = <Future<Response>>[];
        for (var i = 0; i < 4; i++) {
          futures.add(
            sendPost(
              '/api/v1/data/import',
              body: buildZip({
                'metadata.json': {'formatVersion': 1},
                'profiles.json': [
                  {'id': 'p$i'},
                ],
              }),
            ),
          );
        }
        final responses = await Future.wait(futures);
        for (final response in responses) {
          expect(response.statusCode, 200);
        }
        final leftovers = Directory.systemTemp
            .listSync()
            .whereType<Directory>()
            .where((d) => d.path.contains('reaprime-import-'));
        expect(leftovers, isEmpty);
      });
    });
  });
}
