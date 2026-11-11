import 'dart:convert';

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
}
