import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:http/testing.dart' as http_testing;
import 'package:reaprime/src/services/webserver/data_export/data_export_section.dart';
import 'package:reaprime/src/services/webserver/data_export/data_transfer_limits.dart';
import 'package:reaprime/src/services/webserver/data_export_handler.dart';
import 'package:reaprime/src/services/webserver/data_sync_handler.dart';
import 'package:shelf_plus/shelf_plus.dart';

class MockExportSection implements DataExportSection {
  @override
  final String filename;

  final Object? exportData;
  final SectionImportResult importResult;
  final bool failExport;
  final int importCalls;

  ConflictStrategy? lastStrategy;
  int _calls = 0;

  MockExportSection({
    required this.filename,
    this.exportData = const {'mock': true},
    this.importResult = const SectionImportResult(imported: 1),
    this.failExport = false,
    this.importCalls = 0,
  });

  @override
  Future<void> exportJson(JsonSink output) async {
    if (failExport) throw Exception('Export failed');
    output.writeRaw(jsonEncode(exportData));
  }

  @override
  Future<SectionImportResult> importJson(
    SectionJsonInput input,
    ConflictStrategy strategy,
  ) async {
    _calls++;
    lastStrategy = strategy;
    await for (final _ in input.valuesAtDepth(1)) {}
    return importResult;
  }

  int get calls => _calls;
}

class SlowImportSection extends MockExportSection {
  final Duration delay;

  SlowImportSection({required super.filename, required this.delay});

  @override
  Future<SectionImportResult> importJson(
    SectionJsonInput input,
    ConflictStrategy strategy,
  ) async {
    await Future<void>.delayed(delay);
    return super.importJson(input, strategy);
  }
}

List<int> buildZip(Map<String, dynamic> files) {
  return ZipEncoderLegacy.encode(files);
}

class ZipEncoderLegacy {
  static List<int> encode(Map<String, dynamic> files) {
    final archive = <String, String>{};
    files.forEach((name, value) {
      archive[name] = jsonEncode(value);
    });
    return buildRawZip(archive);
  }
}

List<int> buildRawZip(Map<String, String> files) {
  final entries = <Map<String, Object>>[];
  final body = BytesBuilder();
  for (final entry in files.entries) {
    final nameBytes = utf8.encode(entry.key);
    final content = utf8.encode(entry.value);
    final crc = _crc32(content);
    final localOffset = body.length;
    final local = BytesBuilder(copy: false);
    local.addByte(0x50);
    local.addByte(0x4B);
    local.addByte(0x03);
    local.addByte(0x04);
    _u16(local, 20);
    _u16(local, 0);
    _u16(local, 0);
    _u16(local, 0);
    _u16(local, 0);
    _u32(local, crc);
    _u32(local, content.length);
    _u32(local, content.length);
    _u16(local, nameBytes.length);
    _u16(local, 0);
    local.add(nameBytes);
    local.add(content);
    body.add(local.takeBytes());
    entries.add({
      'name': nameBytes,
      'offset': localOffset,
      'crc': crc,
      'size': content.length,
    });
  }
  final cdOffset = body.length;
  for (final entry in entries) {
    final name = entry['name'] as List<int>;
    final cd = BytesBuilder(copy: false);
    cd.addByte(0x50);
    cd.addByte(0x4B);
    cd.addByte(0x01);
    cd.addByte(0x02);
    _u16(cd, 0x031E);
    _u16(cd, 20);
    _u16(cd, 0);
    _u16(cd, 0);
    _u16(cd, 0);
    _u16(cd, 0);
    _u32(cd, entry['crc'] as int);
    _u32(cd, entry['size'] as int);
    _u32(cd, entry['size'] as int);
    _u16(cd, name.length);
    _u16(cd, 0);
    _u16(cd, 0);
    _u16(cd, 0);
    _u16(cd, 0);
    _u32(cd, 0);
    _u32(cd, entry['offset'] as int);
    cd.add(name);
    body.add(cd.takeBytes());
  }
  final cdSize = body.length - cdOffset;
  final eocd = BytesBuilder(copy: false);
  eocd.addByte(0x50);
  eocd.addByte(0x4B);
  eocd.addByte(0x05);
  eocd.addByte(0x06);
  _u16(eocd, 0);
  _u16(eocd, 0);
  _u16(eocd, entries.length);
  _u16(eocd, entries.length);
  _u32(eocd, cdSize);
  _u32(eocd, cdOffset);
  _u16(eocd, 0);
  body.add(eocd.takeBytes());
  return body.takeBytes();
}

