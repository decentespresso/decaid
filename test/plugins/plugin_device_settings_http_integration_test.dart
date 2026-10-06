import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/plugins/plugin_device_contract.dart';
import 'package:reaprime/src/plugins/plugin_loader_service.dart';
import 'package:reaprime/src/plugins/plugin_manager.dart';
import 'package:reaprime/src/plugins/plugin_manifest.dart';
import 'package:reaprime/src/services/webserver_service.dart';
import 'package:shelf_plus/shelf_plus.dart';

import 'plugin_test_helpers.dart';

class _UnusedPluginLoaderService extends Fake implements PluginLoaderService {}

void main() {
  test(
    'mock device settings URL serves independent values via plugin KV',
    () async {
      const fixture = 'test/fixtures/plugins/plugin-device-settings.reaplugin';
      final manifest = PluginManifest.fromJson(
        jsonDecode(File('$fixture/manifest.json').readAsStringSync()),
      );
      final kvStore = FakeKeyValueStoreService();
      final manager = PluginManager(kvStore: kvStore);
      addTearDown(manager.dispose);
      await manager.loadPlugin(
        id: manifest.id,
        manifest: manifest,
        settings: {},
        jsCode: File('$fixture/plugin.js').readAsStringSync(),
      );

      final driver = manifest.drivers.single;
      expect(driver.surfaces.single.role, 'settings');
      final devices = <PluginDeviceAdapter>[];
      for (final (handle, name) in [
        ('one', 'Mock sensor #1'),
        ('two', 'Mock sensor #2'),
      ]) {
        await manager.deviceService.register(
          pluginId: manifest.id,
          generation: 1,
          registrationHandle: handle,
          definition: {
            'driverId': driver.id,
            'instanceId': handle,
            'name': name,
            'vendor': 'Mock',
            'dataChannels': [
              {'key': 'value', 'type': 'number'},
            ],
          },
          driver: driver,
          invoke: (_, _) async => const {},
        );
      }
      devices.addAll(
        (await manager.deviceService.devices.firstWhere(
          (list) => list.length == 2,
        )).cast<PluginDeviceAdapter>(),
      );
      final first = devices.singleWhere(
        (device) => device.name == 'Mock sensor #1',
      );
      final second = devices.singleWhere(
        (device) => device.name == 'Mock sensor #2',
      );

      final app = Router().plus;
      PluginsHandler(
        pluginManager: manager,
        pluginService: _UnusedPluginLoaderService(),
      ).addRoutes(app);

      Future<Map<String, dynamic>> get(Uri uri) async {
        final response = await app.call(Request('GET', uri));
        expect(response.statusCode, 200);
        expect(response.headers['content-type'], contains('application/json'));
        return jsonDecode(await response.readAsString())
            as Map<String, dynamic>;
      }

      final firstUri = Uri.parse('http://localhost:8080').resolve(
        first.surfaceAuthority!
            .resolve(first.deviceId, deviceName: first.name)
            .single['href']!,
      );
      final secondUri = Uri.parse('http://localhost:8080').resolve(
        second.surfaceAuthority!
            .resolve(second.deviceId, deviceName: second.name)
            .single['href']!,
      );
      expect(
        firstUri.toString(),
        'http://localhost:8080/api/v1/plugins/${manifest.id}/${driver.surfaces.single.endpoint}'
        '?ui=1&deviceId=${Uri.encodeQueryComponent(first.deviceId)}'
        '&deviceName=Mock+sensor+%231',
      );
      expect(secondUri.path, firstUri.path);
      expect(secondUri.queryParameters, {
        'ui': '1',
        'deviceId': second.deviceId,
        'deviceName': 'Mock sensor #2',
      });
      expect(
        secondUri.toString(),
        'http://localhost:8080/api/v1/plugins/${manifest.id}/${driver.surfaces.single.endpoint}'
        '?ui=1&deviceId=${Uri.encodeQueryComponent(second.deviceId)}'
        '&deviceName=Mock+sensor+%232',
      );
      expect(first.deviceId, isNot(second.deviceId));

      expect(await get(firstUri), {'deviceId': first.deviceId, 'value': null});
      expect(
        await get(
          firstUri.replace(
            queryParameters: {
              ...firstUri.queryParameters,
              'value': 'first setting',
            },
          ),
        ),
        {'deviceId': first.deviceId, 'value': 'first setting'},
      );
      expect(
        await get(
          secondUri.replace(
            queryParameters: {
              ...secondUri.queryParameters,
              'value': 'second setting',
            },
          ),
        ),
        {'deviceId': second.deviceId, 'value': 'second setting'},
      );
      expect(
        await kvStore.get(namespace: manifest.id, key: first.deviceId),
        'first setting',
      );
      expect(
        await kvStore.get(namespace: manifest.id, key: second.deviceId),
        'second setting',
      );
      expect(await get(firstUri), {
        'deviceId': first.deviceId,
        'value': 'first setting',
      });
      expect(await get(secondUri), {
        'deviceId': second.deviceId,
        'value': 'second setting',
      });
      expect(manager.activePendingOpCount, 0);
    },
  );
}
