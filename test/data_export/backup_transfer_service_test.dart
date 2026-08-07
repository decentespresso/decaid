import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/settings/backup_import_response.dart';
import 'package:reaprime/src/services/webserver/data_export/backup_transfer_service.dart';

void main() {
  late HttpServer server;
  late String baseUrl;
  late Directory tempDir;

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    baseUrl = 'http://127.0.0.1:${server.port}';
    tempDir = await Directory.systemTemp.createTemp('transfer-test-');
  });

  tearDown(() async {
    await server.close(force: true);
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  Future<void> serve(Future<void> Function(HttpRequest request) handler) async {
    server.listen((request) async {
      try {
        await handler(request);
      } catch (_) {
        request.response.statusCode = 500;
        await request.response.close();
      }
    });
  }

  test('downloadExportZip streams a valid response to a temp file', () async {
    final payload = Uint8List.fromList(
      List.generate(1024 * 64, (i) => i % 251),
    );
    await serve((request) async {
      expect(request.uri.path, '/api/v1/data/export');
      request.response.headers.contentType = ContentType('application', 'zip');
      request.response.add(payload);
      await request.response.close();
    });

    final service = BackupTransferService();
    try {
      final file = await service.downloadExportZip(
        '$baseUrl/api/v1/data/export',
        tempDir,
      );
      expect(await file.length(), payload.length);
      expect(await file.readAsBytes(), payload);
    } finally {
      service.close();
    }
  });

  test('downloadExportZip rejects a non-200 response before saving', () async {
    await serve((request) async {
      request.response.statusCode = 500;
      request.response.headers.contentType = ContentType('application', 'json');
      request.response.write('{"message": "Export failed"}');
      await request.response.close();
    });

    final service = BackupTransferService();
    try {
      await expectLater(
        service.downloadExportZip('$baseUrl/api/v1/data/export', tempDir),
        throwsA(
          isA<BackupTransferException>().having(
            (e) => e.statusCode,
            'statusCode',
            500,
          ),
        ),
      );
      expect(tempDir.listSync(), isEmpty);
    } finally {
      service.close();
    }
  });

  test('downloadExportZip rejects a wrong MIME type', () async {
    await serve((request) async {
      request.response.headers.contentType = ContentType('text', 'html');
      request.response.write('<html>error page</html>');
      await request.response.close();
    });

    final service = BackupTransferService();
    try {
      await expectLater(
        service.downloadExportZip('$baseUrl/api/v1/data/export', tempDir),
        throwsA(isA<BackupTransferException>()),
      );
    } finally {
      service.close();
    }
  });

  test('uploadZip streams a local file into the request', () async {
    final received = BytesBuilder();
    final uploadFile = File('${tempDir.path}/upload.zip');
    await uploadFile.writeAsBytes(List.generate(4096, (i) => i % 251));
    String? contentType;
    int? contentLength;

    await serve((request) async {
      expect(request.uri.path, '/api/v1/data/import');
      expect(request.uri.queryParameters['onConflict'], 'overwrite');
      contentType = request.headers.contentType?.mimeType;
      contentLength = request.headers.contentLength;
      await for (final chunk in request) {
        received.add(chunk);
      }
      request.response.headers.contentType = ContentType('application', 'json');
      request.response.write('{"profiles":{"imported":1}}');
      await request.response.close();
    });

    final service = BackupTransferService();
    try {
      final result = await service.uploadZip(
        '$baseUrl/api/v1/data/import',
        'overwrite',
        filePath: uploadFile.path,
      );
      expect(result.status.name, 'complete');
      expect(received.takeBytes(), await uploadFile.readAsBytes());
      expect(contentType, 'application/zip');
      expect(contentLength, 4096);
    } finally {
      service.close();
    }
  });

  test('uploadZip streams a readStream when no path is available', () async {
    final stream = Stream<List<int>>.fromIterable([
      Uint8List.fromList([1, 2, 3]),
      Uint8List.fromList([4, 5]),
    ]);
    final received = BytesBuilder();
    await serve((request) async {
      await for (final chunk in request) {
        received.add(chunk);
      }
      request.response.headers.contentType = ContentType('application', 'json');
      request.response.write('{"profiles":{"imported":1}}');
      await request.response.close();
    });

    final service = BackupTransferService();
    try {
      await service.uploadZip(
        '$baseUrl/api/v1/data/import',
        'skip',
        readStream: stream,
      );
      expect(received.takeBytes(), [1, 2, 3, 4, 5]);
    } finally {
      service.close();
    }
  });

  test('uploadZip surfaces a 400 import rejection', () async {
    await serve((request) async {
      request.response.statusCode = 400;
      request.response.headers.contentType = ContentType('application', 'json');
      request.response.write(
        '{"error":"Invalid backup archive","message":"bad zip"}',
      );
      await request.response.close();
    });

    final service = BackupTransferService();
    try {
      await expectLater(
        service.uploadZip(
          '$baseUrl/api/v1/data/import',
          'skip',
          readStream: Stream.value(Uint8List.fromList([1, 2])),
        ),
        throwsA(
          isA<BackupImportException>().having(
            (e) => e.statusCode,
            'statusCode',
            400,
          ),
        ),
      );
    } finally {
      service.close();
    }
  });

  test('rejects an oversized server response', () async {
    await serve((request) async {
      request.response.headers.contentType = ContentType('application', 'json');
      request.response.write('{"padding":"${'x' * 4096}"}');
      await request.response.close();
    });

    final service = BackupTransferService(maxResponseBytes: 1024);
    try {
      await expectLater(
        service.uploadZip(
          '$baseUrl/api/v1/data/import',
          'skip',
          readStream: Stream.value(Uint8List.fromList([1])),
        ),
        throwsA(isA<BackupTransferException>()),
      );
    } finally {
      service.close();
    }
  });
}
