import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/plugins/plugin_device_service.dart';
import 'package:reaprime/src/plugins/plugin_manifest.dart';

void main() {
  test('registers a device settings descriptor per plugin instance', () async {
    final service = PluginDeviceService();
    addTearDown(service.dispose);

    await service.register(
      pluginId: 'test.plugin',
      generation: 1,
      registrationHandle: 'device_1',
      definition: {
        'driverId': 'scale',
        'instanceId': 'one',
        'name': 'Scale one',
      },
      driver: const PluginDriverDeclaration(
        id: 'scale',
        type: PluginDriverType.scale,
        settingsEndpoint: 'device-settings',
      ),
      invoke: (_, _) async => const {},
    );

    final device = (await service.devices.first).single;
    expect(device.deviceId, 'plugin:test.plugin:scale:one');
    final settings = device as DeviceSettingsCapable;
    expect(settings.deviceSettings?.pluginId, 'test.plugin');
    expect(settings.deviceSettings?.endpointId, 'device-settings');
  });
}
