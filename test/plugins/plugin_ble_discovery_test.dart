import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/device/device.dart' as domain;
import 'package:reaprime/src/models/device/device_implementation.dart';
import 'package:reaprime/src/models/device/remembered_device.dart';
import 'package:reaprime/src/models/device/transport/data_transport.dart';
import 'package:reaprime/src/models/device/watch_filter.dart';
import 'package:reaprime/src/plugins/plugin_manager.dart';
import 'package:reaprime/src/services/universal_ble_discovery_service.dart';
import 'package:universal_ble/universal_ble.dart';

import '../helpers/plugin_ble_fixture.dart';
import 'plugin_manager_ble_test.dart' show bleSensorSource, bleSensorManifest;
import 'plugin_test_helpers.dart';

void main() {
  test(
    'existing watch emits nameless plugin Sensor once and reconciles unload',
    () async {
      final platform = PluginBleFixturePlatform();
      UniversalBle.setInstance(platform);
      final manager = PluginManager(kvStore: FakeKeyValueStoreService());
      final service = UniversalBleDiscoveryService(
        watchSupportGate: () => true,
        pluginBleService: () => manager.bleService,
        transportFactory:
            ({
              required device,
              required stopScan,
              required requestLargeMtuNonAndroid,
              required lifecycleGate,
            }) => PluginBleFixtureTransport(device.deviceId),
      );
      addTearDown(() async {
        await service.dispose();
        await manager.dispose();
      });
      await service.initialize();
      await manager.loadPlugin(
        id: 'ble.sensor',
        manifest: bleSensorManifest(),
        settings: {},
        jsCode: bleSensorSource,
      );
      final devices = <List<domain.Device>>[];
      final sub = service.devices.listen(devices.add);
      addTearDown(sub.cancel);
      await service.startDeviceWatch(const DeviceWatchFilter());
      final found = service.devices.firstWhere((d) => d.isNotEmpty);
      platform.updateScanResult(
        BleDevice(deviceId: 'AA:BB', name: null, services: ['180f']),
      );
      final candidate = (await found.timeout(
        const Duration(seconds: 2),
      )).single;
      expect(candidate.deviceId, 'plugin:ble.sensor:humidity:aa:bb');
      platform.updateScanResult(
        BleDevice(deviceId: 'AA:BB', name: null, services: ['180f']),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(devices.last.single, same(candidate));
      final empty = service.devices.firstWhere((d) => d.isEmpty);
      await manager.unloadPlugin('ble.sensor');
      await empty.timeout(const Duration(seconds: 2));
      await expectLater(candidate.onConnect(), throwsA(anything));
    },
  );

  test(
    'remembered native device cannot bypass incomplete BLE ownership',
    () async {
      final platform = PluginBleFixturePlatform();
      UniversalBle.setInstance(platform);
      final manager = PluginManager(kvStore: FakeKeyValueStoreService());
      final transports = <PluginBleFixtureTransport>[];
      final service = UniversalBleDiscoveryService(
        pluginBleService: () => manager.bleService,
        transportFactory:
            ({
              required device,
              required stopScan,
              required requestLargeMtuNonAndroid,
              required lifecycleGate,
            }) {
              final t = PluginBleFixtureTransport(device.deviceId);
              transports.add(t);
              return t;
            },
      );
      addTearDown(() async {
        await service.dispose();
        await manager.dispose();
      });
      await service.initialize();
      await manager.loadPlugin(
        id: 'ble.sensor',
        manifest: bleSensorManifest(),
        settings: {},
        jsCode: bleSensorSource,
      );
      final device = await service.tryQuickConnect(
        RememberedDevice(
          id: 'AA:BB',
          name: 'Bookoo',
          type: domain.DeviceType.scale,
          implementation: DeviceImplementation.bookooScale,
          transportType: TransportType.ble,
        ),
      );
      expect(device, isNull);
      expect(transports, isEmpty);
    },
  );
}
