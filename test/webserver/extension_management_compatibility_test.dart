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
  _ConnectionInfo(this.remoteAddress);

  @override
  final InternetAddress remoteAddress;

  @override
  final int localPort = 8080;

  @override
  final int remotePort = 51000;
}

const _managerToken = 'manager-token';
const _staleToken = 'stale-manager-token';
const _accountToken = 'account-token';
const _skinToken = 'skin-token';

String _concretePath(ExtensionManagementRoute route) =>
    route.path.replaceAll('<id>', 'example.reaplugin');

void main() {
  final loopback4 = InternetAddress('127.0.0.1');
  final lanPeer = InternetAddress('192.168.1.50');

  late ProxyTokenService tokens;
  late List<Request> reached;
  late Handler handler;

  Handler pipeline({
    ProxyTokenService? withTokens,
    Future<bool> Function()? requireExtensionManagementAuthorization,
  }) {
    return const Pipeline()
        .addMiddleware(
          extensionManagementAuthMiddleware(
            withTokens,
            requireExtensionManagementAuthorization:
                requireExtensionManagementAuthorization,
          ),
        )
        .addHandler((request) {
          reached.add(request);
          return Response.ok('inner');
        });
  }

  Future<Response> send(
    String method,
    String path, {
    String? authorization,
    InternetAddress? peer,
    String host = 'localhost:8080',
    Map<String, Object>? context,
    Handler? through,
  }) async {
    return (through ?? handler)(
      Request(
        method,
        Uri.parse('http://$host$path'),
        headers: {'host': host, 'authorization': ?authorization},
        context: {
          if (peer != null) 'shelf.io.connection_info': _ConnectionInfo(peer),
          ...?context,
        },
      ),
    );
  }

  setUp(() {
    tokens = ProxyTokenService(skinToken: _skinToken)
      ..registerToken(
        _managerToken,
        const ProxyCaller(
          id: 'api:manager',
          scopes: {ProxyTokenService.scopeExtensionsManage},
        ),
      )
      ..registerToken(
        _staleToken,
        const ProxyCaller(
          id: 'api:stale',
          scopes: {ProxyTokenService.scopeExtensionsManage},
        ),
      )
      ..registerToken(
        _accountToken,
        const ProxyCaller(
          id: 'api:account',
          scopes: {ProxyTokenService.scopeAccountProxy},
        ),
      )
      ..revokeToken(_staleToken);
    reached = [];
    handler = pipeline(
      withTokens: tokens,
      requireExtensionManagementAuthorization: () async => false,
    );
  });

  group('default mode admits every protected route', () {
    for (final route in extensionManagementRoutes) {
      final path = _concretePath(route);

      test('$route admits tokenless loopback and LAN callers', () async {
        for (final (label, peer, host) in [
          ('loopback', loopback4, 'localhost:8080'),
          ('LAN peer', lanPeer, '192.168.1.50:8080'),
        ]) {
          reached.clear();
          final response = await send(
            route.method,
            path,
            peer: peer,
            host: host,
          );
          expect(
            response.statusCode,
            200,
            reason: '$route tokenless from $label',
          );
          expect(
            reached,
            hasLength(1),
            reason: '$route tokenless from $label reached no handler',
          );
        }
      });
    }
  });

  group('default mode is not defeated by a presented credential', () {
    for (final route in extensionManagementRoutes) {
      final path = _concretePath(route);

      test('$route admits a stale, unknown or wrong-scope caller', () async {
        for (final (label, authorization) in [
          ('revoked manager token', 'Bearer $_staleToken'),
          ('unknown token', 'Bearer not-a-token'),
          ('malformed header', 'Basic abc'),
          ('account token', 'Bearer $_accountToken'),
          ('skin token', 'Bearer $_skinToken'),
        ]) {
          reached.clear();
          final response = await send(
            route.method,
            path,
            authorization: authorization,
            peer: loopback4,
          );
          expect(response.statusCode, 200, reason: '$route via $label');
          expect(
            reached,
            hasLength(1),
            reason: '$route via $label reached no handler',
          );
        }
      });
    }
  });

  group('default mode agrees with body-dependent handler checks', () {
    for (final (method, path) in [
      ('POST', '/api/v1/settings'),
      ('POST', '/api/v1/data/import'),
      ('POST', '/api/v1/data/sync'),
    ]) {
      test('$method $path decides as the handler checks', () async {
        final response = await send(method, path, peer: loopback4);
        expect(response.statusCode, 200);
        final request = reached.single;
        expect(await mayManageExtensions(request), isTrue);
        expect(
          await requireExtensionManagement(request, action: 'test'),
          isNull,
        );
      });
    }

    test('a wrong-scope caller decides as the handler checks', () async {
      await send(
        'POST',
        '/api/v1/settings',
        authorization: 'Bearer $_accountToken',
        peer: loopback4,
      );
      final request = reached.single;
      expect(await mayManageExtensions(request), isTrue);
      expect(await requireExtensionManagement(request, action: 'test'), isNull);
    });
  });

  group('manual update checks are not conditioned on another setting', () {
    const updates = ['/api/v1/plugins/update', '/api/v1/webui/skins/update'];

    for (final path in updates) {
      test('$path works without a credential or a settings read', () async {
        final response = await send('POST', path, peer: loopback4);
        expect(response.statusCode, 200);
        expect(reached, hasLength(1));
      });
    }
  });

  group('read-only, plugin-defined and unrelated routes stay open', () {
    for (final (method, path) in [
      ('GET', '/api/v1/plugins'),
      ('GET', '/api/v1/plugins/example.reaplugin/settings'),
      ('GET', '/api/v1/webui/skins'),
      ('GET', '/api/v1/webui/skins/default'),
      ('GET', '/api/v1/webui/skins/streamline'),
      ('GET', '/api/v1/webui/server/status'),
      ('POST', '/api/v1/plugins/example.reaplugin/status'),
      ('POST', '/api/v1/machine/state/espresso'),
    ]) {
      test('$method $path stays open', () async {
        final response = await send(method, path, peer: loopback4);
        expect(response.statusCode, 200);
        expect(reached, hasLength(1));
      });
    }

    test('OPTIONS on a protected route stays open', () async {
      final response = await send(
        'OPTIONS',
        '/api/v1/plugins/example.reaplugin/enable',
        peer: loopback4,
      );
      expect(response.statusCode, 200);
    });
  });

  group('credential decisions that must survive both modes', () {
    test('a manager bearer is admitted on every protected route', () async {
      for (final route in extensionManagementRoutes) {
        reached.clear();
        final response = await send(
          route.method,
          _concretePath(route),
          authorization: 'Bearer $_managerToken',
          peer: lanPeer,
          host: '192.168.1.50:8080',
        );
        expect(response.statusCode, 200, reason: '$route');
        expect(reached, hasLength(1), reason: '$route reached no handler');
      }
    });

    test('an active in-process grant is admitted', () async {
      final response = await send(
        'POST',
        '/api/v1/webui/server/stop',
        peer: lanPeer,
        host: '192.168.1.50:8080',
        context: {extensionManagementGrantContextKey: _Grant()},
      );
      expect(response.statusCode, 200);
    });

    test('an ended grant keeps its denial', () async {
      final response = await send(
        'POST',
        '/api/v1/webui/server/stop',
        peer: loopback4,
        context: {
          extensionManagementGrantContextKey: _Grant()..isActive = false,
        },
      );
      expect(response.statusCode, 401);
      expect(reached, isEmpty);
    });
  });
}
