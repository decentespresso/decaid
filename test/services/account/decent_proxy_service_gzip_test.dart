import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:reaprime/src/services/account/decent_account_service.dart';
import 'package:reaprime/src/services/account/decent_proxy_service.dart';

class FakeCredentialStore implements CredentialStore {
  @override
  Future<String?> read({required String key}) async => switch (key) {
    'email' => 'user@example.com',
    'password' => 'test-password',
    _ => null,
  };

  @override
  Future<void> write({required String key, required String value}) async {}

  @override
  Future<void> delete({required String key}) async {}
}

void main() {
  final unicodeBody = jsonEncode({'notes': '\u00e9\u4e2d' * 500});
  final originalBytes = utf8.encode(unicodeBody);

  Future<http.Request> captureRequest({
    String method = 'POST',
    String path = 'support/api/shot_upload',
    String? contentType = 'application/json',
    String? body,
    List<int>? bodyBytes,
    bool gzipBody = true,
  }) async {
    late http.Request captured;
    final service = DecentProxyService(
      httpClient: http_testing.MockClient((request) async {
        captured = request;
        return http.Response('{}', 200);
      }),
      credentialStore: FakeCredentialStore(),
      requireConsent: (_) async => true,
    );
    await service.proxy(
      callerId: 'plugin:shot-upload.reaplugin',
      method: method,
      path: path,
      query: {'replace': '1'},
      contentType: contentType,
      body: body,
      bodyBytes: bodyBytes,
      gzipBody: gzipBody,
    );
    return captured;
  }

  for (final useBytes in [false, true]) {
    test('gzips Unicode JSON ${useBytes ? 'bytes' : 'text'} exactly', () async {
      final request = await captureRequest(
        body: useBytes ? 'ignored text' : unicodeBody,
        bodyBytes: useBytes ? originalBytes : null,
      );

      expect(request.headers['content-encoding'], 'gzip');
      expect(gzip.decode(request.bodyBytes), originalBytes);
      expect(request.bodyBytes.length, lessThan(originalBytes.length));
      expect(request.contentLength, request.bodyBytes.length);
      expect(request.headers['content-type'], 'application/json');
      expect(request.url.queryParameters, {'replace': '1'});
      expect(
        request.headers['authorization'],
        'Basic ${base64Encode(utf8.encode('user@example.com:test-password'))}',
      );
      expect(originalBytes, utf8.encode(unicodeBody));
    });
  }

  test(
    'preserves normalized method, path, and parameterized content type',
    () async {
      const contentType = 'Application/JSON; charset=utf-8';
      final request = await captureRequest(
        method: 'post',
        path: ' /support/api/%73hot_upload ',
        contentType: contentType,
        body: unicodeBody,
      );

      expect(request.headers['content-encoding'], 'gzip');
      expect(gzip.decode(request.bodyBytes), originalBytes);
      expect(request.headers['content-type'], contentType);
      expect(request.url.path, '/support/api/shot_upload');
    },
  );

  for (final length in [0, 1023, 1024]) {
    test('applies the byte threshold to a $length-byte body', () async {
      final body = length == 0 ? '' : '{}'.padRight(length);
      final request = await captureRequest(body: body);

      if (length < 1024) {
        expect(request.headers.containsKey('content-encoding'), isFalse);
        expect(request.bodyBytes, utf8.encode(body));
      } else {
        expect(request.headers['content-encoding'], 'gzip');
        expect(gzip.decode(request.bodyBytes), utf8.encode(body));
      }
    });
  }

  test('leaves an absent body plain', () async {
    final request = await captureRequest();
    expect(request.bodyBytes, isEmpty);
    expect(request.headers.containsKey('content-encoding'), isFalse);
  });

  test('empty byte bodies take precedence over large text bodies', () async {
    final request = await captureRequest(
      body: unicodeBody,
      bodyBytes: const [],
    );
    expect(request.bodyBytes, isEmpty);
    expect(request.headers.containsKey('content-encoding'), isFalse);
  });

  for (final authKnownInvalid in [false, true]) {
    test(
      'security checks block uploads (invalid auth: $authKnownInvalid)',
      () async {
        final service = DecentProxyService(
          httpClient: http_testing.MockClient((request) async {
            fail('must not send a rejected upload');
          }),
          credentialStore: FakeCredentialStore(),
          requireConsent: (_) async => false,
          isAuthKnownInvalid: () async => authKnownInvalid,
        );

        await expectLater(
          service.proxyPost(
            callerId: 'plugin:shot-upload.reaplugin',
            path: 'support/api/shot_upload',
            contentType: 'application/json',
            body: unicodeBody,
          ),
          throwsA(
            authKnownInvalid
                ? isA<DecentAccountAuthInvalidException>()
                : isA<DecentProxyConsentDeniedException>(),
          ),
        );
      },
    );
  }

  test('keeps incompressible bytes without an encoding header', () async {
    final random = Random(0);
    final bytes = List<int>.generate(1024, (_) => random.nextInt(256));
    expect(gzip.encode(bytes).length, greaterThanOrEqualTo(bytes.length));

    final request = await captureRequest(bodyBytes: bytes);
    expect(request.bodyBytes, bytes);
    expect(request.headers.containsKey('content-encoding'), isFalse);
    expect(request.contentLength, bytes.length);
  });

  for (final (method, path, contentType) in <(String, String, String?)>[
    ('GET', 'support/api/shot_upload', 'application/json'),
    ('PUT', 'support/api/shot_upload', 'application/json'),
    ('POST', 'support/api/email', 'application/json'),
    ('POST', 'support/api/shot_upload_extra', 'application/json'),
    ('POST', 'support/api/shot_upload/child', 'application/json'),
    ('POST', 'support/api/SHOT_UPLOAD', 'application/json'),
    ('POST', 'support/api/shot_upload', null),
    ('POST', 'support/api/shot_upload', ''),
    ('POST', 'support/api/shot_upload', 'text/plain'),
    ('POST', 'support/api/shot_upload', 'application/octet-stream'),
    ('POST', 'support/api/shot_upload', 'application/problem+json'),
  ]) {
    test('leaves $method $path ($contentType) unchanged', () async {
      final request = await captureRequest(
        method: method,
        path: path,
        contentType: contentType,
        bodyBytes: originalBytes,
        gzipBody: false,
      );

      expect(request.bodyBytes, originalBytes);
      expect(request.headers.containsKey('content-encoding'), isFalse);
    });
  }

  test('identical shot uploads stay plain without an explicit flag', () async {
    final request = await captureRequest(body: unicodeBody, gzipBody: false);
    expect(request.bodyBytes, originalBytes);
    expect(request.headers.containsKey('content-encoding'), isFalse);
  });

  test(
    'explicit compression does not infer an endpoint or media type',
    () async {
      final request = await captureRequest(
        method: 'PUT',
        path: 'support/api/upload',
        contentType: 'text/plain; charset=utf-8',
        body: unicodeBody,
      );
      expect(request.headers['content-encoding'], 'gzip');
      expect(gzip.decode(request.bodyBytes), originalBytes);
      expect(request.headers['content-type'], 'text/plain; charset=utf-8');
    },
  );

  test('does not retry a rejected compressed POST with a plain body', () async {
    var calls = 0;
    final service = DecentProxyService(
      httpClient: http_testing.MockClient((request) async {
        calls++;
        expect(request.headers['content-encoding'], 'gzip');
        return http.Response('unsupported encoding', 415);
      }),
      credentialStore: FakeCredentialStore(),
      requireConsent: (_) async => true,
    );

    final response = await service.proxyPost(
      callerId: 'plugin:shot-upload.reaplugin',
      path: 'support/api/shot_upload',
      contentType: 'application/json',
      body: unicodeBody,
      gzipBody: true,
    );

    expect(calls, 1);
    expect(response.statusCode, 415);
    expect(response.body, 'unsupported encoding');
  });

  test('sends gzip and compressed content length over loopback HTTP', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final client = http.Client();
    addTearDown(() async {
      client.close();
      await server.close(force: true);
    });
    final received = server.first.then((request) async {
      final bytes = await request.expand((chunk) => chunk).toList();
      request.response
        ..statusCode = 201
        ..write('{"ok":true}');
      await request.response.close();
      return (
        encoding: request.headers.value('content-encoding'),
        contentLength: request.headers.contentLength,
        bytes: bytes,
        query: request.uri.queryParameters,
      );
    });
    final service = DecentProxyService(
      httpClient: client,
      credentialStore: FakeCredentialStore(),
      requireConsent: (_) async => true,
      baseUrl: 'http://127.0.0.1:${server.port}',
    );

    final response = await service.proxyPost(
      callerId: 'plugin:shot-upload.reaplugin',
      path: 'support/api/shot_upload',
      query: {'replace': '1'},
      contentType: 'application/json',
      body: unicodeBody,
      gzipBody: true,
    );
    final wire = await received;

    expect(wire.encoding, 'gzip');
    expect(wire.contentLength, wire.bytes.length);
    expect(gzip.decode(wire.bytes), originalBytes);
    expect(wire.query, {'replace': '1'});
    expect(response.statusCode, 201);
    expect(response.body, '{"ok":true}');
  });
}
