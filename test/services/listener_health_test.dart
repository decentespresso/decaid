import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/services/webserver/listener_health.dart';

void main() {
  for (final status in [HttpStatus.ok, HttpStatus.serviceUnavailable]) {
    test('HTTP $status health probe expects HTTP 200', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        await request.drain<void>();
        request.response.statusCode = status;
        await request.response.close();
      });
      try {
        expect(
          await ListenerHealth.probe(
            Uri.parse('http://127.0.0.1:${server.port}/'),
            expectedStatus: HttpStatus.ok,
          ),
          status == HttpStatus.ok,
        );
      } finally {
        await server.close(force: true);
      }
    });
  }

  test('requires the exact non-empty listener identity', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      await request.drain<void>();
      request.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType.json;
      await request.response.close();
    });
    try {
      final uri = Uri.parse('http://127.0.0.1:${server.port}/');
      expect(
        await ListenerHealth.probe(
          uri,
          expectedStatus: HttpStatus.ok,
          expectedListenerId: 'expected',
        ),
        isFalse,
      );
      expect(
        await ListenerHealth.probe(
          uri,
          expectedStatus: HttpStatus.ok,
          expectedListenerId: '',
        ),
        isFalse,
      );
    } finally {
      await server.close(force: true);
    }
  });

  test('accepts the exact listener identity', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      await request.drain<void>();
      request.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType.json
        ..headers.set(listenerIdentityHeader, 'expected');
      await request.response.close();
    });
    try {
      expect(
        await ListenerHealth.probe(
          Uri.parse('http://127.0.0.1:${server.port}/'),
          expectedStatus: HttpStatus.ok,
          expectedListenerId: 'expected',
        ),
        isTrue,
      );
    } finally {
      await server.close(force: true);
    }
  });

  test('rejects a wrong listener identity', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      await request.drain<void>();
      request.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType.json
        ..headers.set(listenerIdentityHeader, 'other');
      await request.response.close();
    });
    try {
      expect(
        await ListenerHealth.probe(
          Uri.parse('http://127.0.0.1:${server.port}/'),
          expectedStatus: HttpStatus.ok,
          expectedListenerId: 'expected',
        ),
        isFalse,
      );
    } finally {
      await server.close(force: true);
    }
  });

  test(
    'times out after receiving a request without sending a response',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final requestSeen = Completer<void>();
      HttpResponse? stalledResponse;
      server.listen((request) async {
        await request.drain<void>();
        stalledResponse = request.response;
        request.response.statusCode = HttpStatus.ok;
        requestSeen.complete();
      });
      try {
        final probe = ListenerHealth.probe(
          Uri.parse('http://127.0.0.1:${server.port}/'),
          expectedStatus: HttpStatus.ok,
          timeout: const Duration(milliseconds: 250),
        );
        await requestSeen.future.timeout(const Duration(seconds: 2));
        expect(stalledResponse!.statusCode, HttpStatus.ok);
        expect(await probe.timeout(const Duration(seconds: 1)), isFalse);
      } finally {
        try {
          await stalledResponse?.close();
        } finally {
          await server.close(force: true);
        }
      }
    },
  );
}
