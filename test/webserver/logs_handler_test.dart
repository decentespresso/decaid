import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/services/webserver_service.dart';
import 'package:reaprime/src/services/webview_log_service.dart';
import 'package:shelf_plus/shelf_plus.dart';

/// Stub that returns fixed contents, bypassing the IOSink-buffered file the
/// real [WebViewLogService] writes to (which would race a synchronous read).
class _StubWebViewLogService extends WebViewLogService {
  final String _contents;
  _StubWebViewLogService(this._contents) : super(logDirectoryPath: '/unused');

  @override
  String getContents() => _contents;
}

void main() {
  Future<Response> get(Handler handler, String path) async {
    return await handler(Request('GET', Uri.parse('http://localhost$path')));
  }

  group('LogsHandler GET /api/v1/logs', () {
    late Directory tmpDir;
    late File logFile;

    setUp(() {
      tmpDir = Directory.systemTemp.createTempSync('logs_handler_test');
      logFile = File('${tmpDir.path}/log.txt');
    });

    tearDown(() {
      if (tmpDir.existsSync()) tmpDir.deleteSync(recursive: true);
    });

    Handler handlerFor(String path, {int? defaultTailKb, int? maxTailKb}) {
      final app = Router().plus;
      LogsHandler(
        logFilePath: path,
        defaultTailKb: defaultTailKb ?? LogsHandler.defaultTailKb,
        maxTailKb: maxTailKb ?? LogsHandler.maxTailKb,
      ).addRoutes(app);
      return app.call;
    }

    test('returns the file with lines newest-first', () async {
      const lines = ['oldest', 'middle', 'newest'];
      logFile.writeAsStringSync('${lines.join('\n')}\n');

      final res = await get(handlerFor(logFile.path), '/api/v1/logs');

      expect(res.statusCode, 200);
      expect(res.headers['content-type'], 'text/plain');
      expect(await res.readAsString(), 'newest\nmiddle\noldest\n');
    });

    test(
      'does not produce a leading blank line from a trailing newline',
      () async {
        logFile.writeAsStringSync('a\nb\nc\n');
        final res = await get(handlerFor(logFile.path), '/api/v1/logs');
        final body = await res.readAsString();
        expect(body, 'c\nb\na\n');
        expect(body.startsWith('\n'), isFalse);
      },
    );

    test('empty file yields an empty body (not a blank line)', () async {
      logFile.writeAsStringSync('');
      final res = await get(handlerFor(logFile.path), '/api/v1/logs');
      expect(res.statusCode, 200);
      expect(await res.readAsString(), '');
    });

    test('empty file yields an empty body for order=asc too', () async {
      logFile.writeAsStringSync('');
      final res = await get(handlerFor(logFile.path), '/api/v1/logs?order=asc');
      expect(res.statusCode, 200);
      expect(await res.readAsString(), '');
    });

    test('missing file returns 404', () async {
      final res = await get(
        handlerFor('${tmpDir.path}/nope.txt'),
        '/api/v1/logs',
      );
      expect(res.statusCode, 404);
    });

    test('?kb=N returns the most recent window, newest-first', () async {
      final lines = [
        for (var i = 0; i < 200; i++) 'line${i.toString().padLeft(4, '0')}',
      ];
      logFile.writeAsStringSync('${lines.join('\n')}\n');

      final res = await get(handlerFor(logFile.path), '/api/v1/logs?kb=1');
      final body = await res.readAsString();

      expect(res.statusCode, 200);
      expect(body.startsWith('line0199'), isTrue);
      expect(body.contains('line0000'), isFalse);
      expect(body.contains('line0150'), isTrue);
      expect(body.indexOf('line0199'), lessThan(body.indexOf('line0150')));
    });

    test('?kb=0 is rejected', () async {
      logFile.writeAsStringSync('x\n');
      final res = await get(handlerFor(logFile.path), '/api/v1/logs?kb=0');
      expect(res.statusCode, 400);
    });

    test('?order=asc returns the original chronological order', () async {
      logFile.writeAsStringSync('oldest\nmiddle\nnewest\n');
      final res = await get(handlerFor(logFile.path), '/api/v1/logs?order=asc');
      expect(res.statusCode, 200);
      expect(await res.readAsString(), 'oldest\nmiddle\nnewest\n');
    });

    test('?order=desc is the explicit default (newest-first)', () async {
      logFile.writeAsStringSync('oldest\nmiddle\nnewest\n');
      final res = await get(
        handlerFor(logFile.path),
        '/api/v1/logs?order=desc',
      );
      expect(res.statusCode, 200);
      expect(await res.readAsString(), 'newest\nmiddle\noldest\n');
    });

    test('?order is case-insensitive', () async {
      logFile.writeAsStringSync('oldest\nnewest\n');
      final res = await get(handlerFor(logFile.path), '/api/v1/logs?order=ASC');
      expect(res.statusCode, 200);
      expect(await res.readAsString(), 'oldest\nnewest\n');
    });

    test('an unrecognized ?order value is rejected', () async {
      logFile.writeAsStringSync('x\n');
      final res = await get(
        handlerFor(logFile.path),
        '/api/v1/logs?order=sideways',
      );
      expect(res.statusCode, 400);
    });

    test('?kb=N&order=asc returns the window in chronological order', () async {
      final lines = [
        for (var i = 0; i < 200; i++) 'line${i.toString().padLeft(4, '0')}',
      ];
      logFile.writeAsStringSync('${lines.join('\n')}\n');

      final res = await get(
        handlerFor(logFile.path),
        '/api/v1/logs?kb=1&order=asc',
      );
      final body = await res.readAsString();

      expect(res.statusCode, 200);
      expect(body.endsWith('line0199\n'), isTrue);
      expect(body.contains('line0000'), isFalse);
      expect(body.contains('line0150'), isTrue);
      expect(body.indexOf('line0150'), lessThan(body.indexOf('line0199')));
    });

    group('rotation stitching', () {
      void writeRotationSet() {
        File('${logFile.path}.2').writeAsStringSync('r2a\nr2b\n');
        File('${logFile.path}.1').writeAsStringSync('r1a\nr1b\n');
        logFile.writeAsStringSync('base_a\nbase_b\n');
      }

      test(
        'rotated files are always included, newest-first by default',
        () async {
          writeRotationSet();
          final res = await get(handlerFor(logFile.path), '/api/v1/logs');
          expect(res.statusCode, 200);
          expect(
            await res.readAsString(),
            'base_b\nbase_a\nr1b\nr1a\nr2b\nr2a\n',
          );
        },
      );

      test('order=asc stitches all files oldest rotation first', () async {
        writeRotationSet();
        final res = await get(
          handlerFor(logFile.path),
          '/api/v1/logs?order=asc',
        );
        expect(res.statusCode, 200);
        expect(
          await res.readAsString(),
          'r2a\nr2b\nr1a\nr1b\nbase_a\nbase_b\n',
        );
      });

      test('no rotated files present serves just the live file', () async {
        logFile.writeAsStringSync('only_a\nonly_b\n');
        final res = await get(
          handlerFor(logFile.path),
          '/api/v1/logs?order=asc',
        );
        expect(await res.readAsString(), 'only_a\nonly_b\n');
      });

      test('stops probing at the first missing rotation', () async {
        // .1 and .3 exist but .2 does not — .3 must not be picked up.
        File('${logFile.path}.3').writeAsStringSync('r3\n');
        File('${logFile.path}.1').writeAsStringSync('r1\n');
        logFile.writeAsStringSync('base\n');
        final res = await get(
          handlerFor(logFile.path),
          '/api/v1/logs?order=asc',
        );
        expect(await res.readAsString(), 'r1\nbase\n');
      });

      test('?kb=N windows the tail across file boundaries', () async {
        String block(String prefix) => [
          for (var i = 0; i < 111; i++)
            '$prefix${i.toString().padLeft(4, '0')}',
        ].join('\n');
        File('${logFile.path}.1').writeAsStringSync('${block("old")}\n');
        logFile.writeAsStringSync('${block("new")}\n');

        final res = await get(
          handlerFor(logFile.path),
          '/api/v1/logs?kb=1&order=asc',
        );
        final body = await res.readAsString();

        expect(res.statusCode, 200);
        expect(body.endsWith('new0110\n'), isTrue);
        expect(body.contains('old0000'), isFalse);
        expect(body.contains('old0110'), isTrue);
        expect(body.indexOf('old0110'), lessThan(body.indexOf('new0000')));
      });

      test('the legacy ?rotated param is ignored, not rejected', () async {
        writeRotationSet();
        final res = await get(
          handlerFor(logFile.path),
          '/api/v1/logs?rotated=0&order=asc',
        );
        expect(res.statusCode, 200);
        expect(
          await res.readAsString(),
          'r2a\nr2b\nr1a\nr1b\nbase_a\nbase_b\n',
        );
      });
    });

    group('tail window caps', () {
      test('without ?kb the default cap bounds the response', () async {
        final lines = [
          for (var i = 0; i < 228; i++) 'line${i.toString().padLeft(4, '0')}',
        ];
        logFile.writeAsStringSync('${lines.join('\n')}\n');

        final res = await get(
          handlerFor(logFile.path, defaultTailKb: 1),
          '/api/v1/logs?order=asc',
        );
        final body = await res.readAsString();

        expect(res.statusCode, 200);
        expect(body.endsWith('line0227\n'), isTrue);
        expect(body.contains('line0000'), isFalse);
        expect(body.length, lessThanOrEqualTo(1024));
      });

      test('the default cap spans rotated files but stays bounded', () async {
        String block(String prefix) => [
          for (var i = 0; i < 111; i++)
            '$prefix${i.toString().padLeft(4, '0')}',
        ].join('\n');
        File('${logFile.path}.1').writeAsStringSync('${block("old")}\n');
        logFile.writeAsStringSync('${block("new")}\n');

        final res = await get(
          handlerFor(logFile.path, defaultTailKb: 1),
          '/api/v1/logs?order=asc',
        );
        final body = await res.readAsString();

        expect(res.statusCode, 200);
        expect(body.endsWith('new0110\n'), isTrue);
        expect(body.contains('old0000'), isFalse);
        expect(body.contains('old0110'), isTrue);
      });

      test('an explicit ?kb above the ceiling is clamped', () async {
        // 2KB of content, 1KB ceiling: kb=100 must still return only 1KB.
        final lines = [
          for (var i = 0; i < 228; i++) 'line${i.toString().padLeft(4, '0')}',
        ];
        logFile.writeAsStringSync('${lines.join('\n')}\n');

        final res = await get(
          handlerFor(logFile.path, maxTailKb: 1),
          '/api/v1/logs?kb=100&order=asc',
        );
        final body = await res.readAsString();

        expect(res.statusCode, 200);
        expect(body.endsWith('line0227\n'), isTrue);
        expect(body.contains('line0000'), isFalse);
        expect(body.length, lessThanOrEqualTo(1024));
      });

      test('the clamp bounds desc responses too', () async {
        final lines = [
          for (var i = 0; i < 228; i++) 'line${i.toString().padLeft(4, '0')}',
        ];
        logFile.writeAsStringSync('${lines.join('\n')}\n');

        final res = await get(
          handlerFor(logFile.path, maxTailKb: 1),
          '/api/v1/logs?kb=100',
        );
        final body = await res.readAsString();

        expect(res.statusCode, 200);
        expect(body.startsWith('line0227'), isTrue);
        expect(body.contains('line0000'), isFalse);
      });
    });
  });

  group('WebViewLogsHandler GET /api/v1/webview/logs', () {
    Handler handlerFor(WebViewLogService service) {
      final app = Router().plus;
      WebViewLogsHandler(webViewLogService: service).addRoutes(app);
      return app.call;
    }

    test('returns console entries newest-first', () async {
      final service = _StubWebViewLogService(
        '[t1] [skin] [INFO] one\n'
        '[t2] [skin] [INFO] two\n'
        '[t3] [skin] [WARN] three\n',
      );

      final res = await get(handlerFor(service), '/api/v1/webview/logs');

      expect(res.statusCode, 200);
      expect(res.headers['content-type'], 'text/plain');
      expect(
        await res.readAsString(),
        '[t3] [skin] [WARN] three\n'
        '[t2] [skin] [INFO] two\n'
        '[t1] [skin] [INFO] one\n',
      );
    });

    test('empty log yields an empty body', () async {
      final res = await get(
        handlerFor(_StubWebViewLogService('')),
        '/api/v1/webview/logs',
      );
      expect(res.statusCode, 200);
      expect(await res.readAsString(), '');
    });

    test('?order=asc returns the original chronological order', () async {
      final service = _StubWebViewLogService(
        '[t1] [skin] [INFO] one\n'
        '[t2] [skin] [INFO] two\n'
        '[t3] [skin] [WARN] three\n',
      );

      final res = await get(
        handlerFor(service),
        '/api/v1/webview/logs?order=asc',
      );

      expect(res.statusCode, 200);
      expect(
        await res.readAsString(),
        '[t1] [skin] [INFO] one\n'
        '[t2] [skin] [INFO] two\n'
        '[t3] [skin] [WARN] three\n',
      );
    });

    test('an unrecognized ?order value is rejected', () async {
      final res = await get(
        handlerFor(_StubWebViewLogService('x\n')),
        '/api/v1/webview/logs?order=sideways',
      );
      expect(res.statusCode, 400);
    });
  });
}
