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
  bool get usbPowered => powered;

  @override
  Future<void> setUsbPowered(bool value) async {
    calls++;
    if (fail) throw StateError('configuration failed');
    powered = value;
  }
}

void main() {
  test(
    'applies USB setting to existing and newly discovered devices',
    () async {
      final discovery = MockDeviceDiscoveryService();
      final settings = SettingsController(MockSettingsService());
      await settings.loadSettings();
      final controller = DeviceController([
        discovery,
      ], settingsController: settings);
      await controller.initialize();
      final existing = _ConfigurableScale();
      discovery.addDevice(existing);
      await Future<void>.delayed(Duration.zero);

      await settings.setSkalePoweredByUsb(true);
      await Future<void>.delayed(Duration.zero);
      expect(existing.powered, isTrue);

      final newDevice = _ConfigurableScale(deviceId: 'new-scale');
      discovery.addDevice(newDevice);
      await Future<void>.delayed(Duration.zero);
      expect(newDevice.powered, isTrue);

      controller.dispose();
      discovery.dispose();
    },
  );

  test(
    'ignores non-configurable devices and contains configuration failures',
    () async {
      final discovery = MockDeviceDiscoveryService();
      final settings = SettingsController(MockSettingsService());
      await settings.loadSettings();
      final controller = DeviceController([
        discovery,
      ], settingsController: settings);
      await controller.initialize();
      final failing = _ConfigurableScale()..fail = true;
      discovery.addDevice(TestScale(deviceId: 'ordinary'));
      discovery.addDevice(failing);

      await settings.setSkalePoweredByUsb(true);
      await Future<void>.delayed(Duration.zero);
      expect(failing.calls, greaterThanOrEqualTo(1));

      controller.dispose();
      discovery.dispose();
    },
  );

  test('removes settings listener on dispose', () async {
    final discovery = MockDeviceDiscoveryService();
    final settings = SettingsController(MockSettingsService());
    await settings.loadSettings();
    final controller = DeviceController([
      discovery,
    ], settingsController: settings);
    await controller.initialize();
    final scale = _ConfigurableScale();
    discovery.addDevice(scale);
    await Future<void>.delayed(Duration.zero);
    controller.dispose();

    await settings.setSkalePoweredByUsb(true);
    await Future<void>.delayed(Duration.zero);
    expect(scale.calls, 1);

    discovery.dispose();
  });
}
