import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/plugins/plugin_manifest.dart';

void main() {
  test('parses manifest permission wire values', () {
    final manifest = PluginManifest.fromJson(<String, dynamic>{
      'id': 'test.plugin',
      'name': 'Test Plugin',
      'author': 'Test',
      'description': 'Test',
      'version': '1.0.0',
      'apiVersion': 1,
      'permissions': [
        'log',
        'api',
        'events.machine',
        'events.shots',
        'proxy.decent_api',
        'proxy.decent_api.write',
        'network.websocket',
        'network.tcp',
        'network.tls',
      ],
      'settings': <String, dynamic>{},
      'api': <dynamic>[],
    });

    expect(manifest.permissions, contains(PluginPermissions.log));
    expect(manifest.permissions, contains(PluginPermissions.api));
    expect(manifest.permissions, contains(PluginPermissions.eventsMachine));
    expect(manifest.permissions, contains(PluginPermissions.eventsShots));
    expect(manifest.permissions, contains(PluginPermissions.proxyDecentApi));
    expect(
      manifest.permissions,
      contains(PluginPermissions.proxyDecentApiWrite),
    );
    expect(manifest.permissions, contains(PluginPermissions.networkWebsocket));
    expect(manifest.permissions, contains(PluginPermissions.networkTcp));
    expect(manifest.permissions, contains(PluginPermissions.networkTls));
  });

  test('rejects unknown manifest permissions', () {
    expect(
      () => PluginManifest.fromJson(<String, dynamic>{
        'id': 'test.plugin',
        'name': 'Test Plugin',
        'author': 'Test',
        'description': 'Test',
        'version': '1.0.0',
        'apiVersion': 1,
        'permissions': ['pluginStorag'],
        'settings': <String, dynamic>{},
        'api': <dynamic>[],
      }),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          contains('pluginStorag'),
        ),
      ),
    );
  });

  test('rejects removed pluginNotify permission', () {
    expect(PluginPermissions.fromString('pluginNotify'), isNull);
  });

  test('rejects Dart enum names as manifest permission aliases', () {
    expect(PluginPermissions.fromString('eventsShots'), isNull);
  });

  test('serializes permissions using manifest wire values', () {
    final manifest = PluginManifest(
      id: 'test.plugin',
      name: 'Test Plugin',
      author: 'Test',
      description: 'Test',
      version: '1.0.0',
      apiVersion: 1,
      permissions: {
        PluginPermissions.api,
        PluginPermissions.pluginStorage,
        PluginPermissions.proxyDecentApi,
      },
      settings: {},
      api: PluginApi(endpoints: []),
    );

    expect(
      manifest.toJson()['permissions'],
      containsAll(['api', 'pluginStorage', 'proxy.decent_api']),
    );
  });
}
