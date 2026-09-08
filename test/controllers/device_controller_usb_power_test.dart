import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/device_controller.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/settings/settings_controller.dart';

import '../helpers/mock_device_discovery_service.dart';
import '../helpers/mock_settings_service.dart';
import '../helpers/test_scale.dart';

class _ConfigurableScale extends TestScale implements UsbPowerConfigurable {
  _ConfigurableScale({super.deviceId});

  bool powered = false;
  bool fail = false;
  int calls = 0;

  @override
  Future<void> setUsbPowered(bool value) async {
    calls++;
    if (fail) throw StateError('configuration failed');
    powered = value;
  }
}

Future<(MockDeviceDiscoveryService, SettingsController, DeviceController)>
_createController() async {
  final discovery = MockDeviceDiscoveryService();
  final settings = SettingsController(MockSettingsService());
  await settings.loadSettings();
  final controller = DeviceController([
    discovery,
  ], settingsController: settings);
  await controller.initialize();
  return (discovery, settings, controller);
}

void main() {
  test(
    'applies each device USB setting independently to existing and new devices',
    () async {
      final (discovery, settings, controller) = await _createController();
      final existing = _ConfigurableScale(deviceId: 'skale-a');
      final other = _ConfigurableScale(deviceId: 'skale-b');
      discovery.addDevice(existing);
      discovery.addDevice(other);
      await Future<void>.delayed(Duration.zero);

      await settings.setSkalePoweredByUsb('skale-a', true);
      await Future<void>.delayed(Duration.zero);
      expect(existing.powered, isTrue);
      expect(other.powered, isFalse);

      final newDevice = _ConfigurableScale(deviceId: 'new-scale');
      discovery.addDevice(newDevice);
      await Future<void>.delayed(Duration.zero);
      expect(newDevice.powered, isFalse);

      controller.dispose();
      discovery.dispose();
    },
  );

  test(
    'ignores non-configurable devices and contains configuration failures',
    () async {
      final (discovery, settings, controller) = await _createController();
      final failing = _ConfigurableScale()..fail = true;
      discovery.addDevice(TestScale(deviceId: 'ordinary'));
      discovery.addDevice(failing);

      await settings.setSkalePoweredByUsb(failing.deviceId, true);
      await Future<void>.delayed(Duration.zero);
      expect(failing.calls, greaterThanOrEqualTo(1));

      controller.dispose();
      discovery.dispose();
    },
  );

  test('removes settings listener on dispose', () async {
    final (discovery, settings, controller) = await _createController();
    final scale = _ConfigurableScale();
    discovery.addDevice(scale);
    await Future<void>.delayed(Duration.zero);
    controller.dispose();

    await settings.setSkalePoweredByUsb(scale.deviceId, true);
    await Future<void>.delayed(Duration.zero);
    expect(scale.calls, 1);

    discovery.dispose();
  });
}
