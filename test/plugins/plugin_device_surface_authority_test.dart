import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/device/grinder_device.dart';
import 'package:reaprime/src/plugins/plugin_ble_registry.dart';
import 'package:reaprime/src/plugins/plugin_device_contract.dart';
import 'package:reaprime/src/plugins/plugin_device_surface_authority.dart';
import 'package:reaprime/src/plugins/plugin_manager.dart';
import 'package:reaprime/src/plugins/plugin_manifest.dart';

import '../helpers/plugin_ble_fixture.dart';
import 'plugin_test_helpers.dart';

void main() {
  test('optional display names preserve unnamed hrefs and encode once', () {
    final authority = PluginDeviceSurfaceAuthority(
      pluginId: 'explicit.owner',
      surfaces: const [
        PluginDeviceSurface(
          id: 'settings',
          role: 'settings',
          endpoint: 'device-settings',
        ),
      ],
    );
    const deviceId = 'opaque:%2F +?&/設定';
    const unnamedHref =
        '/api/v1/plugins/explicit.owner/device-settings'
        '?ui=1&deviceId=opaque%3A%252F+%2B%3F%26%2F%E8%A8%AD%E5%AE%9A';
    expect(authority.resolve(deviceId).single['href'], unnamedHref);
    expect(
      authority.resolve(deviceId, deviceName: null).single['href'],
      unnamedHref,
    );
    for (final (name, encodedName) in [
      ('X', 'X'),
      ('X:%2F +?&/設定', 'X%3A%252F+%2B%3F%26%2F%E8%A8%AD%E5%AE%9A'),
      ('', ''),
    ]) {
      final href = authority
          .resolve(deviceId, deviceName: name)
          .single['href']!;
      expect(
        href,
        name.isEmpty
            ? '$unnamedHref&deviceName'
            : '$unnamedHref&deviceName=$encodedName',
      );
      expect(Uri.parse(href).queryParameters, {
        'ui': '1',
        'deviceId': deviceId,
        'deviceName': name,
      });
    }
    expect(authority.resolve(deviceId).single['href'], unnamedHref);
  });

  for (final type in ['scale', 'sensor', 'grinder']) {
    for (final ble in [false, true]) {
      test(
        '$type ${ble ? 'BLE' : 'network'} carries fixed surface authority',
        () async {
          final manager = PluginManager(kvStore: FakeKeyValueStoreService());
          addTearDown(manager.dispose);
          final manifest = PluginManifest.fromJson({
            'id': 'explicit.owner',
            'name': 'Surface contract',
            'version': '1.0.0',
            'apiVersion': 1,
            'settings': <String, dynamic>{},
            'author': 'Test',
            'description': 'Surface contract',
            'permissions': ['api', if (ble) 'transport.ble'],
            'api': [
              {
                'id': 'device-settings',
                'type': 'http',
                'data': <String, dynamic>{},
              },
            ],
            'drivers': [
              {
                'id': 'driver',
                'type': type,
                'capabilities': <String>[],
                if (ble)
                  'ble': {
                    'match': {
                      'serviceUuids': ['180f'],
                    },
                  },
                'surfaces': [
                  {
                    'id': 'settings',
                    'role': 'settings',
                    'label': 'Settings',
                    'endpoint': 'device-settings',
                  },
                ],
              },
            ],
          });
          final handlers =
              '''{
          vendor: 'Test', dataChannels: [{key: 'value', type: 'number'}],
          connect() {}, disconnect() {},
          ${ble ? 'bleEvent() {},' : ''}
          ${type == 'sensor' ? 'execute() { return {}; },' : ''}
        }''';
          await manager.loadPlugin(
            id: manifest.id,
            manifest: manifest,
            settings: const {},
            jsCode:
                '''function createPlugin(host) {
            return {id: 'explicit.owner', async onLoad() {
              ${ble ? "await host.devices.bindDriver('driver', {create() { return $handlers; }});" : "await host.devices.register({driverId: 'driver', instanceId: 'one', name: 'Device', vendor: 'Test', dataChannels: [{key: 'value', type: 'number'}]}, $handlers);"}
            }};
          }''',
          );
          final PluginDeviceAdapter device;
          if (ble) {
            final evidence = BleAdvertisementEvidence(serviceUuids: ['180f']);
            device =
                await manager.bleService.createCandidate(
                      driver: manager.bleService.registry
                          .decide(evidence)
                          .drivers
                          .single,
                      physicalId: 'opaque:% +?&/',
                      evidence: evidence,
                      createTransport: () =>
                          PluginBleFixtureTransport('opaque:% +?&/'),
                      admit: () => true,
                    )
                    as PluginDeviceAdapter;
          } else {
            device =
                (await manager.deviceService.devices.firstWhere(
                      (devices) => devices.isNotEmpty,
                    )).single
                    as PluginDeviceAdapter;
          }
          final authority = device.surfaceAuthority!;
          expect(authority.pluginId, 'explicit.owner');
          expect(authority.declaredSurfaces.single.id, 'settings');
          if (device case GrinderDevice grinder) {
            expect(
              grinder.surfaces.single['href'],
              '/api/v1/plugins/explicit.owner/device-settings'
              '?ui=1&deviceId=${Uri.encodeQueryComponent(device.deviceId)}',
            );
          }
          final surface = authority.resolve('not-the-owner:% +?&/').single;
          expect(surface['label'], 'Settings');
          final href = Uri.parse(surface['href']!);
          expect(href.path, '/api/v1/plugins/explicit.owner/device-settings');
          expect(href.queryParameters, {
            'ui': '1',
            'deviceId': 'not-the-owner:% +?&/',
          });
          expect(
            Uri.parse(
              authority.resolve(device.deviceId).single['href']!,
            ).queryParameters['deviceId'],
            device.deviceId,
          );
          expect(
            () => authority.declaredSurfaces.clear(),
            throwsUnsupportedError,
          );
          expect(
            () => surface['href'] = 'https://foreign.invalid/',
            throwsUnsupportedError,
          );
        },
      );
    }
  }
}
