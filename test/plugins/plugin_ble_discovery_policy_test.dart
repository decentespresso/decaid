import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/device/device.dart' as domain;
import 'package:reaprime/src/models/device/device_implementation.dart';
import 'package:reaprime/src/models/device/watch_filter.dart';
import 'package:reaprime/src/plugins/plugin_ble_registry.dart';
import 'package:reaprime/src/plugins/plugin_ble_matcher.dart';
import 'package:reaprime/src/plugins/plugin_manifest.dart';
import 'package:reaprime/src/plugins/plugin_manager.dart';
import 'package:reaprime/src/services/universal_ble_discovery_service.dart';
import 'package:universal_ble/universal_ble.dart';

import '../helpers/plugin_ble_fixture.dart';
import 'plugin_manager_ble_test.dart' show bleSensorSource, bleSensorManifest;
import 'plugin_test_helpers.dart';

class _Fixture {
  _Fixture({
    bool ready = true,
    Duration scanDuration = const Duration(seconds: 15),
  }) : manager = PluginManager(
         kvStore: FakeKeyValueStoreService(),
         bleRegistry: PluginBleRegistry(initiallyReady: ready),
       ) {
    UniversalBle.setInstance(platform);
    discovery = UniversalBleDiscoveryService(
      watchSupportGate: () => true,
      pluginBleService: () => manager.bleService,
      scanDuration: scanDuration,
      transportFactory:
          ({
            required device,
            required stopScan,
            required requestLargeMtuNonAndroid,
            required lifecycleGate,
          }) {
            final transport = PluginBleFixtureTransport(device.deviceId);
            transports.add(transport);
            return transport;
          },
    );
    subscription = discovery.devices.listen(devices.add);
  }
  final PluginManager manager;
  final platform = PluginBleFixturePlatform();
  final transports = <PluginBleFixtureTransport>[];
  final devices = <List<domain.Device>>[];
  late final UniversalBleDiscoveryService discovery;
  late final StreamSubscription<List<domain.Device>> subscription;

  Future<void> load([String id = 'ble.sensor']) => manager.loadPlugin(
    id: id,
    manifest: bleSensorManifest(id: id),
    settings: {},
    jsCode: bleSensorSource.replaceAll('ble.sensor', id),
  );
  Future<void> start() async {
    await discovery.initialize();
    await discovery.startDeviceWatch(const DeviceWatchFilter());
  }

  void advertise({List<String> services = const ['180f']}) =>
      platform.updateScanResult(
        BleDevice(deviceId: 'AA:BB', name: 'Bookoo', services: services),
      );
  Future<domain.Device> get next => discovery.devices
      .firstWhere((d) => d.isNotEmpty)
      .then((d) => d.single)
      .timeout(const Duration(seconds: 2));
  Future<void> dispose() async {
    await subscription.cancel();
    await discovery.dispose();
    await manager.dispose();
  }
}

