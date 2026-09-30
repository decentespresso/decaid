import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/settings/plugin_device_settings.dart';

void main() {
  test('builds a device settings URI with encoded identity', () {
    final uri = pluginDeviceSettingsUri(
      pluginId: 'skale.reaplugin',
      endpointId: 'device-settings',
      deviceId: 'plugin:skale.reaplugin:skale:one two',
      deviceName: 'Skale #1',
    );

    expect(
      uri.toString(),
      contains('/api/v1/plugins/skale.reaplugin/device-settings?'),
    );
    expect(
      uri.queryParameters['deviceId'],
      'plugin:skale.reaplugin:skale:one two',
    );
    expect(uri.queryParameters['deviceName'], 'Skale #1');
    expect(uri.queryParameters['ui'], '1');
  });

  test('encodes legal path component identifiers', () {
    final uri = pluginDeviceSettingsUri(
      pluginId: '_plugin name',
      endpointId: 'device-settings',
      deviceId: 'device',
    );

    expect(uri.pathSegments, [
      'api',
      'v1',
      'plugins',
      '_plugin name',
      'device-settings',
    ]);
    expect(uri.toString(), contains('_plugin%20name'));
  });
}
