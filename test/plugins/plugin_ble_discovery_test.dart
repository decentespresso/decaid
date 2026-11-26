import 'package:clock/clock.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/connection/scale_watch.dart';
import 'package:reaprime/src/controllers/device_controller.dart';
import 'package:reaprime/src/models/device/device.dart' as domain;
import 'package:reaprime/src/models/device/device_implementation.dart';
import 'package:reaprime/src/models/device/remembered_device.dart';
import 'package:reaprime/src/models/device/transport/data_transport.dart';
import 'package:reaprime/src/models/device/watch_filter.dart';
import 'package:reaprime/src/plugins/plugin_manager.dart';
import 'package:reaprime/src/services/universal_ble_discovery_service.dart';
import 'package:universal_ble/universal_ble.dart';

import '../helpers/felicita_plugin_fixture.dart';
import '../helpers/plugin_ble_fixture.dart';
import 'plugin_manager_ble_test.dart' show bleSensorSource, bleSensorManifest;
import 'plugin_test_helpers.dart';

class _PluginWatchFixture {
  _PluginWatchFixture({this.scanDuration = const Duration(seconds: 15)}) {
    UniversalBle.setInstance(platform);
    manager = PluginManager(kvStore: FakeKeyValueStoreService());
    service = UniversalBleDiscoveryService(
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
            final transport = FelicitaPluginTransport(
              device.deviceId,
              firstPacket: felicitaPacket(1),
            );
            transports.add(transport);
            return transport;
          },
    );
  }

  final Duration scanDuration;
  final platform = PluginBleFixturePlatform();
  final transports = <FelicitaPluginTransport>[];
  late final PluginManager manager;
  late final UniversalBleDiscoveryService service;

  Future<void> start() async {
    await service.initialize();
    await loadFelicitaPlugin(manager);
    await service.startDeviceWatch(const DeviceWatchFilter());
  }

  Future<domain.Device> advertise(String physicalId) {
    final publicId =
        'plugin:felicita-arc.reaplugin:felicita:${physicalId.toLowerCase()}';
    final candidate = service.devices
        .firstWhere(
          (devices) => devices.any((device) => device.deviceId == publicId),
        )
        .then(
          (devices) =>
              devices.firstWhere((device) => device.deviceId == publicId),
        );
    platform.updateScanResult(
      BleDevice(
        deviceId: physicalId,
        name: 'Felicita Arc',
        services: const ['ffe0'],
      ),
    );
    return candidate.timeout(const Duration(seconds: 2));
  }

  Future<void> dispose() async {
    await service.dispose();
    await manager.dispose();
  }
}

