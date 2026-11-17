import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/services/webserver/extension_management_auth.dart';
import 'package:reaprime/src/services/webserver_service.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_cors_headers/shelf_cors_headers.dart';

const _connectionInfoKey = 'shelf.io.connection_info';

class _SocketPeer implements HttpConnectionInfo {
  _SocketPeer(String address) : remoteAddress = InternetAddress(address);

  @override
  final InternetAddress remoteAddress;

  @override
  int get remotePort => 51000;

  @override
  int get localPort => 8080;
}

final _loopbackPeer = _SocketPeer('127.0.0.1');

void main() {
  late Handler handler;
  late Set<String> allowedOrigins;

  setUp(() {
    allowedOrigins = {'http://localhost:3000', 'http://127.0.0.1:3000'};

    handler = const Pipeline()
        .addMiddleware(accountProxyCorsMiddleware(() => allowedOrigins))
        .addMiddleware(
          corsHeaders(
            headers: {
              'Access-Control-Expose-Headers': 'ETag',
              'Access-Control-Allow-Headers':
                  'Accept, Authorization, Content-Type',
            },
          ),
        )
        .addHandler((_) => Response.ok('ok'));
  });

  Future<Response> request(String method, String path, {String? origin}) async {
    final headers = <String, String>{};
    if (origin != null) {
      headers['origin'] = origin;
    }
    return await handler(
      Request(method, Uri.parse('http://localhost$path'), headers: headers),
    );
  }

  test(
    'proxy request from an allowed skin origin echoes that origin',
    () async {
      allowedOrigins.add('http://192.168.4.20:3000');

      final response = await request(
        'GET',
        '/api/v1/account/proxy/support/api/sn',
        origin: 'http://192.168.4.20:3000',
      );

      expect(
        response.headers['access-control-allow-origin'],
        'http://192.168.4.20:3000',
      );
      expect(response.headers['vary'], contains('Origin'));
    },
  );

  test(
    'proxy request allows a LAN skin origin learned after handler startup',
    () async {
      final before = await request(
        'GET',
        '/api/v1/account/proxy/support/api/sn',
        origin: 'http://192.168.4.20:3000',
      );

      allowedOrigins.add('http://192.168.4.20:3000');

      final after = await request(
        'GET',
        '/api/v1/account/proxy/support/api/sn',
        origin: 'http://192.168.4.20:3000',
      );

      expect(before.headers['access-control-allow-origin'], isNull);
      expect(
        after.headers['access-control-allow-origin'],
        'http://192.168.4.20:3000',
      );
    },
  );

  test(
    'proxy request from a disallowed origin does not get wildcard ACAO',
    () async {
      final response = await request(
        'GET',
        '/api/v1/account/proxy/support/api/sn',
        origin: 'https://evil.example',
      );

      expect(response.headers['access-control-allow-origin'], isNull);
      expect(response.headers.values, isNot(contains('*')));
    },
  );

  test(
    'proxy preflight from an allowed skin origin echoes that origin',
    () async {
      final response = await request(
        'OPTIONS',
        '/api/v1/account/proxy/support/api/sn',
        origin: 'http://localhost:3000',
      );

      expect(
        response.headers['access-control-allow-origin'],
        'http://localhost:3000',
      );
    },
  );

  test('non-proxy API paths keep the existing permissive CORS', () async {
    final response = await request(
      'GET',
      '/api/v1/devices',
      origin: 'https://any.example',
    );

    expect(
      response.headers['access-control-allow-origin'],
      'https://any.example',
    );
  });

  group('the management browser origin policy stays separate', () {
    late Handler guarded;

    setUp(() {
      final origins = ExtensionManagementBrowserOrigins(
        apiListenerPort: () => 8080,
        pagePorts: () => const {3000},
        deviceAddresses: () async => const {},
      );
      guarded = const Pipeline()
          .addMiddleware(extensionManagementBrowserOriginMiddleware(origins))
          .addMiddleware(accountProxyCorsMiddleware(() => allowedOrigins))
          .addMiddleware(
            corsHeaders(
              headers: {
                'Access-Control-Expose-Headers': 'ETag',
                'Access-Control-Allow-Headers':
                    'Accept, Authorization, Content-Type',
              },
            ),
          )
          .addHandler((_) => Response.ok('ok'));
    });

    Future<Response> send(String method, String path, {String? origin}) async =>
        guarded(
          Request(
            method,
            Uri.parse('http://localhost$path'),
            headers: {'origin': ?origin},
            context: {_connectionInfoKey: _loopbackPeer},
          ),
        );

    const proxyPath = '/api/v1/account/proxy/support/api/sn';
    const managementPath = '/api/v1/plugins/update';

    test(
      'the proxy allowlist does not widen to a management-trusted origin',
      () async {
        final response = await send(
          'GET',
          proxyPath,
          origin: 'http://127.0.0.1:8080',
        );

        expect(response.statusCode, 200);
        expect(response.headers['access-control-allow-origin'], isNull);
      },
    );

    test('a proxy request from a skin origin keeps its ACAO', () async {
      final response = await send(
        'GET',
        proxyPath,
        origin: 'http://localhost:3000',
      );

      expect(response.statusCode, 200);
      expect(
        response.headers['access-control-allow-origin'],
        'http://localhost:3000',
      );
    });

    test('a management mutation from an untrusted origin is refused without '
        'CORS or preflight headers', () async {
      final refused = await send(
        'POST',
        managementPath,
        origin: 'https://evil.example',
      );
      expect(refused.statusCode, 403);
      for (final name in [
        'access-control-allow-origin',
        'access-control-allow-credentials',
        'access-control-allow-methods',
        'access-control-allow-headers',
        'access-control-expose-headers',
      ]) {
        expect(refused.headers[name], isNull, reason: name);
      }

      final preflight = await send(
        'OPTIONS',
        managementPath,
        origin: 'https://evil.example',
      );
      expect(preflight.statusCode, 403);
      expect(preflight.headers['access-control-allow-origin'], isNull);
      expect(preflight.headers['access-control-allow-methods'], isNull);
    });

    test('a management mutation from a trusted origin keeps the general CORS '
        'echo', () async {
      final response = await send(
        'POST',
        managementPath,
        origin: 'http://localhost:3000',
      );

      expect(response.statusCode, 200);
      expect(
        response.headers['access-control-allow-origin'],
        'http://localhost:3000',
      );
    });

    test('the proxy path keeps refusing an untrusted origin', () async {
      final response = await send(
        'GET',
        proxyPath,
        origin: 'https://evil.example',
      );

      expect(response.statusCode, 200);
      expect(response.headers['access-control-allow-origin'], isNull);
    });

    test('a loopback origin without socket peer provenance is refused while '
        'the proxy keeps its own rule', () async {
      const origin = 'http://127.0.0.1:8080';

      final mutation = await guarded(
        Request(
          'POST',
          Uri.parse('http://localhost$managementPath'),
          headers: const {'origin': origin},
        ),
      );
      expect(mutation.statusCode, 403);
      expect(mutation.headers['access-control-allow-origin'], isNull);

      final proxied = await guarded(
        Request(
          'GET',
          Uri.parse('http://localhost$proxyPath'),
          headers: const {'origin': origin},
        ),
      );
      expect(proxied.statusCode, 200);
      expect(proxied.headers['access-control-allow-origin'], isNull);
    });
  });
}