void _u16(BytesBuilder b, int value) {
  b.addByte(value & 0xFF);
  b.addByte((value >> 8) & 0xFF);
}

void _u32(BytesBuilder b, int value) {
  b.addByte(value & 0xFF);
  b.addByte((value >> 8) & 0xFF);
  b.addByte((value >> 16) & 0xFF);
  b.addByte((value >> 24) & 0xFF);
}

int _crc32(List<int> bytes) {
  var crc = 0xFFFFFFFF;
  for (final byte in bytes) {
    crc ^= byte;
    for (var i = 0; i < 8; i++) {
      crc = (crc >> 1) ^ (0xEDB88320 & (-(crc & 1)));
    }
  }
  return crc ^ 0xFFFFFFFF;
}

void main() {
  final sections = [
    MockExportSection(filename: 'profiles.json', exportData: {'profiles': []}),
    MockExportSection(filename: 'shots.json', exportData: {'shots': []}),
  ];

  Handler buildSyncHandler(
    http.Client client, {
    List<DataExportSection>? registeredSections,
    DataTransferLimits? limits,
  }) {
    final exportHandler = DataExportHandler(
      sections: registeredSections ?? sections,
      limits: limits ?? const DataTransferLimits(),
    );
    final syncHandler = DataSyncHandler(
      exportHandler: exportHandler,
      httpClient: client,
    );
    final app = Router().plus;
    syncHandler.addRoutes(app);
    return app.call;
  }

  Future<Response> sendSync(Handler handler, Map<String, dynamic> body) async =>
      await handler(
        Request(
          'POST',
          Uri.parse('http://localhost/api/v1/data/sync'),
          body: jsonEncode(body),
          headers: {'content-type': 'application/json'},
        ),
      );

  Map<String, dynamic> requestBody({
    required String mode,
    String? target,
    List<String>? selectedSections,
    bool? continueOnPullFailure,
    String? onConflict,
  }) => {
    'target': target ?? 'http://192.168.1.50:8080',
    'mode': mode,
    ...?selectedSections == null ? null : {'sections': selectedSections},
    ...?continueOnPullFailure == null
        ? null
        : {'continueOnPullFailure': continueOnPullFailure},
    ...?onConflict == null ? null : {'onConflict': onConflict},
  };

  group('DataSyncHandler', () {
    group('validation', () {
      test('uses all registered sections when sections are omitted for pull '
          'and push', () async {
        final targetZip = buildZip({'profiles.json': [], 'shots.json': []});
        final client = http_testing.MockClient((request) async {
          if (request.method == 'GET') {
            return http.Response.bytes(targetZip, 200);
          }
          return http.Response(
            '{"profiles":{"imported":1},"shots":{"imported":1}}',
            200,
          );
        });
        final handler = buildSyncHandler(client);

        for (final mode in ['pull', 'push']) {
          final response = await sendSync(handler, requestBody(mode: mode));
          final body = jsonDecode(await response.readAsString());
          expect(response.statusCode, 200);
          expect(body['complete'], isTrue);
          if (mode == 'pull') {
            expect(body['pull']['profiles']['imported'], 1);
          } else {
            expect(body['push']['profiles']['imported'], 1);
          }
        }
      });

      test('pull succeeds when the target takes longer than a connect '
          'timeout to generate its export', () async {
        final targetZip = buildZip({'profiles.json': [], 'shots.json': []});
        final client = http_testing.MockClient((request) async {
          await Future<void>.delayed(const Duration(milliseconds: 100));
          return http.Response.bytes(targetZip, 200);
        });
        final handler = buildSyncHandler(
          client,
          limits: const DataTransferLimits(
            syncHeaderTimeout: Duration(milliseconds: 1),
          ),
        );
        final response = await sendSync(handler, requestBody(mode: 'pull'));
        final body = jsonDecode(await response.readAsString());
        expect(response.statusCode, 200);
        expect(body['complete'], isTrue);
      });

      test('push succeeds when the target takes longer than a connect '
          'timeout to import the archive', () async {
        final client = http_testing.MockClient((request) async {
          await Future<void>.delayed(const Duration(milliseconds: 100));
          return http.Response(
            '{"profiles":{"imported":1},"shots":{"imported":1}}',
            200,
          );
        });
        final handler = buildSyncHandler(
          client,
          limits: const DataTransferLimits(
            syncHeaderTimeout: Duration(milliseconds: 1),
          ),
        );
        final response = await sendSync(handler, requestBody(mode: 'push'));
        final body = jsonDecode(await response.readAsString());
        expect(response.statusCode, 200);
        expect(body['complete'], isTrue);
      });

      test(
        'pull overall timeout aborts the download and never imports',
        () async {
          final client = http_testing.MockClient((request) async {
            await Future<void>.delayed(const Duration(milliseconds: 300));
            return http.Response.bytes(
              buildZip({'profiles.json': [], 'shots.json': []}),
              200,
            );
          });
          final freshShots = MockExportSection(filename: 'shots.json');
          final handler = buildSyncHandler(
            client,
            registeredSections: [
              MockExportSection(filename: 'profiles.json'),
              freshShots,
            ],
            limits: const DataTransferLimits(
              syncOverallTimeout: Duration(milliseconds: 50),
            ),
          );
          final response = await sendSync(handler, requestBody(mode: 'pull'));
          final body = jsonDecode(await response.readAsString());
          expect(response.statusCode, 502);
          expect(body['complete'], isFalse);
          expect(body['pull']['reason'], 'timeout');
          expect(freshShots.calls, 0);
        },
      );

      test(
        'push timeout after the upload completed reports an unknown outcome',
        () async {
          final stopwatch = Stopwatch()..start();
          final client = http_testing.MockClient((request) async {
            await Future<void>.delayed(const Duration(milliseconds: 300));
            return http.Response(
              '{"profiles":{"imported":1},"shots":{"imported":1}}',
              200,
            );
          });
          final handler = buildSyncHandler(
            client,
            limits: const DataTransferLimits(
              syncOverallTimeout: Duration(milliseconds: 50),
            ),
          );
          final response = await sendSync(handler, requestBody(mode: 'push'));
          final body = jsonDecode(await response.readAsString());
          expect(response.statusCode, 502);
          expect(body['complete'], isFalse);
          expect(body['push']['reason'], 'timeout_unknown');
          stopwatch.stop();
          expect(
            stopwatch.elapsed,
            lessThan(const Duration(milliseconds: 250)),
          );
        },
      );

      test(
        'pull lets the local import finish past the phase deadline',
        () async {
          final targetZip = buildZip({'profiles.json': [], 'shots.json': []});
          final client = http_testing.MockClient((request) async {
            await Future<void>.delayed(const Duration(milliseconds: 40));
            return http.Response.bytes(targetZip, 200);
          });
          final slowShots = SlowImportSection(
            filename: 'shots.json',
            delay: const Duration(milliseconds: 200),
          );
          final handler = buildSyncHandler(
            client,
            registeredSections: [
              MockExportSection(filename: 'profiles.json'),
              slowShots,
            ],
            limits: const DataTransferLimits(
              syncOverallTimeout: Duration(milliseconds: 100),
            ),
          );
          final response = await sendSync(handler, requestBody(mode: 'pull'));
          final body = jsonDecode(await response.readAsString());
          expect(response.statusCode, 200);
          expect(body['complete'], isTrue);
          expect(slowShots.calls, 1);
        },
      );

      test('pull timeout aborts the connection while the target is '
          'generating its export', () async {
        final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
        final socketClosed = Completer<void>();
        server.listen((socket) {
          socket.listen(
            null,
            onDone: () => socketClosed.complete(),
            onError: (Object _) {
              if (!socketClosed.isCompleted) socketClosed.complete();
            },
          );
        });
        final client = IOClient(
          HttpClient()..connectionTimeout = const Duration(seconds: 1),
        );
        final handler = buildSyncHandler(
          client,
          limits: const DataTransferLimits(
            syncOverallTimeout: Duration(milliseconds: 300),
          ),
        );
        try {
          final response = await sendSync(
            handler,
            requestBody(
              mode: 'pull',
              target: 'http://127.0.0.1:${server.port}',
            ),
          );
          final body = jsonDecode(await response.readAsString());
          expect(response.statusCode, 502);
          expect(body['pull']['reason'], 'timeout');
          await socketClosed.future.timeout(const Duration(seconds: 2));
        } finally {
          await server.close();
          client.close();
        }
      });

      test(
        'push timeout closes the body stream before temporary cleanup',
        () async {
          final server = await ServerSocket.bind(
            InternetAddress.loopbackIPv4,
            0,
          );
          final random = Random(7);
          const chars =
              'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
          final bigData = String.fromCharCodes(
            List.generate(
              6 * 1024 * 1024,
              (_) => chars.codeUnitAt(random.nextInt(chars.length)),
            ),
          );
          final client = IOClient(
            HttpClient()..connectionTimeout = const Duration(seconds: 1),
          );
          final handler = buildSyncHandler(
            client,
            registeredSections: [
              MockExportSection(filename: 'profiles.json', exportData: bigData),
            ],
            limits: const DataTransferLimits(
              syncOverallTimeout: Duration(milliseconds: 300),
            ),
          );
          final tempDirsBefore = await Directory.systemTemp
              .list()
              .where(
                (entry) =>
                    entry is Directory &&
                    entry.path
                        .split(Platform.pathSeparator)
                        .last
                        .startsWith('reaprime-sync-push-'),
              )
              .map((entry) => entry.path)
              .toSet();
          try {
            final response = await sendSync(
              handler,
              requestBody(
                mode: 'push',
                target: 'http://127.0.0.1:${server.port}',
              ),
            );
            final body = jsonDecode(await response.readAsString());
            expect(response.statusCode, 502);
            expect(body['push']['reason'], 'timeout');
            final tempDirsAfter = await Directory.systemTemp
                .list()
                .where(
                  (entry) =>
                      entry is Directory &&
                      entry.path
                          .split(Platform.pathSeparator)
                          .last
                          .startsWith('reaprime-sync-push-'),
                )
                .map((entry) => entry.path)
                .toSet();
            expect(tempDirsAfter.difference(tempDirsBefore), isEmpty);
          } finally {
            await server.close();
            client.close();
          }
        },
      );

      test('rejects empty and unknown section lists', () async {
        final handler = buildSyncHandler(
          http_testing.MockClient((_) async {
            return http.Response('{}', 500);
          }),
        );
        final badSectionBodies = [
          jsonEncode({'target': 'http://x', 'mode': 'pull', 'sections': []}),
          jsonEncode({
            'target': 'http://x',
            'mode': 'pull',
            'sections': ['unknown'],
          }),
          jsonEncode({
            'target': 'http://x',
            'mode': 'pull',
            'sections': 'profiles',
          }),
          jsonEncode({'target': 'http://x', 'mode': 'pull', 'sections': 42}),
        ];
        for (final body in badSectionBodies) {
          final response = await handler(
            Request(
              'POST',
              Uri.parse('http://localhost/api/v1/data/sync'),
              body: body,
              headers: {'content-type': 'application/json'},
            ),
          );
          expect(response.statusCode, 400, reason: body);
        }
      });

      test('rejects invalid bodies and modes', () async {
        final handler = buildSyncHandler(
          http_testing.MockClient((_) async {
            return http.Response('{}', 500);
          }),
        );
        final badRequests = [
          'not json',
          jsonEncode({'target': 'not-a-url', 'mode': 'pull'}),
          jsonEncode({'target': 'http://x', 'mode': 'bogus'}),
          jsonEncode({
            'target': 'http://x',
            'mode': 'pull',
            'continueOnPullFailure': true,
          }),
        ];
        for (final body in badRequests) {
          final response = await handler(
            Request(
              'POST',
              Uri.parse('http://localhost/api/v1/data/sync'),
              body: body,
              headers: {'content-type': 'application/json'},
            ),
          );
          expect(response.statusCode, 400, reason: body);
        }
      });

      test(
        'accepts targets with or without a trailing slash and IPv6 hosts',
        () async {
          final targetZip = buildZip({'profiles.json': [], 'shots.json': []});
          final seen = <String>[];
          final client = http_testing.MockClient((request) async {
            seen.add('${request.method} ${request.url}');
            if (request.method == 'GET') {
              return http.Response.bytes(targetZip, 200);
            }
            return http.Response(
              '{"profiles":{"imported":1},"shots":{"imported":1}}',
              200,
            );
          });
          final handler = buildSyncHandler(client);

          for (final target in [
            'http://192.168.1.50:8080',
            'http://192.168.1.50:8080/',
            'http://[::1]:8080',
          ]) {
            final response = await sendSync(
              handler,
              requestBody(mode: 'pull', target: target),
            );
            expect(response.statusCode, 200, reason: target);
          }
          // Slash and slash-less targets must hit the identical URL.
          expect(seen.toSet(), {
            'GET http://192.168.1.50:8080/api/v1/data/export',
            'GET http://[::1]:8080/api/v1/data/export',
          });
        },
      );

      test('push appends the import path and conflict query once', () async {
        final seen = <String>[];
        final client = http_testing.MockClient((request) async {
          seen.add('${request.method} ${request.url}');
          return http.Response(
            '{"profiles":{"imported":1},"shots":{"imported":1}}',
            200,
          );
        });
        final handler = buildSyncHandler(client);

        for (final target in [
          'http://127.0.0.1:8080',
          'http://127.0.0.1:8080/',
        ]) {
          final response = await sendSync(
            handler,
            requestBody(mode: 'push', target: target),
          );
          expect(response.statusCode, 200, reason: target);
        }
        expect(seen.toSet(), {
          'POST http://127.0.0.1:8080/api/v1/data/import?onConflict=skip',
        });
      });

      test('rejects targets with paths, queries, fragments, credentials, '
          'or missing hosts', () async {
        final handler = buildSyncHandler(
          http_testing.MockClient((_) async => http.Response('{}', 500)),
        );
        final badTargets = [
          'http://192.168.1.50:8080/some/path',
          'http://192.168.1.50:8080?foo=bar',
          'http://192.168.1.50:8080/#frag',
          'http://user:pass@192.168.1.50:8080',
          'http://',
          'ftp://192.168.1.50:8080',
        ];
        for (final target in badTargets) {
          final response = await sendSync(
            handler,
            requestBody(mode: 'pull', target: target),
          );
          expect(response.statusCode, 400, reason: target);
        }
      });

      test('rejects oversized sync request bodies', () async {
        final bigBody = jsonEncode({
          'target': 'http://x',
          'mode': 'pull',
          'padding': 'x' * 2048,
        });
        final smallExport = DataExportHandler(
          sections: sections,
          limits: const DataTransferLimits(maxSyncRequestBytes: 256),
        );
        final sync = DataSyncHandler(
          exportHandler: smallExport,
          httpClient: http_testing.MockClient((_) async {
            return http.Response('{}', 500);
          }),
        );
        final app = Router().plus;
        sync.addRoutes(app);
        final response = await app.call(
          Request(
            'POST',
            Uri.parse('http://localhost/api/v1/data/sync'),
            body: bigBody,
            headers: {'content-type': 'application/json'},
          ),
        );
        expect(response.statusCode, 413);
      });

      test('returns 408 and cancels a stalled sync request body', () async {
        final handler = buildSyncHandler(
          http_testing.MockClient((_) async => http.Response('{}', 500)),
          limits: const DataTransferLimits(
            syncIdleTimeout: Duration(milliseconds: 10),
          ),
        );
        final cancelled = Completer<void>();
        final body = StreamController<List<int>>(onCancel: cancelled.complete);
        addTearDown(body.close);

        final response = await Future<Response>.sync(
          () => handler(
            Request(
              'POST',
              Uri.parse('http://localhost/api/v1/data/sync'),
              body: body.stream,
              headers: {'content-type': 'application/json'},
            ),
          ),
        ).timeout(const Duration(seconds: 1));

        expect(response.statusCode, 408);
        await cancelled.future.timeout(const Duration(seconds: 1));
        expect(body.hasListener, isFalse);
      });
    });

    group('pull', () {
      test('streams a remote archive and imports it', () async {
        final targetZip = buildZip({
          'metadata.json': {'formatVersion': 1},
          'profiles.json': [
            {'id': 'p1'},
          ],
          'shots.json': [
            {'id': 's1'},
          ],
        });
        var pulled = false;
        final client = http_testing.MockClient((request) async {
          if (request.method == 'GET') {
            pulled = true;
            expect(request.url.path, '/api/v1/data/export');
            return http.Response.bytes(targetZip, 200);
          }
          return http.Response('{}', 500);
        });
        final handler = buildSyncHandler(client);
        final response = await sendSync(handler, requestBody(mode: 'pull'));

        expect(pulled, isTrue);
        expect(response.statusCode, 200);
        final body = jsonDecode(await response.readAsString());
        expect(body['status'], 'complete');
        expect(body['pull']['profiles']['imported'], 1);
      });

      test('classifies a non-200 pull as a target error', () async {
        final client = http_testing.MockClient((request) async {
          return http.Response('nope', 503);
        });
        final handler = buildSyncHandler(client);
        final response = await sendSync(handler, requestBody(mode: 'pull'));
        expect(response.statusCode, 502);
        final body = jsonDecode(await response.readAsString());
        expect(body['pull']['reason'], 'target_error');
      });

      test('classifies a malformed pull archive as invalid backup', () async {
        final client = http_testing.MockClient((request) async {
          return http.Response.bytes([1, 2, 3, 4, 5, 6], 200);
        });
        final handler = buildSyncHandler(client);
        final response = await sendSync(handler, requestBody(mode: 'pull'));
        expect(response.statusCode, 502);
        final body = jsonDecode(await response.readAsString());
        expect(body['pull']['reason'], contains('invalid'));
      });

      test('preserves a partial pull result', () async {
        final targetZip = buildZip({
          'metadata.json': {'formatVersion': 1},
          'profiles.json': [
            {'id': 'p1'},
          ],
          'shots.json': [
            {'id': 's1'},
          ],
        });
        final client = http_testing.MockClient((request) async {
          return http.Response.bytes(targetZip, 200);
        });
        final failingShots = MockExportSection(
          filename: 'shots.json',
          importResult: const SectionImportResult(
            imported: 1,
            errors: ['bad record'],
          ),
        );
        final handler = buildSyncHandler(
          client,
          registeredSections: [
            MockExportSection(filename: 'profiles.json'),
            failingShots,
          ],
        );
        final response = await sendSync(handler, requestBody(mode: 'pull'));
        expect(response.statusCode, 502);
        final body = jsonDecode(await response.readAsString());
        expect(body['phases']['pull']['status'], 'partial');
      });
    });

    group('push', () {
      test('streams the local export to the target', () async {
        var pushedBody = <int>[];
        final client = http_testing.MockClient((request) async {
          expect(request.method, 'POST');
          expect(request.url.path, '/api/v1/data/import');
          expect(request.url.queryParameters['onConflict'], 'skip');
          pushedBody = request.bodyBytes;
          return http.Response(
            '{"profiles":{"imported":1},"shots":{"imported":1}}',
            200,
          );
        });
        final handler = buildSyncHandler(client);
        final response = await sendSync(handler, requestBody(mode: 'push'));
        expect(response.statusCode, 200);
        expect(pushedBody, isNotEmpty);
        final body = jsonDecode(await response.readAsString());
        expect(body['push']['profiles']['imported'], 1);
      });

      test('local export failure prevents the remote request', () async {
        var remoteCalled = false;
        final client = http_testing.MockClient((request) async {
          remoteCalled = true;
          return http.Response('{}', 500);
        });
        final failing = MockExportSection(
          filename: 'profiles.json',
          failExport: true,
        );
        final handler = buildSyncHandler(client, registeredSections: [failing]);
        final response = await sendSync(handler, requestBody(mode: 'push'));
        expect(response.statusCode, 502);
        expect(remoteCalled, isFalse);
        final body = jsonDecode(await response.readAsString());
        expect(body['push']['reason'], 'local_export_failed');
      });

      test('classifies remote 207 as a partial push', () async {
        final client = http_testing.MockClient((request) async {
          return http.Response(
            '{"profiles":{"imported":1,"errors":["x"]}}',
            207,
          );
        });
        final handler = buildSyncHandler(client);
        final response = await sendSync(handler, requestBody(mode: 'push'));
        expect(response.statusCode, 502);
        final body = jsonDecode(await response.readAsString());
        expect(body['phases']['push']['status'], 'partial');
      });

      test('classifies invalid remote JSON as invalid_json', () async {
        final client = http_testing.MockClient((request) async {
          return http.Response('not json at all', 200);
        });
        final handler = buildSyncHandler(client);
        final response = await sendSync(handler, requestBody(mode: 'push'));
        final body = jsonDecode(await response.readAsString());
        expect(body['push']['reason'], 'invalid_json');
      });

      test('rejects an oversized remote response body', () async {
        final smallExport = DataExportHandler(
          sections: sections,
          limits: const DataTransferLimits(maxSyncResponseBytes: 64),
        );
        final client = http_testing.MockClient((request) async {
          return http.Response(
            '{"profiles":{"imported":1},"padding":"${'x' * 256}"}',
            200,
          );
        });
        final sync = DataSyncHandler(
          exportHandler: smallExport,
          httpClient: client,
        );
        final app = Router().plus;
        sync.addRoutes(app);
        final response = await app.call(
          Request(
            'POST',
            Uri.parse('http://localhost/api/v1/data/sync'),
            body: jsonEncode(requestBody(mode: 'push')),
            headers: {'content-type': 'application/json'},
          ),
        );
        expect(response.statusCode, 502);
        final body = jsonDecode(await response.readAsString());
        expect(body['push']['reason'], 'target_error');
      });
    });

    group('two_way', () {
      test('runs push after a complete pull', () async {
        final targetZip = buildZip({
          'metadata.json': {'formatVersion': 1},
          'profiles.json': [
            {'id': 'p1'},
          ],
          'shots.json': [
            {'id': 's1'},
          ],
        });
        final client = http_testing.MockClient((request) async {
          if (request.method == 'GET') {
            return http.Response.bytes(targetZip, 200);
          }
          return http.Response(
            '{"profiles":{"imported":1},"shots":{"imported":1}}',
            200,
          );
        });
        final handler = buildSyncHandler(client);
        final response = await sendSync(handler, requestBody(mode: 'two_way'));
        expect(response.statusCode, 200);
        final body = jsonDecode(await response.readAsString());
        expect(body['pull']['status'] ?? body['pull']['profiles'], isNotNull);
        expect(body['push']['profiles']['imported'], 1);
        expect(body['phases']['push']['status'], 'complete');
      });

      test('skips push after a fatal pull by default', () async {
        final client = http_testing.MockClient((request) async {
          return http.Response('server error', 500);
        });
        final handler = buildSyncHandler(client);
        final response = await sendSync(handler, requestBody(mode: 'two_way'));
        expect(response.statusCode, 502);
        final body = jsonDecode(await response.readAsString());
        expect(body['phases']['push']['status'], 'skipped');
        expect(body['phases']['push']['reason'], 'pull_not_complete');
      });

      test('allows explicit continuation after a failed pull', () async {
        var pushCalled = false;
        final client = http_testing.MockClient((request) async {
          if (request.method == 'GET') {
            return http.Response('error', 500);
          }
          pushCalled = true;
          return http.Response(
            '{"profiles":{"imported":1},"shots":{"imported":1}}',
            200,
          );
        });
        final handler = buildSyncHandler(client);
        final response = await sendSync(
          handler,
          requestBody(mode: 'two_way', continueOnPullFailure: true),
        );
        expect(pushCalled, isTrue);
        expect(response.statusCode, 207);
        final body = jsonDecode(await response.readAsString());
        expect(body['phases']['pull']['status'], 'failed');
        expect(body['phases']['push']['status'], 'complete');
      });

      test('returns 207 when pull completes and push is partial', () async {
        final targetZip = buildZip({
          'metadata.json': {'formatVersion': 1},
          'profiles.json': [],
          'shots.json': [],
        });
        final client = http_testing.MockClient((request) async {
          if (request.method == 'GET') {
            return http.Response.bytes(targetZip, 200);
          }
          return http.Response(
            '{"profiles":{"imported":0,"errors":["boom"]}}',
            207,
          );
        });
        final handler = buildSyncHandler(client);
        final response = await sendSync(handler, requestBody(mode: 'two_way'));
        expect(response.statusCode, 207);
        final body = jsonDecode(await response.readAsString());
        expect(body['status'], 'partial');
      });
    });
  });
}
