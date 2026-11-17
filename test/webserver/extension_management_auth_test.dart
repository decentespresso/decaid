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

class _SocketPeer implements HttpConnectionInfo {
  _SocketPeer(String address) : this._(InternetAddress(address));

  _SocketPeer._(this.remoteAddress);

  @override
  final InternetAddress remoteAddress;

  @override
  int get remotePort => 51000;

  @override
  int get localPort => 8080;
}

class _UnreadableSocketPeer implements HttpConnectionInfo {
  @override
  InternetAddress get remoteAddress =>
      throw const SocketException('peer address is unreadable');

  @override
  int get remotePort => 51000;

  @override
  int get localPort => 8080;
}

const _connectionInfoKey = 'shelf.io.connection_info';

final _loopbackPeer = _SocketPeer('127.0.0.1');

class _NoPeer {
  const _NoPeer();
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
    test('a request that skipped the middleware is refused', () async {
      final request = Request('POST', Uri.parse('http://localhost/x'));
      expect(await mayManageExtensions(request), isFalse);
      expect(
        (await requireExtensionManagement(request, action: 'test'))?.statusCode,
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

      expect(await Future.wait(reached.map(mayManageExtensions)), [
        false,
        false,
        true,
        true,
      ]);
      expect(
        await Future.wait(
          reached.map(
            (request) async => (await requireExtensionManagement(
              request,
              action: 'test',
            ))?.statusCode,
          ),
        ),
        [401, 403, null, null],
      );
    });
  });

  group('denial responses', () {
    const enabling = '/api/v1/plugins/example.reaplugin/enable';

    test(
      'a wrong-scope refusal is a JSON body with a JSON content type',
      () async {
        final response = await send(
          'POST',
          enabling,
          authorization: 'Bearer $_accountToken',
        );

        expect(response.statusCode, 403);
        expect(response.headers['content-type'], 'application/json');
        expect(await errorOf(response), contains('extensions:manage'));
      },
    );

    test(
      'a tokenless refusal is a JSON body with a JSON content type',
      () async {
        final response = await send('POST', enabling);

        expect(response.statusCode, 401);
        expect(response.headers['content-type'], 'application/json');
      },
    );
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

  group('extension management authorization mode', () {
    Handler modePipeline(Future<bool> Function()? requirement) =>
        const Pipeline()
            .addMiddleware(
              extensionManagementAuthMiddleware(
                tokens,
                requireExtensionManagementAuthorization: requirement,
              ),
            )
            .addHandler((request) {
              reached.add(request);
              return Response.ok('inner');
            });

    Request managementRequest(
      String method,
      String path, {
      Map<String, String> headers = const {},
      Map<String, Object>? context,
    }) => Request(
      method,
      Uri.parse('http://localhost$path'),
      headers: {'host': 'localhost', ...headers},
      context: context,
    );

    for (final route in extensionManagementRoutes) {
      final path = _concretePath(route);

      test('$route follows the mode for a tokenless caller', () async {
        reached.clear();
        expect(
          (await send(
            route.method,
            path,
            through: modePipeline(() async => false),
          )).statusCode,
          200,
        );
        expect(reached, hasLength(1));

        expect(
          (await send(
            route.method,
            path,
            through: modePipeline(() async => true),
          )).statusCode,
          401,
        );
        expect(reached, hasLength(1));
      });

      test('$route fails closed without a usable mode', () async {
        reached.clear();
        expect(
          (await send(
            route.method,
            path,
            through: modePipeline(
              () async => throw StateError('prefs unreadable'),
            ),
          )).statusCode,
          401,
        );
        expect(
          (await send(
            route.method,
            path,
            through: modePipeline(null),
          )).statusCode,
          401,
        );
        expect(reached, isEmpty);
      });
    }

    test('the mode is resolved once per request', () async {
      var reads = 0;
      final flipping = modePipeline(() async {
        reads += 1;
        return reads > 1;
      });

      final response = await flipping(
        managementRequest('POST', '/api/v1/settings'),
      );

      expect(response.statusCode, 200);
      expect(reads, 0, reason: 'the route is classified before any read');
      final request = reached.single;
      expect(await mayManageExtensions(request), isTrue);
      expect(await requireExtensionManagement(request, action: 'test'), isNull);
      expect(reads, 1, reason: 'the handler consult reads the mode once');
    });

    test(
      'a mode flip applies to the next request, not the current one',
      () async {
        var protect = false;
        final flipping = modePipeline(() async => protect);

        final first = await flipping(
          managementRequest('POST', '/api/v1/plugins/install'),
        );
        expect(first.statusCode, 200);

        protect = true;
        final second = await flipping(
          managementRequest('POST', '/api/v1/plugins/install'),
        );
        expect(second.statusCode, 401);
        expect(reached, hasLength(1));
      },
    );

    test('admission does not depend on peer, host or origin', () async {
      final open = modePipeline(() async => false);
      final protected = modePipeline(() async => true);
      final request = managementRequest(
        'POST',
        '/api/v1/plugins/example.reaplugin/enable',
        headers: const {
          'host': 'decaid-dashboard.example:8080',
          'origin': 'https://remote.example',
          'x-forwarded-for': '127.0.0.1',
        },
      );

      expect((await open(request)).statusCode, 200);
      expect((await protected(request)).statusCode, 401);
      expect(reached, hasLength(1));
    });

    test('compatibility mode keeps every credential decision', () async {
      final open = modePipeline(() async => false);
      for (final route in extensionManagementRoutes) {
        reached.clear();
        final response = await open(
          managementRequest(
            route.method,
            _concretePath(route),
            headers: const {'authorization': 'Bearer $_managerToken'},
          ),
        );
        expect(response.statusCode, 200, reason: '$route');
        expect(reached, hasLength(1), reason: '$route');
      }
    });

    test('compatibility mode still strips a recognised bearer', () async {
      final open = modePipeline(() async => false);

      await open(
        managementRequest(
          'POST',
          '/api/v1/plugins/install',
          headers: const {'authorization': 'Bearer $_managerToken'},
        ),
      );

      expect(reached.single.headers['authorization'], isNull);
    });

    test('compatibility mode keeps the in-process grant lifecycle', () async {
      final open = modePipeline(() async => false);

      final active = await open(
        managementRequest(
          'POST',
          '/api/v1/webui/server/stop',
          context: {extensionManagementGrantContextKey: _Grant()},
        ),
      );
      expect(active.statusCode, 200);

      final ended = await open(
        managementRequest(
          'POST',
          '/api/v1/webui/server/stop',
          context: {
            extensionManagementGrantContextKey: _Grant()..isActive = false,
          },
        ),
      );
      expect(ended.statusCode, 401);
      expect(
        await errorOf(ended),
        'Plugin extension-management authority has ended',
      );
      expect(await mayManageExtensions(reached.single), isTrue);
      expect(reached, hasLength(1));
    });

    test(
      'compatibility mode never adds CORS to a management response',
      () async {
        final open = modePipeline(() async => false);

        final response = await open(
          managementRequest(
            'POST',
            '/api/v1/plugins/update',
            headers: const {'origin': 'http://localhost:3000'},
          ),
        );

        expect(response.statusCode, 200);
        expect(
          response.headers.containsKey('access-control-allow-origin'),
          isFalse,
        );
      },
    );

    test('protected mode refuses tokenless update checks', () async {
      final protected = modePipeline(() async => true);

      for (final path in [
        '/api/v1/plugins/update',
        '/api/v1/webui/skins/update',
      ]) {
        final response = await protected(managementRequest('POST', path));
        expect(response.statusCode, 401, reason: path);
        expect(response.headers['www-authenticate'], 'Bearer');
      }
      expect(reached, isEmpty);
    });
  });

  group('request-scoped security mode', () {
    Handler modePipeline(Future<bool> Function()? requirement) =>
        const Pipeline()
            .addMiddleware(
              extensionManagementAuthMiddleware(
                tokens,
                requireExtensionManagementAuthorization: requirement,
              ),
            )
            .addHandler((request) {
              reached.add(request);
              return Response.ok('inner');
            });

    Request plain(String method, String path) => Request(
      method,
      Uri.parse('http://localhost$path'),
      headers: const {'host': 'localhost'},
    );

    test(
      'an ordinary request completes while the security read is blocked',
      () async {
        final readStarted = Completer<String>();
        final release = Completer<bool>();
        var reads = 0;
        final blocked = modePipeline(() {
          reads += 1;
          if (!readStarted.isCompleted) readStarted.complete('security read');
          return release.future;
        });

        final response = Future<Response>.sync(
          () => blocked(plain('GET', '/api/v1/machine/state/espresso')),
        );
        final winner = await Future.any<String>([
          response.then((_) => 'response'),
          readStarted.future,
        ]);

        expect(
          winner,
          'response',
          reason:
              'the security setting was read before the route was classified',
        );
        expect((await response).statusCode, 200);
        expect(reads, 0);
        expect(reached, hasLength(1));
        if (!release.isCompleted) release.complete(false);
      },
    );

    test('an unrelated route never invokes the mode reader', () async {
      var reads = 0;
      final counting = modePipeline(() async {
        reads += 1;
        return true;
      });

      for (final (method, path) in const [
        ('GET', '/api/v1/machine/state/espresso'),
        ('GET', '/api/v1/settings'),
        ('GET', '/api/v1/plugins'),
        ('GET', '/api/v1/webui/server/status'),
        ('POST', '/api/v1/account/proxy/models'),
        ('GET', '/api/v1/data/export'),
      ]) {
        reached.clear();
        final response = await counting(plain(method, path));
        expect(response.statusCode, 200, reason: '$method $path');
        expect(reached, hasLength(1), reason: '$method $path');
      }

      expect(reads, 0);
    });

    test('a protected mutation waits for the mode decision', () async {
      final decision = Completer<bool>();
      final readStarted = Completer<String>();
      var reads = 0;
      final gated = modePipeline(() {
        reads += 1;
        if (!readStarted.isCompleted) readStarted.complete('security read');
        return decision.future;
      });

      final response = Future<Response>.sync(
        () => gated(plain('POST', '/api/v1/plugins/example.reaplugin/enable')),
      );
      final winner = await Future.any<String>([
        response.then((_) => 'response'),
        readStarted.future,
      ]);

      expect(winner, 'security read');
      expect(reached, isEmpty);

      decision.complete(true);
      expect((await response).statusCode, 401);
      expect(reads, 1);
      expect(reached, isEmpty);
    });

    test('an unreadable mode fails closed for a relevant request', () async {
      final failing = modePipeline(
        () async => throw StateError('prefs unreadable'),
      );

      expect(
        (await failing(
          plain('POST', '/api/v1/plugins/example.reaplugin/enable'),
        )).statusCode,
        401,
      );
      expect(reached, isEmpty);
    });

    test('an unreadable mode does not block an unrelated route', () async {
      final failing = modePipeline(
        () async => throw StateError('prefs unreadable'),
      );
      final failed = await failing(
        plain('GET', '/api/v1/machine/state/espresso'),
      );
      expect(failed.statusCode, 200);
      expect(reached, hasLength(1));

      final readStarted = Completer<String>();
      final release = Completer<bool>();
      var reads = 0;
      final blocked = modePipeline(() {
        reads += 1;
        if (!readStarted.isCompleted) readStarted.complete('security read');
        return release.future;
      });

      final pending = Future<Response>.sync(
        () => blocked(plain('GET', '/api/v1/machine/state/espresso')),
      );
      expect(
        await Future.any<String>([
          pending.then((_) => 'response'),
          readStarted.future,
        ]),
        'response',
      );
      expect((await pending).statusCode, 200);
      expect(reads, 0);
      if (!release.isCompleted) release.complete(false);
    });

    test('the route gate and a handler check share one decision', () async {
      var reads = 0;
      final consultations = <Response?>[];
      final handler = const Pipeline()
          .addMiddleware(
            extensionManagementAuthMiddleware(
              tokens,
              requireExtensionManagementAuthorization: () async {
                reads += 1;
                return reads > 1;
              },
            ),
          )
          .addHandler((request) async {
            consultations.add(
              await requireExtensionManagement(request, action: 'test'),
            );
            return Response.ok('inner');
          });

      final response = await handler(
        plain('POST', '/api/v1/plugins/example.reaplugin/enable'),
      );

      expect(response.statusCode, 200);
      expect(consultations.single, isNull);
      expect(reads, 1);
    });

    test(
      'turning protection on applies to the next relevant request',
      () async {
        var protect = false;
        final flipping = modePipeline(() async => protect);

        expect(
          (await flipping(
            plain('POST', '/api/v1/plugins/example.reaplugin/enable'),
          )).statusCode,
          200,
        );

        protect = true;
        expect(
          (await flipping(
            plain('POST', '/api/v1/plugins/example.reaplugin/enable'),
          )).statusCode,
          401,
        );
        expect(reached, hasLength(1));
      },
    );

    test(
      'turning protection off applies to the next relevant request',
      () async {
        var protect = true;
        final flipping = modePipeline(() async => protect);

        expect(
          (await flipping(
            plain('POST', '/api/v1/plugins/example.reaplugin/enable'),
          )).statusCode,
          401,
        );

        protect = false;
        expect(
          (await flipping(
            plain('POST', '/api/v1/plugins/example.reaplugin/enable'),
          )).statusCode,
          200,
        );
        expect(reached, hasLength(1));
      },
    );
  });

  group('browser origin source', () {
    ExtensionManagementBrowserOrigins source({
      int? apiListenerPort = 8080,
      Set<int> pagePorts = const {25707},
      Set<String> deviceAddresses = const {'192.168.12.64'},
    }) => ExtensionManagementBrowserOrigins(
      apiListenerPort: () => apiListenerPort,
      pagePorts: () => pagePorts,
      deviceAddresses: () async => deviceAddresses,
    );

    test('separates originless, trusted and untrusted requests', () async {
      final origins = source();
      expect(await origins.classify(null), BrowserOriginVerdict.originless);
      expect(await origins.classify(''), BrowserOriginVerdict.untrusted);

      for (final origin in [
        'http://localhost:25707',
        'http://127.0.0.1:25707',
        'http://[::1]:25707',
        'http://localhost:8080',
        'HTTP://LOCALHOST:25707',
      ]) {
        expect(
          await origins.classify(origin, connectionInfo: _loopbackPeer),
          BrowserOriginVerdict.trusted,
          reason: origin,
        );
      }

      for (final origin in [
        'http://192.168.12.64:25707',
        'http://192.168.12.64:8080',
      ]) {
        expect(
          await origins.classify(origin),
          BrowserOriginVerdict.trusted,
          reason: '$origin (a numeric device origin needs no peer)',
        );
      }

      for (final origin in [
        'null',
        'https://localhost:25707',
        'http://evil.example:25707',
        'http://192.168.12.65:25707',
        'http://localhost:3000',
        'http://localhost',
        'http://localhost:25707/',
        'http://user@localhost:25707',
        'http://localhost:25707, http://evil.example',
        'http://decaid.local:25707',
        'ws://localhost:25707',
      ]) {
        expect(
          await origins.classify(origin),
          BrowserOriginVerdict.untrusted,
          reason: origin,
        );
      }
    });

    test(
      'reads the live listener ports and addresses on every request',
      () async {
        var api = 8080;
        var page = <int>{25707};
        var addresses = <String>{'192.168.12.64'};
        final origins = ExtensionManagementBrowserOrigins(
          apiListenerPort: () => api,
          pagePorts: () => page,
          deviceAddresses: () async => addresses,
        );

        expect(
          await origins.classify(
            'http://localhost:9001',
            connectionInfo: _loopbackPeer,
          ),
          BrowserOriginVerdict.untrusted,
        );
        api = 9001;
        expect(
          await origins.classify(
            'http://localhost:9001',
            connectionInfo: _loopbackPeer,
          ),
          BrowserOriginVerdict.trusted,
        );

        page = {};
        expect(
          await origins.classify(
            'http://localhost:25707',
            connectionInfo: _loopbackPeer,
          ),
          BrowserOriginVerdict.untrusted,
        );
        page = {25707};
        expect(
          await origins.classify(
            'http://localhost:25707',
            connectionInfo: _loopbackPeer,
          ),
          BrowserOriginVerdict.trusted,
        );

        addresses = {'192.168.12.65'};
        expect(
          await origins.classify('http://192.168.12.64:25707'),
          BrowserOriginVerdict.untrusted,
        );
        expect(
          await origins.classify('http://192.168.12.65:25707'),
          BrowserOriginVerdict.trusted,
        );
      },
    );

    test('only an http origin literally on this device is trusted', () async {
      final origins = source(apiListenerPort: null);
      expect(
        await origins.classify(
          'http://localhost:8080',
          connectionInfo: _loopbackPeer,
        ),
        BrowserOriginVerdict.untrusted,
        reason: 'no listener port is known yet',
      );
      expect(
        await origins.classify(
          'http://localhost:25707',
          connectionInfo: _loopbackPeer,
        ),
        BrowserOriginVerdict.trusted,
      );
    });

    test(
      'a loopback origin without socket peer provenance fails closed',
      () async {
        final origins = source();
        for (final origin in [
          'http://localhost:25707',
          'http://localhost:8080',
          'http://127.0.0.1:25707',
          'http://[::1]:8080',
          'HTTP://LOCALHOST:25707',
        ]) {
          expect(
            await origins.classify(origin),
            BrowserOriginVerdict.untrusted,
            reason: origin,
          );
        }
        expect(
          await origins.classify('http://192.168.12.64:25707'),
          BrowserOriginVerdict.trusted,
          reason: 'a numeric device origin does not need peer provenance',
        );
      },
    );

    test('a loopback socket peer admits every loopback origin form', () async {
      var reads = 0;
      final origins = ExtensionManagementBrowserOrigins(
        apiListenerPort: () => 8080,
        pagePorts: () => const {25707},
        deviceAddresses: () async {
          reads++;
          throw StateError('the interface list must not be read');
        },
      );
      for (final peer in const ['127.0.0.1', '127.9.9.9', '::1']) {
        for (final origin in const [
          'http://localhost:25707',
          'http://127.0.0.1:8080',
          'http://[::1]:25707',
        ]) {
          expect(
            await origins.classify(origin, connectionInfo: _SocketPeer(peer)),
            BrowserOriginVerdict.trusted,
            reason: '$origin via $peer',
          );
        }
      }
      expect(reads, 0);
    });

    test('a non-loopback socket peer is matched against the fresh device '
        'addresses', () async {
      var addresses = {'192.168.12.64', 'fd00::64'};
      final origins = ExtensionManagementBrowserOrigins(
        apiListenerPort: () => 8080,
        pagePorts: () => const {25707},
        deviceAddresses: () async => addresses,
      );
      const origin = 'http://localhost:25707';

      for (final peer in const ['192.168.12.64', 'fd00::64']) {
        expect(
          await origins.classify(origin, connectionInfo: _SocketPeer(peer)),
          BrowserOriginVerdict.trusted,
          reason: peer,
        );
      }
      expect(
        await origins.classify(
          origin,
          connectionInfo: _SocketPeer('192.168.12.100'),
        ),
        BrowserOriginVerdict.untrusted,
      );
      expect(
        await origins.classify(origin, connectionInfo: _UnreadableSocketPeer()),
        BrowserOriginVerdict.untrusted,
      );

      addresses = {'192.168.12.100'};
      expect(
        await origins.classify(
          origin,
          connectionInfo: _SocketPeer('192.168.12.64'),
        ),
        BrowserOriginVerdict.untrusted,
        reason: 'the previous address must not stay trusted',
      );
      expect(
        await origins.classify(
          origin,
          connectionInfo: _SocketPeer('192.168.12.100'),
        ),
        BrowserOriginVerdict.trusted,
      );
    });
  });

  group('browser origin guard', () {
    final origins = ExtensionManagementBrowserOrigins(
      apiListenerPort: () => 8080,
      pagePorts: () => const {25707},
      deviceAddresses: () async => const {'192.168.12.64'},
    );
    const trustedOrigin = 'http://localhost:25707';
    const untrustedOrigin = 'https://evil.example';
    const refusedError =
        'Extension management is not allowed from this browser origin';

    Handler guarded({bool protect = true, bool withGuard = true}) {
      var pipeline = const Pipeline();
      if (withGuard) {
        pipeline = pipeline.addMiddleware(
          extensionManagementBrowserOriginMiddleware(origins),
        );
      }
      return pipeline
          .addMiddleware(
            extensionManagementAuthMiddleware(
              tokens,
              requireExtensionManagementAuthorization: () async => protect,
            ),
          )
          .addHandler((request) {
            reached.add(request);
            return Response.ok('inner');
          });
    }

    Future<Response> request(
      String method,
      String path, {
      String? origin,
      String? authorization,
      Map<String, Object>? context,
      Map<String, String> headers = const {},
      Object? connectionInfo,
      Handler? through,
    }) async => (through ?? guarded())(
      Request(
        method,
        Uri.parse('http://localhost$path'),
        headers: {
          'host': 'localhost',
          'authorization': ?authorization,
          'origin': ?origin,
          ...headers,
        },
        context: {_connectionInfoKey: ?connectionInfo, ...?context},
      ),
    );

    Future<String> errorOf(Response response) async =>
        (jsonDecode(await response.readAsString()) as Map)['error'] as String;

    for (final protect in [true, false]) {
      Handler protectedPipeline() => guarded(protect: protect);

      test('an untrusted origin is refused on every management route '
          '(${protect ? 'protected' : 'compatibility'})', () async {
        for (final route in extensionManagementRoutes) {
          reached.clear();
          final response = await request(
            route.method,
            _concretePath(route),
            origin: untrustedOrigin,
            authorization: 'Bearer $_managerToken',
            through: protectedPipeline(),
          );
          expect(response.statusCode, 403, reason: '$route');
          expect(await errorOf(response), refusedError, reason: '$route');
          expect(
            response.headers['access-control-allow-origin'],
            isNull,
            reason: '$route',
          );
          expect(reached, isEmpty, reason: '$route');
        }
      });

      test('an untrusted preflight is refused without preflight headers '
          '(${protect ? 'protected' : 'compatibility'})', () async {
        for (final route in extensionManagementRoutes) {
          final response = await request(
            'OPTIONS',
            _concretePath(route),
            origin: untrustedOrigin,
            headers: {'access-control-request-method': route.method},
            through: protectedPipeline(),
          );
          expect(response.statusCode, 403, reason: '$route');
          for (final name in [
            'access-control-allow-origin',
            'access-control-allow-methods',
            'access-control-allow-headers',
            'access-control-allow-credentials',
          ]) {
            expect(response.headers[name], isNull, reason: '$route $name');
          }
          expect(reached, isEmpty, reason: '$route');
        }
      });

      test('a trusted origin keeps the credential decision '
          '(${protect ? 'protected' : 'compatibility'})', () async {
        reached.clear();
        expect(
          (await request(
            'POST',
            '/api/v1/plugins/example.reaplugin/update/approve',
            origin: trustedOrigin,
            connectionInfo: _loopbackPeer,
            through: protectedPipeline(),
          )).statusCode,
          protect ? 401 : 200,
        );
        expect(
          (await request(
            'POST',
            '/api/v1/plugins/example.reaplugin/update/approve',
            origin: trustedOrigin,
            authorization: 'Bearer $_managerToken',
            connectionInfo: _loopbackPeer,
            through: protectedPipeline(),
          )).statusCode,
          200,
        );
        expect(reached, hasLength(protect ? 1 : 2));
      });

      test('an originless request is unchanged '
          '(${protect ? 'protected' : 'compatibility'})', () async {
        reached.clear();
        expect(
          (await request(
            'POST',
            '/api/v1/plugins/example.reaplugin/enable',
            through: protectedPipeline(),
          )).statusCode,
          protect ? 401 : 200,
        );
      });
    }

    test('a loopback origin without socket peer provenance is refused on every '
        'management route in both modes', () async {
      for (final protect in [true, false]) {
        for (final authorization in <String?>[null, 'Bearer $_managerToken']) {
          for (final route in extensionManagementRoutes) {
            reached.clear();
            final response = await request(
              route.method,
              _concretePath(route),
              origin: trustedOrigin,
              authorization: authorization,
              connectionInfo: null,
              through: guarded(protect: protect),
            );
            expect(
              response.statusCode,
              403,
              reason: '$route protect=$protect $authorization',
            );
            expect(
              await errorOf(response),
              refusedError,
              reason: '$route protect=$protect',
            );
            expect(
              response.headers['access-control-allow-origin'],
              isNull,
              reason: '$route protect=$protect',
            );
            expect(reached, isEmpty, reason: '$route protect=$protect');
          }
        }
      }
    });

    test('a loopback origin is refused without socket peer provenance even '
        'with an active grant', () async {
      for (final protect in [true, false]) {
        reached.clear();
        final response = await request(
          'POST',
          '/api/v1/webui/server/stop',
          origin: trustedOrigin,
          connectionInfo: null,
          context: {extensionManagementGrantContextKey: _Grant()},
          through: guarded(protect: protect),
        );
        expect(response.statusCode, 403, reason: 'protect=$protect');
        expect(await errorOf(response), refusedError);
        expect(reached, isEmpty, reason: 'protect=$protect');
      }
    });

    test('an unreadable or wrong-typed socket peer cannot admit a loopback '
        'origin', () async {
      for (final peer in <Object>[
        _UnreadableSocketPeer(),
        '127.0.0.1',
        const <String, String>{'remoteAddress': '127.0.0.1'},
        Object(),
      ]) {
        reached.clear();
        final response = await request(
          'POST',
          '/api/v1/plugins/example.reaplugin/enable',
          origin: trustedOrigin,
          connectionInfo: peer,
          through: guarded(protect: false),
        );
        expect(response.statusCode, 403, reason: '$peer');
        expect(reached, isEmpty, reason: '$peer');
      }
    });

    test('forwarded, host and referer headers never stand in for socket '
        'peer provenance', () async {
      for (final protect in [true, false]) {
        reached.clear();
        final response = await request(
          'POST',
          '/api/v1/plugins/example.reaplugin/enable',
          origin: trustedOrigin,
          authorization: 'Bearer $_managerToken',
          connectionInfo: _SocketPeer('192.168.12.100'),
          headers: {
            'host': 'localhost:25707',
            'referer': 'http://localhost:25707/',
            'x-forwarded-for': '127.0.0.1',
            'x-real-ip': '127.0.0.1',
            'forwarded': 'for=127.0.0.1;host=localhost;proto=http',
            'x-forwarded-host': 'localhost:25707',
          },
          through: guarded(protect: protect),
        );
        expect(response.statusCode, 403, reason: 'protect=$protect');
        expect(reached, isEmpty, reason: 'protect=$protect');
      }
    });

    test(
      'a loopback socket peer admits a loopback origin in both modes',
      () async {
        for (final protect in [true, false]) {
          for (final origin in const [
            'http://localhost:25707',
            'http://127.0.0.1:25707',
            'http://[::1]:25707',
            'http://localhost:8080',
          ]) {
            reached.clear();
            final response = await request(
              'POST',
              '/api/v1/plugins/example.reaplugin/enable',
              origin: origin,
              authorization: 'Bearer $_managerToken',
              connectionInfo: _loopbackPeer,
              through: guarded(protect: protect),
            );
            expect(
              response.statusCode,
              200,
              reason: '$origin protect=$protect',
            );
            expect(reached, hasLength(1), reason: '$origin protect=$protect');
          }
        }
      },
    );

    test('an untrusted preflight for a read-only method on a shared path is '
        'not a management mutation', () async {
      for (final path in const [
        '/api/v1/plugins',
        '/api/v1/plugins/example.reaplugin/settings',
        '/api/v1/webui/skins',
        '/api/v1/webui/skins/default',
        '/api/v1/webui/skins/streamline',
        '/api/v1/webui/server/status',
        '/api/v1/settings',
      ]) {
        for (final method in const ['GET', 'HEAD', 'get']) {
          reached.clear();
          final response = await request(
            'OPTIONS',
            path,
            origin: untrustedOrigin,
            headers: {'access-control-request-method': method},
            through: guarded(protect: false),
          );
          expect(response.statusCode, 200, reason: '$method $path');
          expect(reached, hasLength(1), reason: '$method $path');
        }
      }
    });

    test('an untrusted preflight for an unlisted method keeps the general '
        'path', () async {
      for (final (method, path) in const [
        ('PATCH', '/api/v1/plugins/example.reaplugin/enable'),
        ('GET', '/api/v1/plugins/example.reaplugin/enable'),
        ('TRACE', '/api/v1/data/import'),
      ]) {
        reached.clear();
        final response = await request(
          'OPTIONS',
          path,
          origin: untrustedOrigin,
          headers: {'access-control-request-method': method},
        );
        expect(response.statusCode, 200, reason: '$method $path');
        expect(reached, hasLength(1), reason: '$method $path');
      }
    });

    test(
      'an untrusted preflight for a mutation on a shared path is refused',
      () async {
        for (final origin in const [
          untrustedOrigin,
          'null',
          'http://unknown.example:9999',
        ]) {
          for (final (method, path) in const [
            ('POST', '/api/v1/plugins/example.reaplugin/settings'),
            ('PUT', '/api/v1/webui/skins/default'),
            ('DELETE', '/api/v1/webui/skins/streamline'),
            ('DELETE', '/api/v1/plugins/example.reaplugin'),
            ('POST', '/api/v1/settings'),
            ('POST', '/api/v1/data/import'),
            ('POST', '/api/v1/data/sync'),
          ]) {
            reached.clear();
            final response = await request(
              'OPTIONS',
              path,
              origin: origin,
              headers: {'access-control-request-method': method},
            );
            expect(response.statusCode, 403, reason: '$method $path $origin');
            expect(await errorOf(response), refusedError, reason: path);
            expect(
              response.headers['access-control-allow-origin'],
              isNull,
              reason: '$method $path $origin',
            );
            expect(reached, isEmpty, reason: '$method $path $origin');
          }
        }
      },
    );

    test(
      'a missing or malformed requested method stays conservative',
      () async {
        for (final value in const <String?>[
          null,
          '',
          'GET, POST',
          ' POST',
          'POST ',
          'POST GET',
          'P@ST',
        ]) {
          for (final path in const [
            '/api/v1/plugins/example.reaplugin/settings',
            '/api/v1/webui/skins/default',
            '/api/v1/settings',
          ]) {
            reached.clear();
            final response = await request(
              'OPTIONS',
              path,
              origin: untrustedOrigin,
              headers: {'access-control-request-method': ?value},
            );
            expect(response.statusCode, 403, reason: '$value $path');
            expect(reached, isEmpty, reason: '$value $path');
          }
        }

        for (final path in const [
          '/api/v1/plugins/example.reaplugin/echo',
          '/api/v1/machine/state/espresso',
        ]) {
          reached.clear();
          final response = await request(
            'OPTIONS',
            path,
            origin: untrustedOrigin,
          );
          expect(response.statusCode, 200, reason: path);
          expect(reached, hasLength(1), reason: path);
        }
      },
    );

    test('an untrusted origin is refused even with an active grant', () async {
      reached.clear();
      final response = await request(
        'POST',
        '/api/v1/webui/server/stop',
        origin: untrustedOrigin,
        context: {extensionManagementGrantContextKey: _Grant()},
      );
      expect(response.statusCode, 403);
      expect(await errorOf(response), refusedError);
      expect(reached, isEmpty);
    });

    test('an untrusted origin keeps unrelated routes reachable', () async {
      for (final (method, path) in [
        ('GET', '/api/v1/plugins'),
        ('POST', '/api/v1/settings'),
        ('POST', '/api/v1/data/import'),
        ('POST', '/api/v1/data/sync'),
        ('GET', '/api/v1/machine/state/espresso'),
      ]) {
        reached.clear();
        final response = await request(
          method,
          path,
          origin: untrustedOrigin,
          through: guarded(protect: false),
        );
        expect(response.statusCode, 200, reason: '$method $path');
        expect(reached, hasLength(1), reason: '$method $path');
      }
    });

    test(
      'the handler check refuses only a recorded untrusted origin',
      () async {
        late Request seen;
        final handler = const Pipeline()
            .addMiddleware(extensionManagementBrowserOriginMiddleware(origins))
            .addHandler((request) async {
              seen = request;
              return requireTrustedBrowserOrigin(request, action: 'test') ??
                  Response.ok('inner');
            });

        await handler(
          Request(
            'POST',
            Uri.parse('http://localhost/api/v1/settings'),
            headers: const {'origin': untrustedOrigin},
          ),
        );
        final refused = requireTrustedBrowserOrigin(seen, action: 'test');
        expect(refused?.statusCode, 403);
        expect(isUntrustedBrowserOrigin(seen), isTrue);

        await handler(
          Request(
            'POST',
            Uri.parse('http://localhost/api/v1/settings'),
            headers: const {'origin': trustedOrigin},
            context: {_connectionInfoKey: _loopbackPeer},
          ),
        );
        expect(requireTrustedBrowserOrigin(seen, action: 'test'), isNull);
        expect(isUntrustedBrowserOrigin(seen), isFalse);

        await handler(
          Request('POST', Uri.parse('http://localhost/api/v1/settings')),
        );
        expect(requireTrustedBrowserOrigin(seen, action: 'test'), isNull);
        expect(isUntrustedBrowserOrigin(seen), isFalse);

        final unguarded = Request(
          'POST',
          Uri.parse('http://localhost/api/v1/settings'),
          headers: const {'origin': untrustedOrigin},
        );
        expect(requireTrustedBrowserOrigin(unguarded, action: 'test'), isNull);
        expect(isUntrustedBrowserOrigin(unguarded), isFalse);
      },
    );
  });

  group('browser origin address reads', () {
    late int reads;
    late Set<String> addresses;
    late Completer<void> readStarted;
    Completer<void>? barrier;
    var enumerationFails = false;

    ExtensionManagementBrowserOrigins origins() =>
        ExtensionManagementBrowserOrigins(
          apiListenerPort: () => 8080,
          pagePorts: () => const {25707},
          deviceAddresses: () async {
            reads++;
            if (!readStarted.isCompleted) readStarted.complete();
            final blocked = barrier;
            if (blocked != null) await blocked.future;
            if (enumerationFails) {
              throw StateError('interface enumeration failed');
            }
            return addresses;
          },
        );

    Handler guarded({bool protect = false}) => const Pipeline()
        .addMiddleware(extensionManagementBrowserOriginMiddleware(origins()))
        .addMiddleware(
          extensionManagementAuthMiddleware(
            tokens,
            requireExtensionManagementAuthorization: () async => protect,
          ),
        )
        .addHandler((request) {
          reached.add(request);
          return Response.ok('inner');
        });

    Future<Response> send(
      String method,
      String path, {
      String? origin,
      Map<String, String> headers = const {},
      Object? connectionInfo = const _NoPeer(),
    }) async {
      final context = connectionInfo == null || connectionInfo is _NoPeer
          ? null
          : <String, Object>{_connectionInfoKey: connectionInfo};
      return guarded()(
        Request(
          method,
          Uri.parse('http://localhost$path'),
          headers: {'host': 'localhost', 'origin': ?origin, ...headers},
          context: context,
        ),
      );
    }

    setUp(() {
      reads = 0;
      addresses = {'192.168.12.64'};
      readStarted = Completer<void>();
      barrier = null;
      enumerationFails = false;
    });

    test('an originless request never reads device addresses', () async {
      for (final (method, path) in const [
        ('GET', '/api/v1/plugins'),
        ('GET', '/api/v1/machine/state/espresso'),
        ('POST', '/api/v1/plugins/example.reaplugin/enable'),
        ('POST', '/api/v1/settings'),
      ]) {
        reached.clear();
        final response = await send(method, path);
        expect(response.statusCode, 200, reason: '$method $path');
        expect(reached, hasLength(1), reason: '$method $path');
      }
      expect(reads, 0);
    });

    test('unrelated, read-only and plugin traffic never reads device '
        'addresses', () async {
      const origin = 'http://192.168.12.64:25707';
      for (final (method, path) in const [
        ('GET', '/api/v1/plugins'),
        ('GET', '/api/v1/plugins/example.reaplugin/settings'),
        ('GET', '/api/v1/webui/skins'),
        ('GET', '/api/v1/webui/server/status'),
        ('GET', '/api/v1/plugins/echo.fixture/echo'),
        ('PUT', '/api/v1/machine/state/espresso'),
        ('GET', '/api/v1/account/proxy/support/api/sn'),
      ]) {
        reached.clear();
        final response = await send(method, path, origin: origin);
        expect(response.statusCode, 200, reason: '$method $path');
        expect(reached, hasLength(1), reason: '$method $path');
      }
      expect(reads, 0);
    });

    test(
      'unrelated traffic completes while the address read is blocked',
      () async {
        barrier = Completer<void>();
        final mutation = send(
          'POST',
          '/api/v1/plugins/install',
          origin: 'http://192.168.12.64:25707',
        );
        await readStarted.future;

        final unrelated = await send(
          'GET',
          '/api/v1/machine/state/espresso',
          origin: 'http://192.168.12.64:25707',
        );
        expect(unrelated.statusCode, 200);
        expect(reached, hasLength(1));
        expect(reads, 1);

        barrier!.complete();
        expect((await mutation).statusCode, 200);
        expect(reached, hasLength(2));
        expect(reads, 1);
      },
    );

    test('a management mutation reads the interfaces once', () async {
      final response = await send(
        'POST',
        '/api/v1/plugins/install',
        origin: 'http://192.168.12.64:25707',
      );

      expect(response.statusCode, 200);
      expect(reached, hasLength(1));
      expect(reads, 1);
    });

    test('a body-sensitive settings write reads the interfaces once', () async {
      final response = await send(
        'POST',
        '/api/v1/settings',
        origin: 'http://192.168.12.64:25707',
      );

      expect(response.statusCode, 200);
      expect(reads, 1);
    });

    test('a guarded preflight reads the interfaces once', () async {
      final response = await send(
        'OPTIONS',
        '/api/v1/plugins/install',
        origin: 'http://192.168.12.64:25707',
        headers: const {'access-control-request-method': 'POST'},
      );

      expect(response.statusCode, 200);
      expect(reads, 1);
    });

    test('a loopback socket peer never reads device addresses', () async {
      enumerationFails = true;
      for (final address in const ['127.0.0.1', '127.0.4.1', '::1']) {
        reached.clear();
        final response = await send(
          'POST',
          '/api/v1/plugins/install',
          origin: 'http://localhost:25707',
          connectionInfo: _SocketPeer(address),
        );
        expect(response.statusCode, 200, reason: address);
        expect(reached, hasLength(1), reason: address);
      }
      expect(reads, 0);
    });

    test('a loopback origin without socket peer provenance fails closed '
        'without reading device addresses', () async {
      final response = await send(
        'POST',
        '/api/v1/plugins/install',
        origin: 'http://localhost:25707',
      );
      expect(response.statusCode, 403);
      expect(reached, isEmpty);
      expect(reads, 0);
    });

    test('a loopback origin from a non-loopback peer is matched against the '
        'live device addresses', () async {
      const origin = 'http://localhost:25707';
      final peer = _SocketPeer('192.168.12.100');

      final refused = await send(
        'POST',
        '/api/v1/plugins/install',
        origin: origin,
        connectionInfo: peer,
      );
      expect(refused.statusCode, 403);
      expect(reached, isEmpty);
      expect(
        reads,
        1,
        reason: 'the peer is matched, not trusted as a LAN peer',
      );

      addresses = {'192.168.12.100'};
      final admitted = await send(
        'POST',
        '/api/v1/plugins/install',
        origin: origin,
        connectionInfo: peer,
      );
      expect(admitted.statusCode, 200);
      expect(reached, hasLength(1));
      expect(reads, 2);

      addresses = {'192.168.12.64'};
      final retired = await send(
        'POST',
        '/api/v1/plugins/install',
        origin: origin,
        connectionInfo: peer,
      );
      expect(retired.statusCode, 403);
      expect(reached, hasLength(1));
      expect(reads, 3);
    });

    test('a loopback origin is refused from a non-loopback peer while the '
        'address read fails', () async {
      enumerationFails = true;
      final response = await send(
        'POST',
        '/api/v1/plugins/install',
        origin: 'http://localhost:25707',
        connectionInfo: _SocketPeer('192.168.12.64'),
      );
      expect(response.statusCode, 403);
      expect(reached, isEmpty);
      expect(reads, 1);
    });

    test('an unrelated preflight never reads device addresses', () async {
      final response = await send(
        'OPTIONS',
        '/api/v1/machine/state/espresso',
        origin: 'http://192.168.12.64:25707',
      );

      expect(response.statusCode, 200);
      expect(reads, 0);
    });

    test('an untrusted port is refused without reading addresses', () async {
      final response = await send(
        'POST',
        '/api/v1/plugins/install',
        origin: 'http://192.168.12.64:1234',
      );

      expect(response.statusCode, 403);
      expect(reached, isEmpty);
      expect(reads, 0);
    });

    test('an enumeration failure refuses numeric origins but keeps loopback '
        'and originless requests', () async {
      enumerationFails = true;

      expect(
        (await send(
          'POST',
          '/api/v1/plugins/example.reaplugin/enable',
          origin: 'http://192.168.12.64:25707',
        )).statusCode,
        403,
      );
      expect(reached, isEmpty);

      expect(
        (await send(
          'POST',
          '/api/v1/plugins/example.reaplugin/enable',
          origin: 'http://localhost:25707',
          connectionInfo: _loopbackPeer,
        )).statusCode,
        200,
      );
      expect(reached, hasLength(1));

      reached.clear();
      expect(
        (await send(
          'POST',
          '/api/v1/plugins/example.reaplugin/enable',
        )).statusCode,
        200,
      );
      expect(reached, hasLength(1));
    });
  });
}
