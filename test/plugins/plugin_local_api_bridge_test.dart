import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/plugins/plugin_local_api_bridge.dart';
import 'package:reaprime/src/services/webserver/extension_management_auth.dart';
import 'package:shelf/shelf.dart';

class _Grant implements ExtensionManagementGrant {
  @override
  String get callerId => 'plugin:test.reaplugin';

  @override
  bool get isActive => true;
}

void main() {
  late PluginLocalApiBridge bridge;
  late List<Request> received;
  late List<String> bodies;
  late Response Function(Request) respond;
  final grant = _Grant();

  setUp(() {
    received = [];
    bodies = [];
    respond = (_) => Response.ok('ok');
    bridge = PluginLocalApiBridge(maxResponseBytes: 64)
      ..handler = (request) async {
        received.add(request);
        bodies.add(await request.readAsString());
        return respond(request);
      };
  });

  Future<Map<String, dynamic>> send(
    Object? path, {
    Object? method,
    Object? body,
    Object? contentType,
  }) => bridge.request(
    grant: grant,
    path: path,
    method: method,
    body: body,
    contentType: contentType,
  );

  test('refuses to dispatch without a handler', () async {
    bridge.handler = null;

    await expectLater(
      send('/api/v1/plugins'),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          'The local API is not available',
        ),
      ),
    );
  });

  test(
    'dispatches a local request carrying the grant in its context',
    () async {
      await send('/api/v1/plugins/a.reaplugin/settings?x=1&y=two');

      final request = received.single;
      expect(request.method, 'GET');
      expect(request.requestedUri.scheme, 'http');
      expect(request.requestedUri.host, 'localhost');
      expect(request.url.path, 'api/v1/plugins/a.reaplugin/settings');
      expect(request.url.queryParameters, {'x': '1', 'y': 'two'});
      expect(request.context[extensionManagementGrantContextKey], same(grant));
      expect(request.headers.keys, isNot(contains('authorization')));
    },
  );

  test('normalizes supported methods and rejects the rest', () async {
    await send('/api/v1/plugins', method: 'get');
    await send('/api/v1/plugins/a.reaplugin/enable', method: 'Post');
    await send('/api/v1/plugins/a.reaplugin/source', method: 'put');
    await send('/api/v1/plugins/a.reaplugin', method: 'DELETE');
    expect(received.map((r) => r.method), ['GET', 'POST', 'PUT', 'DELETE']);

    for (final method in [
      'OPTIONS',
      'HEAD',
      'PATCH',
      'TRACE',
      'CONNECT',
      'FETCH',
      '',
      42,
    ]) {
      await expectLater(
        send('/api/v1/plugins', method: method),
        throwsArgumentError,
        reason: '$method',
      );
    }
    expect(received, hasLength(4));
  });

  test('dispatches every plugin and skin management route', () async {
    final routes = [
      ...extensionManagementRoutes,
      ...extensionManagementReadRoutes,
    ];
    for (final route in routes) {
      await send(
        route.path.replaceAll('<id>', 'a.reaplugin'),
        method: route.method,
      );
    }

    expect(
      received.map((r) => '${r.method} /${r.url.path}'),
      routes.map(
        (route) =>
            '${route.method} ${route.path.replaceAll('<id>', 'a.reaplugin')}',
      ),
    );
  });

  test('rejects every route outside plugin and skin management', () async {
    for (final (method, path) in [
      ('PUT', '/api/v1/machine/state/espresso'),
      ('GET', '/api/v1/machine/state'),
      ('POST', '/api/v1/workflow'),
      ('GET', '/api/v1/settings'),
      ('PUT', '/api/v1/settings'),
      ('POST', '/api/v1/data/import'),
      ('GET', '/api/v1/data/export'),
      ('POST', '/api/v1/store/a.reaplugin/key'),
      ('GET', '/api/v1/account/proxy/api/v1/me'),
      ('GET', '/api/v1/plugins/a.reaplugin/status'),
      ('POST', '/api/v1/plugins/a.reaplugin/command'),
      ('GET', '/api/v1/plugins/a.reaplugin'),
      ('GET', '/api/v1/webui/skin-assets/a/index.html'),
      ('GET', '/api/v1/plugins/'),
      ('POST', '/api/v1/plugins/a.reaplugin/enable/'),
      ('POST', '/api/v1/plugins/a.reaplugin/ENABLE'),
      ('PUT', '/api/v1/plugins/a.reaplugin/../../machine/state/espresso'),
      ('PUT', '/api/v1/webui/skins/default/../../../machine/state/espresso'),
      ('DELETE', '/api/v1/webui/skins'),
      ('POST', '/api/v1/webui/skins/default'),
    ]) {
      await expectLater(
        send(path, method: method),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            contains('only the plugin and skin management routes'),
          ),
        ),
        reason: '$method $path',
      );
    }
    expect(received, isEmpty);
  });

  test('changes the extension settings and no other setting', () async {
    await send(
      '/api/v1/settings',
      method: 'POST',
      body: {'defaultSkinId': 'a', 'automaticUpdateCheck': true},
    );
    await send(
      '/api/v1/settings',
      method: 'POST',
      body:
          '{"webUiPath": "/skin", "automaticUpdateCheck": true, '
          '"automaticUpdateCheck": false}',
    );

    expect(bodies, [
      jsonEncode({'defaultSkinId': 'a', 'automaticUpdateCheck': true}),
      jsonEncode({'webUiPath': '/skin', 'automaticUpdateCheck': false}),
    ]);
    expect(received.map((r) => r.headers['content-type']), [
      'application/json',
      'application/json',
    ]);

    for (final body in <Object?>[
      {'defaultSkinId': 'a', 'gatewayMode': 'full'},
      {'logLevel': 'FINE'},
      '{"defaultSkinId": "a", "gatewayMode": "full"}',
      r'{"defaultSkinId": "a", "gatew\u0061yMode": "full"}',
      '{"defaultSkinId": "a"',
      <String, Object?>{},
      '{}',
      ['defaultSkinId'],
      '"defaultSkinId"',
      null,
    ]) {
      await expectLater(
        send('/api/v1/settings', method: 'POST', body: body),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            contains('localApi changes only these settings'),
          ),
        ),
        reason: '$body',
      );
    }
    expect(received, hasLength(2));
  });

  test('rejects anything but a path under /api/v1/', () async {
    for (final path in <Object?>[
      'http://localhost/api/v1/plugins',
      'http://127.0.0.1:8080/api/v1/plugins',
      '//127.0.0.1:8080/api/v1/plugins',
      'ws://localhost/api/v1/plugins',
      'http:/api/v1/plugins',
      'api/v1/x',
      '/api/v1',
      '/api/v10/x',
      '/api/v2/x',
      '/ws/v1/plugins/a/b',
      '/api/v1/../../ws/v1/plugins/a/b',
      '/api/v1/%2e%2e/x',
      '/api/v1/plugins#fragment',
      '',
      42,
      null,
      const ['/api/v1/plugins'],
      const {'path': '/api/v1/plugins'},
    ]) {
      await expectLater(send(path), throwsArgumentError, reason: '$path');
    }
    expect(received, isEmpty);
  });

  test('sends no content type without a body', () async {
    await send('/api/v1/plugins/a.reaplugin/enable', method: 'POST');

    expect(received.single.headers.keys, isNot(contains('content-type')));
    expect(bodies.single, isEmpty);
  });

  test('sends a string body verbatim and JSON-encodes others', () async {
    await send(
      '/api/v1/plugins/a.reaplugin/settings',
      method: 'POST',
      body: '{"raw": 1 }',
    );
    await send(
      '/api/v1/plugins/a.reaplugin/settings',
      method: 'POST',
      body: {
        'a': [1, 'b'],
      },
    );
    await send(
      '/api/v1/plugins/a.reaplugin/settings',
      method: 'POST',
      body: [1, 2],
    );
    await send('/api/v1/plugins/a.reaplugin/settings', method: 'POST', body: 7);
    await send(
      '/api/v1/plugins/a.reaplugin/settings',
      method: 'POST',
      body: 'a=1',
      contentType: 'text/plain',
    );
    await send(
      '/api/v1/plugins/a.reaplugin/settings',
      method: 'POST',
      body: 'x',
      contentType: 42,
    );

    expect(bodies, [
      '{"raw": 1 }',
      jsonEncode({
        'a': [1, 'b'],
      }),
      '[1,2]',
      '7',
      'a=1',
      'x',
    ]);
    expect(received.map((r) => r.headers['content-type']), [
      'application/json',
      'application/json',
      'application/json',
      'application/json',
      'text/plain',
      'application/json',
    ]);
  });

  test('returns status, headers and text body as data', () async {
    respond = (_) => Response(
      307,
      body: 'moved',
      headers: {'location': '/api/v1/elsewhere', 'x-extra': 'yes'},
    );

    final response = await send('/api/v1/plugins');

    expect(response.keys, unorderedEquals(['status', 'headers', 'body']));
    expect(response['status'], 307);
    expect(response['headers'], containsPair('location', '/api/v1/elsewhere'));
    expect(response['headers'], containsPair('x-extra', 'yes'));
    expect(response['body'], 'moved');
    expect(received, hasLength(1));
  });

  test('decodes malformed UTF-8 with replacement characters', () async {
    respond = (_) => Response.ok([0xFF, 0x41]);

    final response = await send('/api/v1/plugins');

    expect(response['body'], '�A');
  });

  test('accepts a response of exactly maxResponseBytes', () async {
    respond = (_) => Response.ok('x' * 64);

    final response = await send('/api/v1/plugins');

    expect(response['body'], hasLength(64));
  });

  test('rejects a response over maxResponseBytes', () async {
    respond = (_) => Response.ok('x' * 65);

    await expectLater(
      send('/api/v1/plugins'),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('exceeds 64 bytes'),
        ),
      ),
    );
  });

  test('propagates a handler failure', () async {
    respond = (_) => throw const FormatException('handler failed');

    await expectLater(send('/api/v1/plugins'), throwsFormatException);
  });
}