void main() {
  test(
    'watch handover is single-use and remains bound to its physical device',
    () async {
      final fixture = _PluginWatchFixture();
      addTearDown(fixture.dispose);
      await fixture.start();
      final selected = await fixture.advertise('AA:BB');
      final other = await fixture.advertise('CC:DD');

      final claim = fixture.service.claimScaleWatchHandover(selected);
      expect(claim, isNotNull);
      expect(
        fixture.service.claimScaleWatchHandover(selected),
        isNull,
        reason: 'a watch sighting can issue only one outstanding claim',
      );
      await fixture.service.stopDeviceWatch();

      await expectLater(other.onConnect(), throwsA(anything));
      await selected.onConnect();
      expect(
        fixture.transports
            .singleWhere((t) => t.physicalId == 'AA:BB')
            .connectCalls,
        1,
      );
      await selected.disconnect();
      await expectLater(
        selected.onConnect(),
        throwsA(anything),
        reason: 'the consumed handover must not be replayed',
      );
    },
  );

  test(
    'expired handover rejects plugin connection deterministically',
    () async {
      final fixture = _PluginWatchFixture();
      addTearDown(fixture.dispose);
      await fixture.start();
      final selected = await fixture.advertise('AA:BB');
      final now = DateTime(2030, 1, 1);
      final claim = withClock(
        Clock.fixed(now),
        () => fixture.service.claimScaleWatchHandover(selected),
      );
      expect(claim, isNotNull);
      await fixture.service.stopDeviceWatch();

      await expectLater(
        withClock(
          Clock.fixed(now.add(const Duration(seconds: 6))),
          selected.onConnect,
        ),
        throwsA(anything),
      );
    },
  );

  test('a competing foreground scan supersedes a watch handover', () async {
    final fixture = _PluginWatchFixture(
      scanDuration: const Duration(milliseconds: 1),
    );
    addTearDown(fixture.dispose);
    await fixture.start();
    final selected = await fixture.advertise('AA:BB');
    expect(fixture.service.claimScaleWatchHandover(selected), isNotNull);

    await fixture.service.scanForDevices();
    await expectLater(selected.onConnect(), throwsA(anything));
  });

  test('registry unload invalidates an outstanding watch handover', () async {
    final fixture = _PluginWatchFixture();
    addTearDown(fixture.dispose);
    await fixture.start();
    final selected = await fixture.advertise('AA:BB');
    expect(fixture.service.claimScaleWatchHandover(selected), isNotNull);

    await fixture.manager.unloadPlugin(felicitaManifest().id);
    await expectLater(selected.onConnect(), throwsA(anything));
  });

  test(
    'plugin replacement invalidates an outstanding watch handover',
    () async {
      final fixture = _PluginWatchFixture();
      addTearDown(fixture.dispose);
      await fixture.start();
      final selected = await fixture.advertise('AA:BB');
      expect(fixture.service.claimScaleWatchHandover(selected), isNotNull);

      await fixture.manager.unloadPlugin(felicitaManifest().id);
      await loadFelicitaPlugin(fixture.manager);
      await expectLater(selected.onConnect(), throwsA(anything));
    },
  );

  test('runtime shutdown invalidates an outstanding watch handover', () async {
    final fixture = _PluginWatchFixture();
    addTearDown(fixture.dispose);
    await fixture.start();
    final selected = await fixture.advertise('AA:BB');
    expect(fixture.service.claimScaleWatchHandover(selected), isNotNull);

    await fixture.manager.dispose();
    await expectLater(selected.onConnect(), throwsA(anything));
  });

  test('adapter shutdown invalidates an outstanding watch handover', () async {
    final fixture = _PluginWatchFixture();
    addTearDown(fixture.dispose);
    await fixture.start();
    final selected = await fixture.advertise('AA:BB');
    expect(fixture.service.claimScaleWatchHandover(selected), isNotNull);

    fixture.platform.updateAvailability(AvailabilityState.poweredOff);
    await Future<void>.delayed(Duration.zero);
    await expectLater(selected.onConnect(), throwsA(anything));
  });

  test('preferred plugin scale connects from the background watch without a foreground scan', () async {
    final platform = PluginBleFixturePlatform();
    UniversalBle.setInstance(platform);
    final manager = PluginManager(kvStore: FakeKeyValueStoreService());
    await loadFelicitaPlugin(manager);
    final transports = <FelicitaPluginTransport>[];
    final service = UniversalBleDiscoveryService(
      watchSupportGate: () => true,
      pluginBleService: () => manager.bleService,
      transportFactory:
          ({
            required device,
            required stopScan,
            required requestLargeMtuNonAndroid,
            required lifecycleGate,
          }) {
            final transport = FelicitaPluginTransport(
              device.deviceId,
              firstPacket: felicitaPacket(1),
            );
            transports.add(transport);
            return transport;
          },
    );
    final devices = DeviceController([service]);
    addTearDown(() async {
      devices.dispose();
      await service.dispose();
      await manager.dispose();
    });
    await devices.initialize();

    const preferredId = 'plugin:felicita-arc.reaplugin:felicita:aa:bb';
    var shouldWatch = true;
    var connected = false;
    Object? connectError;
    final candidate = devices.deviceStream
        .where((found) => found.any((device) => device.deviceId == preferredId))
        .map(
          (found) =>
              found.firstWhere((device) => device.deviceId == preferredId),
        )
        .first;
    final watch = ScaleWatch(
      scanner: devices,
      shouldWatch: () => shouldWatch,
      preferredScaleId: () => preferredId,
      connectScale: (scale) async {
        try {
          await scale.onConnect();
          connected = true;
          shouldWatch = false;
        } catch (error) {
          connectError = error;
          rethrow;
        }
      },
      onWatchUnavailable: () {},
    );
    addTearDown(watch.dispose);

    await watch.arm();
    platform.updateScanResult(
      BleDevice(
        deviceId: 'AA:BB',
        name: 'Felicita Arc',
        services: const ['ffe0'],
      ),
    );
    await candidate.timeout(const Duration(seconds: 2));
    await pumpEventQueue();

    expect(connected, isTrue, reason: 'watch connection error: $connectError');
    expect(connectError, isNull);
    expect(transports, hasLength(1));
    expect(transports.single.connectCalls, 1);
    expect(
      platform.operations.where((operation) => operation == 'startScan'),
      hasLength(1),
      reason: 'the watch path must not fall back to a foreground scan',
    );
  });

  test(
    'existing watch emits nameless plugin Sensor once and reconciles unload',
    () async {
      final platform = PluginBleFixturePlatform();
      UniversalBle.setInstance(platform);
      final manager = PluginManager(kvStore: FakeKeyValueStoreService());
      final service = UniversalBleDiscoveryService(
        watchSupportGate: () => true,
        pluginBleService: () => manager.bleService,
        transportFactory: ({
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
      final candidate = (await found.timeout(const Duration(seconds: 2)))
          .single;
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