void main() {
  for (final advertisementFirst in [false, true]) {
    test(
      'system/advertisement ownership with advertisementFirst=$advertisementFirst',
      () async {
        final fixture = _Fixture(
          scanDuration: const Duration(milliseconds: 60),
        );
        addTearDown(fixture.dispose);
        await fixture.discovery.initialize();
        await fixture.load();
        await fixture.manager.loadPlugin(
          id: 'competitor',
          settings: {},
          manifest: testManifest(
            'competitor',
            permissions: {
              PluginPermissions.emit,
              PluginPermissions.transportBle,
            },
            drivers: [
              PluginDriverDeclaration(
                id: 'humidity',
                type: PluginDriverType.sensor,
                ble: PluginBleMatcher.fromJson({
                  'serviceUuids': ['180a'],
                }),
              ),
            ],
          ),
          jsCode: bleSensorSource.replaceAll('ble.sensor', 'competitor'),
        );
        fixture.platform.systemDevices.add(
          BleDevice(deviceId: 'AA:BB', name: 'Bookoo', services: ['180f']),
        );
        if (advertisementFirst) {
          fixture.platform.firstAdvertisement = BleDevice(
            deviceId: 'AA:BB',
            name: 'Bookoo',
            services: ['180f'],
          );
        }
        final candidate = fixture.next;
        final scan = fixture.discovery.scanForDevices();
        await fixture.platform.started.future;
        if (!advertisementFirst) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
          final diagnostics = await fixture.discovery.diagnostics();
          expect(
            (diagnostics['pluginOwnership'] as Map)['aa:bb']['decision'],
            'pending',
          );
          expect(fixture.devices.expand((list) => list), isEmpty);
          fixture.advertise();
        }
        expect((await candidate).deviceId, 'plugin:ble.sensor:humidity:aa:bb');
        await scan.timeout(const Duration(seconds: 2));
        expect(
          fixture.devices.last.single.implementation,
          DeviceImplementation.plugin,
        );
        expect(fixture.manager.bleService.bindingCount, 1);
      },
    );
  }

  test(
    'loading a driver widens a filtered watch through existing scan ownership',
    () async {
      final fixture = _Fixture();
      addTearDown(fixture.dispose);
      await fixture.discovery.initialize();
      await fixture.discovery.startDeviceWatch(
        const DeviceWatchFilter(namePrefix: 'Decent Scale'),
      );
      expect(fixture.platform.scanFilters.last?.withNamePrefix, [
        'Decent Scale',
      ]);
      await fixture.load();
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(fixture.platform.scanFilters.last?.withNamePrefix, isEmpty);
      final candidate = fixture.next;
      fixture.platform.updateScanResult(
        BleDevice(deviceId: 'AA:BB', name: null, services: ['180f']),
      );
      expect((await candidate).implementation, DeviceImplementation.plugin);
    },
  );

  test(
    'startup waits for registry, not factory hardware initialization',
    () async {
      final fixture = _Fixture(ready: false);
      addTearDown(fixture.dispose);
      await fixture.discovery.initialize();
      final watch = fixture.discovery.startDeviceWatch(
        const DeviceWatchFilter(),
      );
      await Future<void>.delayed(Duration.zero);
      expect(fixture.platform.scanning, isFalse);
      await fixture.load();
      expect(fixture.transports, isEmpty);
      fixture.manager.bleService.registry.finishInitialLoading();
      await watch;
      final candidate = fixture.next;
      fixture.advertise();
      expect((await candidate).implementation, DeviceImplementation.plugin);
    },
  );

  test(
    'plugin-first ownership fences old native candidate and unload restores native',
    () async {
      final fixture = _Fixture();
      addTearDown(fixture.dispose);
      await fixture.start();
      final native = fixture.next;
      fixture.advertise();
      final oldNative = await native;
      expect(oldNative.implementation, DeviceImplementation.bookooScale);
      final replacement = fixture.next;
      await fixture.load();
      expect((await replacement).implementation, DeviceImplementation.plugin);
      await oldNative.onConnect();
      expect(fixture.transports.every((t) => t.connectCalls == 0), isTrue);
      final fallback = fixture.next;
      await fixture.manager.unloadPlugin('ble.sensor');
      expect((await fallback).implementation, DeviceImplementation.bookooScale);
      expect(fixture.devices.every((list) => list.length <= 1), isTrue);
    },
  );

  test(
    'failed plugin handshake does not fall back to native ownership',
    () async {
      final fixture = _Fixture();
      addTearDown(fixture.dispose);
      await fixture.start();
      await fixture.manager.loadPlugin(
        id: 'ble.sensor',
        manifest: bleSensorManifest(),
        settings: {},
        jsCode: bleSensorSource.replaceFirst(
          'context = session;',
          "throw Error('handshake failed');",
        ),
      );
      final candidate = fixture.next;
      fixture.advertise();
      final sensor = await candidate;
      await expectLater(sensor.onConnect(), throwsA(anything));
      await fixture.transports.single.disposed.future.timeout(
        const Duration(seconds: 2),
      );
      expect(fixture.transports.single.disposeCalls, 1);
      expect(
        fixture.devices
            .expand((list) => list)
            .every(
              (device) => device.implementation == DeviceImplementation.plugin,
            ),
        isTrue,
      );
      final diagnostics = await fixture.discovery.diagnostics();
      expect(
        (diagnostics['pluginOwnership'] as Map)['aa:bb']['decision'],
        'plugin',
      );
    },
  );

  test(
    'two definite matches conflict and unloading a competitor resolves ownership',
    () async {
      final fixture = _Fixture();
      addTearDown(fixture.dispose);
      await fixture.start();
      await fixture.load();
      await fixture.load('competitor');
      fixture.advertise();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(fixture.devices.expand((list) => list), isEmpty);
      final diagnostics = await fixture.discovery.diagnostics();
      expect(
        (diagnostics['pluginOwnership'] as Map)['aa:bb']['decision'],
        'conflict',
      );
      final candidate = fixture.next;
      await fixture.manager.unloadPlugin('competitor');
      expect((await candidate).deviceId, 'plugin:ble.sensor:humidity:aa:bb');
    },
  );

  test(
    'pending system evidence reaches normal scan deadline without native fallback',
    () async {
      final fixture = _Fixture(scanDuration: const Duration(milliseconds: 30));
      addTearDown(fixture.dispose);
      await fixture.discovery.initialize();
      await fixture.load();
      fixture.platform.systemDevices.add(
        BleDevice(deviceId: 'AA:BB', name: 'Bookoo'),
      );
      await fixture.discovery.scanForDevices().timeout(
        const Duration(seconds: 2),
      );
      expect(fixture.platform.scanning, isFalse);
      expect(fixture.transports, isEmpty);
      expect(fixture.devices.expand((list) => list), isEmpty);
      final diagnostics = await fixture.discovery.diagnostics();
      expect(
        (diagnostics['pluginOwnership'] as Map)['aa:bb']['decision'],
        'pending',
      );
    },
  );
}
