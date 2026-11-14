import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/services/account/proxy_token_service.dart';
import 'package:reaprime/src/services/webserver/extension_management_auth.dart';
import 'package:shelf/shelf.dart';

class _Grant implements ExtensionManagementGrant {
  @override
  bool isActive = true;

  @override
  String get callerId => 'plugin:manager.reaplugin';
}

class _ConnectionInfo implements HttpConnectionInfo {
  @override
  final InternetAddress remoteAddress;
  @override
  final int localPort;
  @override
  final int remotePort = 51000;

  _ConnectionInfo(this.remoteAddress, {this.localPort = 8080});
}

const _managerToken = 'manager-token';
const _accountToken = 'account-token';
const _accountWriteToken = 'account-write-token';

String _concretePath(ExtensionManagementRoute route) =>
    route.path.replaceAll('<id>', 'example.reaplugin');

void main() {
  late ProxyTokenService tokens;
  late List<Request> reached;
  late Handler handler;

  Handler pipeline(ProxyTokenService? tokens) => const Pipeline()
      .addMiddleware(extensionManagementAuthMiddleware(tokens))
      .addHandler((request) {
        reached.add(request);
        return Response.ok('inner');
      });

  Future<Response> send(
    String method,
    String path, {
    String? authorization,
    Map<String, Object>? context,
    Handler? through,
  }) async {
    return (through ?? handler)(
      Request(
        method,
        Uri.parse('http://localhost$path'),
        headers: {'authorization': ?authorization},
        context: context,
      ),
    );
  }

  Future<String> errorOf(Response response) async =>
      (jsonDecode(await response.readAsString()) as Map)['error'] as String;

  setUp(() {
    tokens = ProxyTokenService(skinToken: 'skin-token')
      ..registerToken(
        _managerToken,
        const ProxyCaller(
          id: 'api:manager',
          scopes: {ProxyTokenService.scopeExtensionsManage},
          label: 'fleet',
        ),
      )
      ..registerToken(
        _accountToken,
        const ProxyCaller(
          id: 'api:account',
          scopes: {ProxyTokenService.scopeAccountProxy},
        ),
      )
      ..registerToken(
        _accountWriteToken,
        const ProxyCaller(
          id: 'api:account-write',
          scopes: {
            ProxyTokenService.scopeAccountProxy,
            ProxyTokenService.scopeAccountProxyWrite,
          },
        ),
      );
    reached = [];
    handler = pipeline(tokens);
  });

  test('the protected table lists every management mutation', () {
    expect(extensionManagementRoutes.map((route) => route.toString()), [
      'POST /api/v1/plugins/install',
      'POST /api/v1/plugins/install/github-release',
      'POST /api/v1/plugins/install/github-branch',
      'POST /api/v1/plugins/update',
      'POST /api/v1/plugins/<id>/settings',
      'PUT /api/v1/plugins/<id>/source',
      'POST /api/v1/plugins/<id>/enable',
      'POST /api/v1/plugins/<id>/disable',
      'POST /api/v1/plugins/<id>/update/approve',
      'DELETE /api/v1/plugins/<id>',
      'PUT /api/v1/webui/skins/default',
      'POST /api/v1/webui/skins/install/github-release',
      'POST /api/v1/webui/skins/install/github-branch',
      'POST /api/v1/webui/skins/install/url',
      'POST /api/v1/webui/skins/update',
      'DELETE /api/v1/webui/skins/<id>',
      'POST /api/v1/webui/server/start',
      'POST /api/v1/webui/server/stop',
    ]);
  });

  group('every protected route', () {
    for (final route in extensionManagementRoutes) {
      final path = _concretePath(route);

      test('$route refuses a request without a bearer', () async {
        final response = await send(route.method, path);
        expect(response.statusCode, 401);
        expect(response.headers['www-authenticate'], 'Bearer');
        expect(await errorOf(response), 'Missing or malformed bearer token');
        expect(reached, isEmpty);
      });

      test('$route refuses a malformed authorization header', () async {
        for (final header in [
          'Basic abc',
          'Bearer',
          'Bearer ',
          _managerToken,
        ]) {
          final response = await send(
            route.method,
            path,
            authorization: header,
          );
          expect(response.statusCode, 401, reason: header);
        }
        expect(reached, isEmpty);
      });

      test('$route refuses an unknown token', () async {
        final response = await send(
          route.method,
          path,
          authorization: 'Bearer not-a-token',
        );
        expect(response.statusCode, 401);
        expect(await errorOf(response), 'Invalid token');
        expect(reached, isEmpty);
      });

      test('$route refuses a revoked token', () async {
        tokens.revokeToken(_managerToken);
        final response = await send(
          route.method,
          path,
          authorization: 'Bearer $_managerToken',
        );
        expect(response.statusCode, 401);
        expect(reached, isEmpty);
      });

      test('$route refuses tokens scoped only for the account', () async {
        for (final token in [_accountToken, _accountWriteToken, 'skin-token']) {
          final response = await send(
            route.method,
            path,
            authorization: 'Bearer $token',
          );
          expect(response.statusCode, 403, reason: token);
          expect(await errorOf(response), contains('extensions:manage'));
        }
        expect(reached, isEmpty);
      });

      test('$route admits a token scoped for extensions:manage', () async {
        final response = await send(
          route.method,
          path,
          authorization: 'Bearer $_managerToken',
        );
        expect(response.statusCode, 200);
        expect(reached, hasLength(1));
      });

      test('$route is not gated for OPTIONS', () async {
        final response = await send('OPTIONS', path);
        expect(response.statusCode, 200);
      });
    }
  });

  group('route precedence', () {
    const open = <(String, String)>[
      ('GET', '/api/v1/plugins'),
      ('GET', '/api/v1/plugins/example.reaplugin/settings'),
      ('GET', '/api/v1/plugins/example.reaplugin/status'),
      ('POST', '/api/v1/plugins/example.reaplugin/status'),
      ('GET', '/api/v1/plugins/example.reaplugin/enable'),
      ('DELETE', '/api/v1/plugins/example.reaplugin/settings'),
      ('POST', '/api/v1/plugins/example.reaplugin/source'),
      ('GET', '/api/v1/plugins/install/github-release'),
      ('GET', '/ws/v1/plugins/example.reaplugin/events'),
      ('GET', '/api/v1/webui/skins'),
      ('GET', '/api/v1/webui/skins/default'),
      ('GET', '/api/v1/webui/skins/streamline'),
      ('GET', '/api/v1/webui/server/status'),
      ('GET', '/api/v1/webui/skin-assets/streamline/index.html'),
      ('POST', '/api/v1/settings'),
      ('POST', '/api/v1/data/import'),
      ('POST', '/api/v1/machine/state/espresso'),
    ];

    for (final (method, path) in open) {
      test('$method $path stays open', () async {
        final response = await send(method, path);
        expect(response.statusCode, 200);
        expect(reached, hasLength(1));
      });
    }

    const aliases = <(String, String)>[
      ('post', '/api/v1/plugins/example.reaplugin/enable'),
      ('POST', '/api/v1/plugins/example.reaplugin/%65nable'),
      ('POST', '/api/v1/plugins/example%2Ereaplugin/enable'),
      ('POST', '/api/v1/plugins/example.reaplugin/enable?token=$_managerToken'),
      ('DELETE', '/api/v1/plugins/update'),
      ('DELETE', '/api/v1/webui/skins/default'),
      ('POST', '/api/v1/plugins/install/enable'),
    ];

    for (final (method, path) in aliases) {
      test('$method $path is still refused', () async {
        final response = await send(method, path);
        expect(response.statusCode, 401);
        expect(reached, isEmpty);
      });
    }
  });

  group('in-process grant', () {
    test('an active grant is admitted without a bearer', () async {
      final response = await send(
        'POST',
        '/api/v1/plugins/example.reaplugin/enable',
        context: {extensionManagementGrantContextKey: _Grant()},
      );
      expect(response.statusCode, 200);
    });

    test('a grant is asked again on every request', () async {
      final grant = _Grant();
      final context = {extensionManagementGrantContextKey: grant};
      expect(
        (await send(
          'POST',
          '/api/v1/webui/server/stop',
          context: context,
        )).statusCode,
        200,
      );

      grant.isActive = false;
      final response = await send(
        'POST',
        '/api/v1/webui/server/stop',
        context: context,
      );
      expect(response.statusCode, 401);
      expect(reached, hasLength(1));
    });

    test('an ended grant is not rescued by a valid bearer', () async {
      final response = await send(
        'POST',
        '/api/v1/webui/server/stop',
        authorization: 'Bearer $_managerToken',
        context: {
          extensionManagementGrantContextKey: _Grant()..isActive = false,
        },
      );
      expect(response.statusCode, 401);
    });

    test('a context value of another type grants nothing', () async {
      final response = await send(
        'POST',
        '/api/v1/webui/server/stop',
        context: {extensionManagementGrantContextKey: true},
      );
      expect(response.statusCode, 401);
    });
  });

  group('handler checks', () {
    test('a request that skipped the middleware is refused', () {
      final request = Request('POST', Uri.parse('http://localhost/x'));
      expect(mayManageExtensions(request), isFalse);
      expect(
        requireExtensionManagement(request, action: 'test')?.statusCode,
        401,
      );
    });

    test('handlers see the decision the middleware made', () async {
      await send('POST', '/api/v1/settings');
      await send(
        'POST',
        '/api/v1/settings',
        authorization: 'Bearer $_accountToken',
      );
      await send(
        'POST',
        '/api/v1/settings',
        authorization: 'Bearer $_managerToken',
      );
      await send(
        'POST',
        '/api/v1/settings',
        context: {extensionManagementGrantContextKey: _Grant()},
      );

      expect(reached.map(mayManageExtensions), [false, false, true, true]);
      expect(
        reached.map(
          (request) =>
              requireExtensionManagement(request, action: 'test')?.statusCode,
        ),
        [401, 403, null, null],
      );
    });
  });

  group('bearer handling', () {
    test('a recognised bearer is not forwarded to handlers', () async {
      for (final token in [_managerToken, _accountToken, 'skin-token']) {
        await send(
          'GET',
          '/api/v1/plugins/example.reaplugin/status',
          authorization: 'Bearer $token',
        );
      }
      expect(
        reached.map((request) => request.headers['authorization']),
        everyElement(isNull),
      );
    });

    test('a mixed-case header name is removed too', () async {
      await handler(
        Request(
          'GET',
          Uri.parse('http://localhost/api/v1/plugins/a/status'),
          headers: {'Authorization': 'Bearer $_managerToken'},
        ),
      );
      expect(reached.single.headers['authorization'], isNull);
    });

    test(
      'a recognised token is removed however the header spells it',
      () async {
        for (final header in [
          'bearer $_managerToken',
          'BEARER $_managerToken',
          'Bearer\t$_managerToken',
          'Bearer $_managerToken, Bearer $_managerToken',
          'Basic abc, Bearer $_managerToken',
          _managerToken,
        ]) {
          await send(
            'GET',
            '/api/v1/plugins/example.reaplugin/status',
            authorization: header,
          );
        }
        expect(reached, hasLength(6));
        expect(
          reached.map((request) => request.headers['authorization']),
          everyElement(isNull),
        );
      },
    );

    test('a recognised token that contains spaces is removed too', () async {
      const spacedToken = 'correct horse battery staple decaid extensions';
      tokens.registerToken(
        spacedToken,
        const ProxyCaller(
          id: 'cli',
          scopes: {ProxyTokenService.scopeExtensionsManage},
        ),
      );

      final gated = await send(
        'POST',
        '/api/v1/plugins/update',
        authorization: 'Bearer $spacedToken',
      );
      await send(
        'GET',
        '/api/v1/plugins/example.reaplugin/status',
        authorization: 'Bearer $spacedToken',
      );

      expect(gated.statusCode, 200);
      expect(reached.map((request) => request.headers['authorization']), [
        isNull,
        isNull,
      ]);
    });

    test('an unrecognised bearer is left for the plugin to judge', () async {
      await send(
        'GET',
        '/api/v1/plugins/example.reaplugin/status',
        authorization: 'Bearer plugin-own-secret',
      );
      expect(
        reached.single.headers['authorization'],
        'Bearer plugin-own-secret',
      );
    });
  });

  test('without a token service the routes are closed, not open', () async {
    final closed = pipeline(null);
    for (final route in extensionManagementRoutes) {
      final response = await send(
        route.method,
        _concretePath(route),
        authorization: 'Bearer $_managerToken',
        through: closed,
      );
      expect(response.statusCode, 401, reason: '$route');
    }
    expect(reached, isEmpty);

    final response = await send(
      'POST',
      '/api/v1/plugins/example.reaplugin/enable',
      context: {extensionManagementGrantContextKey: _Grant()},
      through: closed,
    );
    expect(response.statusCode, 200);
  });

  group('tokenless loopback update checks', () {
    const skinOrigin = 'http://localhost:3000';
    const apiOrigin = 'http://127.0.0.1:8080';
    const lanOrigin = 'http://192.168.1.50:3000';
    const pluginsUpdate = '/api/v1/plugins/update';
    const skinsUpdate = '/api/v1/webui/skins/update';

    final loopback4 = InternetAddress('127.0.0.1');

    late bool automaticOn;
    late DateTime now;
    late Handler loopback;

    Handler buildLoopbackPipeline({
      Future<bool> Function()? setting,
      Set<String> Function()? origins,
      Handler? inner,
    }) {
      return const Pipeline()
          .addMiddleware(
            extensionManagementAuthMiddleware(
              tokens,
              automaticUpdateCheckEnabled: setting ?? () async => automaticOn,
              localOrigins:
                  origins ?? () => const {skinOrigin, apiOrigin, lanOrigin},
              clock: () => now,
            ),
          )
          .addHandler(
            inner ??
                (request) {
                  reached.add(request);
                  return Response.ok('inner');
                },
          );
    }

    Request updateRequest(
      String path, {
      InternetAddress? peer,
      int localPort = 8080,
      Map<String, String> headers = const {'host': 'localhost:8080'},
      Map<String, Object>? extraContext,
    }) {
      return Request(
        'POST',
        Uri.parse('http://localhost:8080$path'),
        headers: headers,
        context: {
          if (peer != null)
            'shelf.io.connection_info': _ConnectionInfo(
              peer,
              localPort: localPort,
            ),
          ...?extraContext,
        },
      );
    }

    setUp(() {
      automaticOn = true;
      now = DateTime(2026, 11, 13, 12);
      loopback = buildLoopbackPipeline();
    });

    test(
      'admits IPv4, IPv6 and mapped loopback peers on both routes',
      () async {
        for (final peer in [
          InternetAddress('127.0.0.1'),
          InternetAddress('127.0.0.2'),
          InternetAddress('::1'),
          InternetAddress('::ffff:127.0.0.1'),
        ]) {
          for (final path in [pluginsUpdate, skinsUpdate]) {
            reached.clear();
            final response = await loopback(updateRequest(path, peer: peer));
            expect(response.statusCode, 200, reason: '${peer.address} $path');
            expect(reached, hasLength(1));
            now = now.add(const Duration(seconds: 31));
          }
        }
      },
    );

    test('an admitted update response carries scoped CORS headers', () async {
      for (final path in [pluginsUpdate, skinsUpdate]) {
        final response = await loopback(
          updateRequest(
            path,
            peer: loopback4,
            headers: {'host': 'localhost:8080', 'origin': skinOrigin},
          ),
        );
        expect(response.statusCode, 200, reason: path);
        expect(
          response.headers['access-control-allow-origin'],
          skinOrigin,
          reason: '$path must be readable by the skin origin',
        );
        expect(response.headers['vary'], contains('Origin'));
      }
    });

    test('CORS is never added when no Origin is present', () async {
      final response = await loopback(
        updateRequest(skinsUpdate, peer: loopback4),
      );
      expect(response.statusCode, 200);
      expect(
        response.headers.containsKey('access-control-allow-origin'),
        isFalse,
      );
    });

    test(
      'an existing Vary value is preserved when Origin is appended',
      () async {
        final pipeline = buildLoopbackPipeline(
          inner: (request) {
            reached.add(request);
            return Response.ok('inner', headers: {'vary': 'Accept-Encoding'});
          },
        );
        final response = await pipeline(
          updateRequest(
            skinsUpdate,
            peer: loopback4,
            headers: {'host': 'localhost:8080', 'origin': skinOrigin},
          ),
        );
        expect(response.headers['access-control-allow-origin'], skinOrigin);
        expect(response.headers['vary'], 'Accept-Encoding, Origin');
      },
    );

    test('a disallowed Origin is refused and gets no CORS header', () async {
      final response = await loopback(
        updateRequest(
          skinsUpdate,
          peer: loopback4,
          headers: {'host': 'localhost:8080', 'origin': lanOrigin},
        ),
      );
      expect(response.statusCode, anyOf(401, 403));
      expect(
        response.headers.containsKey('access-control-allow-origin'),
        isFalse,
        reason: 'CORS must never widen authorization',
      );
    });

    test(
      'a LAN peer spoofing an allowed Origin is refused without CORS',
      () async {
        final response = await loopback(
          updateRequest(
            skinsUpdate,
            peer: InternetAddress('192.168.1.50'),
            headers: {'host': 'localhost:8080', 'origin': skinOrigin},
          ),
        );
        expect(response.statusCode, anyOf(401, 403));
        expect(
          response.headers.containsKey('access-control-allow-origin'),
          isFalse,
        );
      },
    );

    test(
      'a disabled setting refuses before any CORS header is added',
      () async {
        automaticOn = false;
        final response = await loopback(
          updateRequest(
            skinsUpdate,
            headers: {'host': 'localhost:8080', 'origin': skinOrigin},
          ),
        );
        expect(response.statusCode, anyOf(401, 403));
        expect(
          response.headers.containsKey('access-control-allow-origin'),
          isFalse,
        );
      },
    );

    test('a throttled tokenless retry stays browser-readable', () async {
      final headers = {'host': 'localhost:8080', 'origin': skinOrigin};
      final first = await loopback(
        updateRequest(skinsUpdate, peer: loopback4, headers: headers),
      );
      expect(first.statusCode, 200);

      final second = await loopback(
        updateRequest(skinsUpdate, peer: loopback4, headers: headers),
      );
      expect(second.statusCode, 429);
      expect(second.headers['access-control-allow-origin'], skinOrigin);
      expect(second.headers['retry-after'], isNotNull);
    });

    test('refuses non-loopback and absent peers', () async {
      for (final peer in [
        InternetAddress('192.168.1.20'),
        InternetAddress('10.0.0.5'),
        InternetAddress('203.0.113.9'),
        InternetAddress('::ffff:192.168.1.20'),
        InternetAddress('fe80::1'),
        InternetAddress('::'),
      ]) {
        final response = await loopback(
          updateRequest(pluginsUpdate, peer: peer),
        );
        expect(response.statusCode, 401, reason: peer.address);
        expect(response.headers['www-authenticate'], 'Bearer');
      }
      final missing = await loopback(updateRequest(pluginsUpdate));
      expect(missing.statusCode, 401);
      expect(reached, isEmpty);
    });

    test('never trusts forwarding headers as peer proof', () async {
      final response = await loopback(
        updateRequest(
          pluginsUpdate,
          peer: InternetAddress('192.168.1.20'),
          headers: {
            'host': 'localhost:8080',
            'x-forwarded-for': '127.0.0.1',
            'x-real-ip': '127.0.0.1',
            'referer': 'http://localhost:3000/',
            'origin': skinOrigin,
          },
        ),
      );
      expect(response.statusCode, 401);
      expect(reached, isEmpty);
    });

    test(
      'fails closed when the setting is off, unreadable or unwired',
      () async {
        automaticOn = false;
        expect(
          (await loopback(updateRequest(pluginsUpdate, peer: loopback4)))
              .statusCode,
          401,
        );

        final failing = buildLoopbackPipeline(
          setting: () async => throw StateError('prefs unreadable'),
        );
        expect(
          (await failing(updateRequest(pluginsUpdate, peer: loopback4)))
              .statusCode,
          401,
        );

        final unwired = const Pipeline()
            .addMiddleware(extensionManagementAuthMiddleware(tokens))
            .addHandler((request) {
              reached.add(request);
              return Response.ok('inner');
            });
        expect(
          (await unwired(updateRequest(pluginsUpdate, peer: loopback4)))
              .statusCode,
          401,
        );
        expect(reached, isEmpty);
      },
    );

    test(
      'reads the setting fresh on every dispatch, throttled or not',
      () async {
        var reads = 0;
        final counting = buildLoopbackPipeline(
          setting: () async {
            reads += 1;
            return automaticOn;
          },
        );

        expect(
          (await counting(updateRequest(pluginsUpdate, peer: loopback4)))
              .statusCode,
          200,
        );
        automaticOn = false;
        // The setting is consulted before the throttle: off means 401, not 429.
        expect(
          (await counting(updateRequest(pluginsUpdate, peer: loopback4)))
              .statusCode,
          401,
        );
        automaticOn = true;
        expect(
          (await counting(updateRequest(pluginsUpdate, peer: loopback4)))
              .statusCode,
          429,
        );
        expect(reads, 3);
        expect(reached, hasLength(1));
      },
    );

    test('validates Host as a loopback authority on the local port', () async {
      Future<int> status(
        String? host, {
        int localPort = 8080,
        InternetAddress? peer,
      }) async {
        final response = await loopback(
          updateRequest(
            pluginsUpdate,
            peer: peer ?? loopback4,
            localPort: localPort,
            headers: {'host': ?host},
          ),
        );
        now = now.add(const Duration(seconds: 31));
        return response.statusCode;
      }

      expect(await status('localhost:8080'), 200);
      expect(await status('LOCALHOST:8080'), 200);
      expect(await status('127.0.0.1:8080'), 200);
      expect(await status('[::1]:8080', peer: InternetAddress('::1')), 200);
      expect(await status('[::ffff:127.0.0.1]:8080'), 200);
      expect(await status('localhost', localPort: 80), 200);

      expect(await status(null), 401);
      expect(await status(''), 401);
      expect(await status('localhost:9090'), 401);
      expect(await status('localhost'), 401);
      expect(await status('evil.com:8080'), 401);
      expect(await status('192.168.1.50:8080'), 401);
      expect(await status('localhost.evil.com:8080'), 401);
      expect(await status('user@localhost:8080'), 401);
      expect(await status('localhost:8080/path'), 401);
      expect(await status('localhost:notaport'), 401);
      expect(reached, hasLength(6));
    });

    test('admits the active skin and api loopback origins', () async {
      for (final origin in [skinOrigin, apiOrigin]) {
        final response = await loopback(
          updateRequest(
            pluginsUpdate,
            peer: loopback4,
            headers: {'host': 'localhost:8080', 'origin': origin},
          ),
        );
        expect(response.statusCode, 200, reason: origin);
        now = now.add(const Duration(seconds: 31));
      }
      expect(reached, hasLength(2));
    });

    test('refuses null, cross-origin, malformed and LAN origins', () async {
      for (final origin in [
        'null',
        'https://evil.example',
        'not-an-origin',
        'http://localhost:9999',
        'https://localhost:3000',
        lanOrigin,
      ]) {
        final response = await loopback(
          updateRequest(
            pluginsUpdate,
            peer: loopback4,
            headers: {'host': 'localhost:8080', 'origin': origin},
          ),
        );
        expect(response.statusCode, 401, reason: origin);
      }
      expect(reached, isEmpty);
    });

    test('admits a local client without an Origin header', () async {
      final noOrigins = buildLoopbackPipeline(origins: () => const {});
      final response = await noOrigins(
        updateRequest(pluginsUpdate, peer: loopback4),
      );
      expect(response.statusCode, 200);
      expect(reached, hasLength(1));
    });

    test('any presented credential keeps the existing decision', () async {
      Future<Response> withHeader(String authorization) async => loopback(
        updateRequest(
          pluginsUpdate,
          peer: loopback4,
          headers: {'host': 'localhost:8080', 'authorization': authorization},
        ),
      );

      final invalid = await withHeader('Bearer not-a-token');
      expect(invalid.statusCode, 401);
      expect(await errorOf(invalid), 'Invalid token');

      final malformed = await withHeader('Basic abc');
      expect(malformed.statusCode, 401);
      expect(await errorOf(malformed), 'Missing or malformed bearer token');

      final unscoped = await withHeader('Bearer $_accountToken');
      expect(unscoped.statusCode, 403);
      expect(await errorOf(unscoped), contains('extensions:manage'));

      final manager = await withHeader('Bearer $_managerToken');
      expect(manager.statusCode, 200);
      expect(reached, hasLength(1));
    });

    test(
      'bearers and grants work regardless of setting, peer and origin',
      () async {
        automaticOn = false;
        final remote = InternetAddress('203.0.113.9');

        final bearer = await loopback(
          updateRequest(
            pluginsUpdate,
            peer: remote,
            headers: {
              'host': 'decaid-dashboard.local:8080',
              'authorization': 'Bearer $_managerToken',
            },
          ),
        );
        expect(bearer.statusCode, 200);

        final granted = await loopback(
          updateRequest(
            skinsUpdate,
            peer: remote,
            headers: const {},
            extraContext: {extensionManagementGrantContextKey: _Grant()},
          ),
        );
        expect(granted.statusCode, 200);
        expect(reached, hasLength(2));
      },
    );

    test('an ended grant keeps its denial even on loopback', () async {
      final response = await loopback(
        updateRequest(
          pluginsUpdate,
          peer: loopback4,
          extraContext: {
            extensionManagementGrantContextKey: _Grant()..isActive = false,
          },
        ),
      );
      expect(response.statusCode, 401);
      expect(
        await errorOf(response),
        'Plugin extension-management authority has ended',
      );
      expect(reached, isEmpty);
    });

    test('an admitted tokenless request is not a management grant', () async {
      final response = await loopback(
        updateRequest(pluginsUpdate, peer: loopback4),
      );
      expect(response.statusCode, 200);
      final request = reached.single;
      expect(mayManageExtensions(request), isFalse);
      expect(
        requireExtensionManagement(request, action: 'test')?.statusCode,
        401,
      );
      expect(request.headers['authorization'], isNull);
    });

    test('other protected routes keep their denial on loopback', () async {
      for (final (method, path) in [
        ('POST', '/api/v1/plugins/install'),
        ('POST', '/api/v1/plugins/example.reaplugin/update/approve'),
        ('PUT', '/api/v1/plugins/example.reaplugin/source'),
        ('POST', '/api/v1/webui/server/stop'),
      ]) {
        final response = await loopback(
          Request(
            method,
            Uri.parse('http://localhost:8080$path'),
            headers: const {'host': 'localhost:8080'},
            context: {'shelf.io.connection_info': _ConnectionInfo(loopback4)},
          ),
        );
        expect(response.statusCode, 401, reason: '$method $path');
      }
      expect(reached, isEmpty);
    });

    test('OPTIONS on the update routes stays open', () async {
      for (final path in [pluginsUpdate, skinsUpdate]) {
        final response = await loopback(
          Request('OPTIONS', Uri.parse('http://localhost:8080$path')),
        );
        expect(response.statusCode, 200, reason: path);
      }
      expect(reached, hasLength(2));
    });

    test(
      'throttles a completed tokenless check for thirty seconds per route',
      () async {
        Future<Response> check(String path) async =>
            loopback(updateRequest(path, peer: loopback4));

        expect((await check(pluginsUpdate)).statusCode, 200);

        final throttled = await check(pluginsUpdate);
        expect(throttled.statusCode, 429);
        expect(throttled.headers['retry-after'], '30');
        expect(await errorOf(throttled), contains('retry'));
        expect(reached, hasLength(1));

        // The two route keys are independent.
        expect((await check(skinsUpdate)).statusCode, 200);

        now = now.add(const Duration(seconds: 30));
        expect((await check(pluginsUpdate)).statusCode, 200);
        expect(reached, hasLength(3));
      },
    );

    test(
      'bearer and grant calls are not throttled and do not throttle',
      () async {
        Future<Response> manager() async => loopback(
          updateRequest(
            pluginsUpdate,
            peer: loopback4,
            headers: {
              'host': 'localhost:8080',
              'authorization': 'Bearer $_managerToken',
            },
          ),
        );

        expect((await manager()).statusCode, 200);
        expect((await manager()).statusCode, 200);

        // Manager completions are not recorded against the tokenless budget.
        expect(
          (await loopback(updateRequest(pluginsUpdate, peer: loopback4)))
              .statusCode,
          200,
        );

        // A bearer call right after a tokenless completion is still fine.
        expect((await manager()).statusCode, 200);
        expect(reached, hasLength(4));
      },
    );

    test(
      'overlapping tokenless checks still reach the coalescing services',
      () async {
        final firstEntered = Completer<void>();
        final bothEntered = Completer<void>();
        final release = Completer<void>();
        var entries = 0;
        final gated = buildLoopbackPipeline(
          inner: (request) async {
            entries += 1;
            if (entries == 1) firstEntered.complete();
            if (entries == 2) bothEntered.complete();
            await release.future;
            return Response.ok('inner');
          },
        );

        final first = gated(updateRequest(pluginsUpdate, peer: loopback4));
        await firstEntered.future.timeout(const Duration(seconds: 5));
        final second = gated(updateRequest(pluginsUpdate, peer: loopback4));
        await bothEntered.future.timeout(const Duration(seconds: 5));
        release.complete();

        expect((await first).statusCode, 200);
        expect((await second).statusCode, 200);

        // Completion was recorded when the in-flight checks finished.
        final third = await gated(
          updateRequest(pluginsUpdate, peer: loopback4),
        );
        expect(third.statusCode, 429);
      },
    );
  });
}
