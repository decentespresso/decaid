import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/plugins/plugin_device_surface_authority.dart';
import 'package:reaprime/src/plugins/plugin_loader_service.dart';
import 'package:reaprime/src/plugins/plugin_manager.dart';
import 'package:reaprime/src/plugins/plugin_manifest.dart';
import 'package:reaprime/src/services/webserver/opaque_path_component.dart';
import 'package:reaprime/src/services/webserver_service.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_plus/shelf_plus.dart';

import 'plugin_test_helpers.dart';

class _FakePluginLoaderService extends Fake implements PluginLoaderService {}

Future<Uri> _serveSurface(String pluginId, String endpoint) async {
  const socketEndpoint = 'device%2Fupdates';
  final manifest = PluginManifest.fromJson({
    'id': pluginId,
    'name': 'Surface test',
    'author': 'Test',
    'description': 'Test',
    'version': '1.0.0',
    'apiVersion': 1,
    'permissions': ['api', 'emit'],
    'api': [
      {'id': endpoint, 'type': 'http', 'data': <String, dynamic>{}},
      {'id': socketEndpoint, 'type': 'websocket', 'data': <String, dynamic>{}},
    ],
    'drivers': [
      {
        'id': 'test-driver',
        'type': 'sensor',
        'surfaces': [
          {'id': 'settings', 'role': 'settings', 'endpoint': endpoint},
        ],
      },
    ],
  });
  final manager = PluginManager(kvStore: FakeKeyValueStoreService());
  addTearDown(manager.dispose);
  await manager.loadPlugin(
    id: pluginId,
    manifest: manifest,
    settings: {},
    jsCode:
        '''
      function createPlugin(host) {
        return {
          id: ${jsonEncode(pluginId)},
          handleHttpRequest: (request) => {
            host.emit('$socketEndpoint', {endpoint: request.endpoint});
            return {
              status: 200,
              headers: {'Content-Type': 'application/json'},
              body: JSON.stringify({endpoint: request.endpoint, query: request.query})
            };
          }
        };
      }
    ''',
  );
  final app = Router().plus;
  PluginsHandler(
    pluginManager: manager,
    pluginService: _FakePluginLoaderService(),
  ).addRoutes(app);
  final server = await shelf_io.serve(
    app.call,
    InternetAddress.loopbackIPv4,
    0,
  );
  addTearDown(() => server.close(force: true));
  final href = PluginDeviceSurfaceAuthority(
    pluginId: manifest.id,
    surfaces: manifest.drivers.single.surfaces,
  ).resolve('device%2F1').single['href']!;
  return Uri.parse('http://127.0.0.1:${server.port}').resolve(href);
}

Future<void> _expectSurfaceResponse(Uri href, String endpoint) async {
  final client = HttpClient();
  addTearDown(() => client.close(force: true));
  final request = await client.getUrl(href);
  final response = await request.close();
  final body = await utf8.decoder.bind(response).join();
  expect(response.statusCode, 200, reason: body);
  expect(jsonDecode(body), {
    'endpoint': endpoint,
    'query': {'ui': '1', 'deviceId': 'device%2F1'},
  });
}

void main() {
  for (final codeUnit in [0xD800, 0xDC00]) {
    test('surface rejects unpaired surrogate $codeUnit', () {
      expect(
        () => PluginDeviceSurface.fromJson({
          'id': 'settings',
          'role': 'settings',
          'endpoint': 'device${String.fromCharCode(codeUnit)}settings',
        }),
        throwsFormatException,
      );
    });
  }

  test('surface accepts a valid surrogate pair and href round-trips', () {
    const endpoint = 'device\u{1F600}settings';
    final surface = PluginDeviceSurface.fromJson({
      'id': 'settings',
      'role': 'settings',
      'endpoint': endpoint,
    });
    final href = PluginDeviceSurfaceAuthority(
      pluginId: 'surface.plugin',
      surfaces: [surface],
    ).resolve('device-1').single['href']!;
    expect(surface.endpoint, endpoint);
    expect(
      decodeOpaquePathComponent(Uri.parse(href).path.split('/').last),
      endpoint,
    );
  });

  for (final endpoint in [
    'device settings',
    'device%2Fsettings',
    'device%ZZsettings%',
    'device+#settings',
    '設定',
    'device\u{1F600}settings',
    'device\nsettings',
  ]) {
    test('generated surface href reaches HTTP handler for $endpoint', () async {
      final href = await _serveSurface('surface.plugin', endpoint);
      await _expectSurfaceResponse(href, endpoint);
    });
  }

  test('generated surface href decodes the plugin ID exactly once', () async {
    const endpoint = 'device settings';
    final href = await _serveSurface('surface%2Fplugin', endpoint);
    await _expectSurfaceResponse(href, endpoint);
  });

  test('WebSocket decodes plugin and endpoint IDs exactly once', () async {
    const endpoint = 'device settings';
    final href = await _serveSurface('surface%2Fplugin', endpoint);
    final socketUri = Uri(
      scheme: 'ws',
      host: href.host,
      port: href.port,
      pathSegments: [
        '',
        'ws',
        'v1',
        'plugins',
        'surface%2Fplugin',
        'device%2Fupdates',
      ],
    );
    final socket = await WebSocket.connect(socketUri.toString());
    addTearDown(socket.close);
    final message = socket.first.timeout(const Duration(seconds: 5));
    await _expectSurfaceResponse(href, endpoint);
    expect(jsonDecode(await message as String), {'endpoint': endpoint});
  });
}
