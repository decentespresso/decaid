import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/services/webserver/api_listener.dart';
import 'package:reaprime/src/services/webserver/listener_health.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_web_socket/shelf_web_socket.dart' as sws;

Future<({int statusCode, String? contentType, String? listenerId})> _response(
  Uri uri,
) async {
  final client = HttpClient();
  try {
    final request = await client
        .getUrl(uri)
        .timeout(const Duration(seconds: 1));
    final response = await request.close().timeout(const Duration(seconds: 1));
    await response.drain<void>();
    return (
      statusCode: response.statusCode,
      contentType: response.headers.value(HttpHeaders.contentTypeHeader),
      listenerId: response.headers.value(listenerIdentityHeader),
    );
  } finally {
    client.close(force: true);
  }
}

Future<int> _statusCode(Uri uri) async => (await _response(uri)).statusCode;

Future<bool> _responds(Uri uri) async {
  try {
    await _statusCode(uri);
    return true;
  } catch (_) {
    return false;
  }
}

void main() {
  late ApiListener listener;

  setUp(() {
    listener = ApiListener(
      handler: (request) =>
          Response.ok('{}', headers: {'content-type': 'application/json'}),
      port: 0,
    );
  });

  tearDown(() => listener.stop());

  test(
    'cancelled recovery inside API bind closes unpublished socket',
    () async {
      await listener.start();
      final port = listener.port;
      final starts = listener.startCount;
      await listener.closeForTesting();
      final entered = Completer<void>();
      final release = Completer<void>();
      listener.bindBarrier = () async {
        entered.complete();
        await release.future;
      };
      var cancelled = false;
      final pending = listener.recover(isCancelled: () => cancelled);
      await entered.future.timeout(const Duration(seconds: 1));
      cancelled = true;
      release.complete();
      await pending;
      expect(listener.startCount, starts);
      expect(listener.isStarted, isFalse);
      final socket = await ServerSocket.bind('0.0.0.0', port);
      await socket.close();
    },
  );

  test(
    'rejects a responsive replacement listener on the retained port',
    () async {
      await listener.start();
      final port = listener.port;
      await listener.closeForTesting();
      final replacement = await HttpServer.bind('0.0.0.0', port);
      addTearDown(() => replacement.close(force: true));
      replacement.listen((request) async {
        await request.drain<void>();
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType.json;
        await request.response.close();
      });

      final response = await _response(
        Uri.parse('http://127.0.0.1:$port/api/v1/info'),
      );
      expect(response.statusCode, HttpStatus.ok);
      expect(response.contentType, startsWith('application/json'));
      expect(await listener.checkHealth(), isFalse);
    },
  );

  test('health checks actual listener responsiveness', () async {
    await listener.start();

    expect(listener.isStarted, isTrue);
    final first = await _response(
      Uri.parse('http://127.0.0.1:${listener.port}/api/v1/info'),
    );
    expect(first.statusCode, HttpStatus.ok);
    expect(first.listenerId, isNotNull);
    expect(await listener.checkHealth(), isTrue);
    final second = await _response(
      Uri.parse('http://127.0.0.1:${listener.port}/api/v1/info'),
    );
    expect(second.listenerId, first.listenerId);
    expect(listener.startCount, 1);

    await listener.closeForTesting();

    expect(listener.isStarted, isTrue);
    expect(await listener.checkHealth(), isFalse);
    expect(
      await _responds(
        Uri.parse('http://127.0.0.1:${listener.port}/api/v1/info'),
      ),
      isFalse,
    );
  });

  test('a fresh binding gets a fresh listener identity', () async {
    await listener.start();
    final port = listener.port;
    final first = await _response(
      Uri.parse('http://127.0.0.1:$port/api/v1/info'),
    );
    expect(first.listenerId, isNotNull);
    await listener.closeForTesting();

    await listener.recover();

    final second = await _response(
      Uri.parse('http://127.0.0.1:$port/api/v1/info'),
    );
    expect(second.listenerId, isNotNull);
    expect(second.listenerId, isNot(first.listenerId));
    expect(await listener.checkHealth(), isTrue);
  });

  test('rejects another Decaid listener on the retained port', () async {
    await listener.start();
    final port = listener.port;
    await listener.closeForTesting();
    final other = ApiListener(
      handler: (request) =>
          Response.ok('{}', headers: {'content-type': 'application/json'}),
      port: port,
    );
    addTearDown(other.stop);
    await other.start();

    final response = await _response(
      Uri.parse('http://127.0.0.1:$port/api/v1/info'),
    );
    expect(response.statusCode, HttpStatus.ok);
    expect(response.contentType, startsWith('application/json'));
    expect(response.listenerId, isNotNull);
    expect(await listener.checkHealth(), isFalse);
    expect(await other.checkHealth(), isTrue);
  });

  test('recovery rebinds the configured port after listener loss', () async {
    await listener.start();
    final port = listener.port;
    await listener.closeForTesting();

    await listener.recover();

    expect(listener.port, port);
    expect(await listener.checkHealth(), isTrue);
    expect(
      await _statusCode(Uri.parse('http://127.0.0.1:$port/api/v1/info')),
      HttpStatus.ok,
    );
  });

  test(
    'recovery restores REST and a real WebSocket on the same listener',
    () async {
      var webSocketConnections = 0;
      final webSocketHandler = sws.webSocketHandler((socket, _) {
        webSocketConnections++;
        socket.stream.listen(socket.sink.add);
      });
      final seenHandlers = <Handler>[];
      final webSocketListener = ApiListener(
        handler: (request) {
          seenHandlers.add(webSocketHandler);
          if (request.url.path == 'ws') return webSocketHandler(request);
          return Response.ok(
            '{}',
            headers: {'content-type': 'application/json'},
          );
        },
        port: 0,
      );
      addTearDown(webSocketListener.stop);

      await webSocketListener.start();
      final port = webSocketListener.port;
      final first = await WebSocket.connect('ws://127.0.0.1:$port/ws');
      first.add('before-recovery');
      expect(
        await first.first.timeout(const Duration(seconds: 1)),
        'before-recovery',
      );
      await first.close();

      await webSocketListener.closeForTesting();
      await webSocketListener.recover();

      expect(webSocketListener.port, port);
      expect(await webSocketListener.checkHealth(), isTrue);
      expect(
        await _statusCode(Uri.parse('http://127.0.0.1:$port/api/v1/info')),
        HttpStatus.ok,
      );

      final second = await WebSocket.connect('ws://127.0.0.1:$port/ws');
      second.add('after-recovery');
      expect(
        await second.first.timeout(const Duration(seconds: 1)),
        'after-recovery',
      );
      await second.close();

      expect(webSocketConnections, 2);
      expect(seenHandlers.length, greaterThanOrEqualTo(4));
      expect(
        seenHandlers.every((handler) => identical(handler, webSocketHandler)),
        isTrue,
      );
    },
  );

  test('concurrent recovery has one listener owner', () async {
    await listener.start();
    final starts = listener.startCount;
    await listener.closeForTesting();

    await Future.wait([listener.recover(), listener.recover()]);

    expect(listener.startCount, starts + 1);
    expect(await listener.checkHealth(), isTrue);
    expect(
      await _statusCode(
        Uri.parse('http://127.0.0.1:${listener.port}/api/v1/info'),
      ),
      HttpStatus.ok,
    );
  });

  test(
    'stopping while start is waiting for health leaves no late listener',
    () async {
      final healthStarted = Completer<void>();
      final releaseHealth = Completer<void>();
      var blockHealth = false;
      final gated = ApiListener(
        handler: (request) async {
          if (blockHealth && request.url.path == 'api/v1/info') {
            if (!healthStarted.isCompleted) healthStarted.complete();
            await releaseHealth.future;
          }
          return Response.ok(
            '{}',
            headers: {'content-type': 'application/json'},
          );
        },
        port: 0,
      );
      addTearDown(gated.stop);

      await gated.start();
      final port = gated.port;
      final starts = gated.startCount;
      blockHealth = true;
      final pendingStart = gated.start();
      await healthStarted.future.timeout(const Duration(seconds: 1));

      final stopping = gated.stop();
      releaseHealth.complete();
      await Future.wait([pendingStart, stopping]);

      expect(gated.startCount, starts);
      expect(gated.isStarted, isFalse);
      expect(
        await _responds(Uri.parse('http://127.0.0.1:$port/api/v1/info')),
        isFalse,
      );
    },
  );

  test(
    'failed bind remains recoverable without an automatic retry loop',
    () async {
      final squatter = await ServerSocket.bind('0.0.0.0', 0);
      final blocked = ApiListener(
        handler: (request) =>
            Response.ok('{}', headers: {'content-type': 'application/json'}),
        port: squatter.port,
      );
      addTearDown(() async {
        await blocked.stop();
        await squatter.close();
      });

      final attempts = blocked.startAttemptCount;
      await expectLater(blocked.start(), throwsA(anything));
      expect(blocked.startAttemptCount, attempts + 1);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(blocked.startAttemptCount, attempts + 1);
      expect(await blocked.checkHealth(), isFalse);
    },
  );
}
