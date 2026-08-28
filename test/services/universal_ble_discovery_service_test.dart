import 'dart:async';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/device/de1_interface.dart';
import 'package:reaprime/src/models/device/device.dart' as domain;
import 'package:reaprime/src/models/device/watch_filter.dart';
import 'package:reaprime/src/services/universal_ble_discovery_service.dart';
import 'package:universal_ble/universal_ble.dart';

import 'package:reaprime/src/models/device/device_implementation.dart';
import 'package:reaprime/src/models/device/impl/de1/de1.models.dart';
import 'package:reaprime/src/models/device/machine.dart';
import 'package:reaprime/src/models/device/remembered_device.dart';
import 'package:reaprime/src/models/device/transport/data_transport.dart';
import 'package:reaprime/src/settings/feature_flags.dart';
import 'package:reaprime/src/settings/settings_controller.dart';

import '../helpers/fake_ble_transport.dart';
import '../helpers/mock_settings_service.dart';

class _FakeBlePlatform extends UniversalBlePlatform {
  final List<BleDevice> systemDevices = [];

  final List<({ScanFilter? filter, PlatformConfig? config})> startScanCalls =
      [];
  int stopScanCalls = 0;
  Object? failNextStartScanWith;

  @override
  Future<AvailabilityState> getBluetoothAvailabilityState() async =>
      AvailabilityState.poweredOn;

  @override
  Future<bool> enableBluetooth() async => true;

  @override
  Future<bool> disableBluetooth() async => true;

  Completer<void>? holdNextStartScan;

  @override
  Future<void> startScan({
    ScanFilter? scanFilter,
    PlatformConfig? platformConfig,
  }) async {
    if (failNextStartScanWith != null) {
      final e = failNextStartScanWith;
      failNextStartScanWith = null;
      throw e!;
    }
    final hold = holdNextStartScan;
    if (hold != null) {
      holdNextStartScan = null;
      await hold.future;
    }
    startScanCalls.add((filter: scanFilter, config: platformConfig));
    nativeScanning = true;
  }

  @override
  Future<void> stopScan() async {
    stopScanCalls++;
    nativeScanning = false;
  }

  bool nativeScanning = false;

  @override
  Future<bool> isScanning() async => nativeScanning;

  @override
  Future<void> connect(
    String deviceId, {
    Duration? connectionTimeout,
    bool autoConnect = false,
    ConnectionPlatformConfig? platformConfig,
  }) async {}

  @override
  Future<void> disconnect(String deviceId) async {}

  @override
  Future<List<BleService>> discoverServices(
    String deviceId,
    bool withDescriptors,
  ) async => [];

  @override
  Future<void> setNotifiable(
    String deviceId,
    String service,
    String characteristic,
    BleInputProperty bleInputProperty,
  ) async {}

  @override
  Future<Uint8List> readValue(
    String deviceId,
    String service,
    String characteristic, {
    Duration? timeout,
  }) async => Uint8List(0);

  @override
  Future<void> writeValue(
    String deviceId,
    String service,
    String characteristic,
    Uint8List value,
    BleOutputProperty bleOutputProperty,
  ) async {}

  @override
  Future<int> requestMtu(String deviceId, int expectedMtu) async => 23;

  @override
  Future<int> readRssi(String deviceId) async => 0;

  @override
  Future<void> requestConnectionPriority(
    String deviceId,
    BleConnectionPriority priority,
  ) async {}

  @override
  Future<bool> isPaired(String deviceId) async => false;

  @override
  Future<bool> pair(String deviceId) async => true;

  @override
  Future<void> unpair(String deviceId) async {}

  @override
  Future<BleConnectionState> getConnectionState(String deviceId) async =>
      BleConnectionState.disconnected;

  @override
  Future<List<BleDevice>> getSystemDevices(List<String>? withServices) async {
    return List<BleDevice>.unmodifiable(systemDevices);
  }
}

class _TrackingFakeBleTransport extends FakeBleTransport {
  int disconnectCalls = 0;
  int disposeCalls = 0;
  bool _disposed = false;

  @override
  Future<void> disconnect() async {
    disconnectCalls++;
    if (!_disposed) {
      await super.disconnect();
    }
  }

  @override
  Future<void> dispose() async {
    disposeCalls++;
    if (_disposed) return;

    _disposed = true;
    await super.dispose();
  }
}

const _watchFilter = DeviceWatchFilter(namePrefix: 'Decent Scale');

void main() {
  late _FakeBlePlatform platform;
  late UniversalBleDiscoveryService service;

  _TrackingFakeBleTransport transportForModel(int model) {
    return _TrackingFakeBleTransport()
      ..queueOnConnectResponses(v13Model: model, calFlowEst: 100);
  }

  Future<void> pump([int n = 3]) async {
    for (var i = 0; i < n; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  setUp(() async {
    platform = _FakeBlePlatform();
    UniversalBle.setInstance(platform);
    service = UniversalBleDiscoveryService(watchSupportGate: () => true);
    await service.initialize();
  });

  tearDown(() async {
    await service.dispose();
  });

  ({ScanFilter? filter, PlatformConfig? config}) lastStart() =>
      platform.startScanCalls.last;

  group('startDeviceWatch', () {
    test('starts a name-prefix-filtered balanced scan', () async {
      await service.startDeviceWatch(_watchFilter);

      expect(platform.startScanCalls, hasLength(1));
      expect(lastStart().filter?.withNamePrefix, ['Decent Scale']);
      expect(
        lastStart().config?.android?.scanMode,
        AndroidScanMode.balanced,
        reason: 'the watch must leave most of the radio duty cycle to GATT',
      );
    });

    test('null name prefix scans unfiltered, still balanced', () async {
      await service.startDeviceWatch(const DeviceWatchFilter());

      expect(platform.startScanCalls, hasLength(1));
      expect(lastStart().filter?.withNamePrefix, isEmpty);
      expect(lastStart().config?.android?.scanMode, AndroidScanMode.balanced);
    });

    test('watch discovery flows into the devices stream', () async {
      final emissions = <List<domain.Device>>[];
      final sub = service.devices.listen(emissions.add);
      await service.startDeviceWatch(_watchFilter);

      platform.updateScanResult(
        BleDevice(deviceId: 'AA:BB:CC:DD:EE:FF', name: 'Decent Scale'),
      );
      await pump();

      expect(
        emissions.expand((l) => l).map((d) => d.deviceId),
        contains('AA:BB:CC:DD:EE:FF'),
      );
      await sub.cancel();
    });

    test('normalized duplicate results create one candidate', () async {
      var transports = 0;
      final sut = UniversalBleDiscoveryService(
        watchSupportGate: () => true,
        transportFactory:
            ({
              required device,
              required stopScan,
              required requestLargeMtuNonAndroid,
              required lifecycleGate,
            }) {
              transports++;
              return FakeBleTransport();
            },
      );
      addTearDown(sut.dispose);
      await sut.initialize();
      await sut.startDeviceWatch(_watchFilter);

      platform.updateScanResult(
        BleDevice(deviceId: 'AA:BB:CC:DD:EE:FF', name: 'Decent Scale'),
      );
      platform.updateScanResult(
        BleDevice(deviceId: 'aa:bb:cc:dd:ee:ff', name: 'Decent Scale'),
      );
      await pump();

      expect(transports, 1);
    });
  });

  group('stopDeviceWatch', () {
    test('stops the platform scan', () async {
      await service.startDeviceWatch(_watchFilter);
      await service.stopDeviceWatch();
      expect(platform.stopScanCalls, 1);
    });

    test('is idempotent and safe without a watch', () async {
      await service.stopDeviceWatch();
      expect(platform.stopScanCalls, 0);
    });
  });

  group('burst arbitration', () {
    test('a burst scan pauses the watch and resumes it afterwards', () async {
      await service.startDeviceWatch(_watchFilter);
      expect(platform.startScanCalls, hasLength(1));

      final burst = service.scanForDevices();
      await pump();
      expect(
        platform.stopScanCalls,
        1,
        reason: 'the watch scan must be stopped before the burst starts',
      );
      expect(platform.startScanCalls, hasLength(2));
      expect(
        lastStart().filter?.withNamePrefix,
        isEmpty,
        reason: 'bursts stay unfiltered (name-match happens in Dart)',
      );

      service.stopScan();
      await burst;
      await pump();

      expect(
        platform.startScanCalls,
        hasLength(3),
        reason: 'the watch must resume after the burst',
      );
      expect(lastStart().filter?.withNamePrefix, ['Decent Scale']);
      expect(lastStart().config?.android?.scanMode, AndroidScanMode.balanced);
    });

    test(
      'startDeviceWatch during a burst defers until the burst ends',
      () async {
        final burst = service.scanForDevices();
        await pump();
        expect(platform.startScanCalls, hasLength(1));

        await service.startDeviceWatch(_watchFilter);
        expect(
          platform.startScanCalls,
          hasLength(1),
          reason: 'watch start must not fight the in-flight burst',
        );

        service.stopScan();
        await burst;
        await pump();

        expect(
          platform.startScanCalls,
          hasLength(2),
          reason: 'the requested watch starts once the burst is done',
        );
        expect(lastStart().filter?.withNamePrefix, ['Decent Scale']);
      },
    );

    test('external stopScan() with only the watch active is a no-op', () async {
      await service.startDeviceWatch(_watchFilter);
      service.stopScan();
      await pump();

      expect(
        platform.stopScanCalls,
        0,
        reason: 'stopScan means "stop burst" — it must not kill the watch',
      );
    });
  });

  group('start-window races', () {
    test('stopDeviceWatch during an in-flight start waits for it and '
        'undoes the scan', () async {
      final hold = Completer<void>();
      platform.holdNextStartScan = hold;

      final start = service.startDeviceWatch(_watchFilter);
      await pump();
      final stop = service.stopDeviceWatch();
      await pump();
      expect(
        platform.stopScanCalls,
        0,
        reason: 'stop must wait for the start to settle first',
      );

      hold.complete();
      await start;
      await stop;
      await pump();

      expect(platform.startScanCalls, hasLength(1));
      expect(
        platform.stopScanCalls,
        1,
        reason:
            'the scan the raced start opened must be undone — '
            'otherwise it runs orphaned forever',
      );
    });

    test(
      'a burst racing the watch start is serialized: the burst scan '
      'starts only after the watch start settles and owns the session',
      () async {
        final hold = Completer<void>();
        platform.holdNextStartScan = hold;

        final start = service.startDeviceWatch(_watchFilter);
        await pump();
        final burst = service.scanForDevices();
        await pump();

        expect(
          platform.startScanCalls,
          isEmpty,
          reason:
              'the burst must wait for the in-flight watch start — '
              'issuing its startScan concurrently leaves session '
              'ownership undefined',
        );

        hold.complete();
        await start;
        await pump();

        final prefixes = platform.startScanCalls
            .map((c) => c.filter?.withNamePrefix ?? const <String>[])
            .toList();
        expect(
          prefixes.first,
          ['Decent Scale'],
          reason: 'the raced watch start settles before the burst starts',
        );
        expect(
          prefixes[1],
          isEmpty,
          reason: 'the burst scan follows and owns the session',
        );

        service.stopScan();
        await burst;
        await pump();

        expect(
          platform.startScanCalls,
          hasLength(3),
          reason: 'the watch must resume after the burst',
        );
        expect(
          lastStart().filter?.withNamePrefix,
          ['Decent Scale'],
          reason:
              'the burst finally-block must resume a real watch scan, '
              'not skip it because the raced start claimed to be active',
        );
      },
    );
  });

  group('resilience', () {
    test('adapter powering off during the start window stands the watch '
        'down and power-on restarts it', () async {
      final hold = Completer<void>();
      platform.holdNextStartScan = hold;

      final start = service.startDeviceWatch(_watchFilter);
      await pump();
      platform.updateAvailability(AvailabilityState.poweredOff);
      await pump();

      hold.complete();
      await start;
      await pump();

      expect(
        platform.startScanCalls,
        hasLength(1),
        reason:
            'the raced start alone — nothing may claim active while '
            'the adapter is off',
      );

      platform.updateAvailability(AvailabilityState.poweredOn);
      await pump();

      expect(
        platform.startScanCalls,
        hasLength(2),
        reason:
            'a still-requested watch must restart on power-on; a '
            'stale active claim from the raced start would block this',
      );
      expect(lastStart().filter?.withNamePrefix, ['Decent Scale']);
    });

    test('adapter off AND on completing within the start window discards '
        'the raced start and starts a fresh scan', () async {
      final hold = Completer<void>();
      platform.holdNextStartScan = hold;

      final start = service.startDeviceWatch(_watchFilter);
      await pump();
      platform.updateAvailability(AvailabilityState.poweredOff);
      await pump();
      platform.updateAvailability(AvailabilityState.poweredOn);
      await pump();

      hold.complete();
      await start;
      await pump(6);

      expect(
        platform.startScanCalls,
        hasLength(2),
        reason:
            'the raced start is discarded and a fresh start must '
            'own the session — claiming active over a possibly-dead '
            'native scan leaves the watch permanently silent',
      );
      expect(lastStart().filter?.withNamePrefix, ['Decent Scale']);
    });

    test('a failed post-burst resume emits a watch failure', () async {
      await service.startDeviceWatch(_watchFilter);
      final failures = <void>[];
      final sub = service.deviceWatchFailures.listen(failures.add);

      final burst = service.scanForDevices();
      await pump();
      platform.failNextStartScanWith = Exception('resume denied');
      service.stopScan();
      await burst;
      await pump();

      expect(
        failures,
        hasLength(1),
        reason:
            'a dead watch must be reported so ScaleWatch can fall '
            'back to the legacy loop instead of staying silently armed',
      );

      platform.updateAvailability(AvailabilityState.poweredOff);
      await pump();
      platform.updateAvailability(AvailabilityState.poweredOn);
      await pump();
      expect(
        platform.startScanCalls,
        hasLength(2),
        reason:
            'watch start + burst only — no resurrection after a '
            'reported failure',
      );
      await sub.cancel();
    });

    test('a failed refresh restart emits a watch failure', () {
      fakeAsync((async) {
        final zoned = UniversalBleDiscoveryService(
          watchSupportGate: () => true,
        );
        zoned.initialize();
        async.flushMicrotasks();
        final failures = <void>[];
        zoned.deviceWatchFailures.listen(failures.add);
        zoned.startDeviceWatch(_watchFilter);
        async.flushMicrotasks();
        expect(platform.startScanCalls, hasLength(1));

        platform.failNextStartScanWith = Exception('refresh denied');
        async.elapse(const Duration(minutes: 26));
        async.flushMicrotasks();

        expect(
          failures,
          hasLength(1),
          reason:
              'a refresh that cannot restart the scan leaves the '
              'watch dead — it must be reported, not swallowed',
        );

        zoned.stopDeviceWatch();
        async.flushMicrotasks();
      });
    });

    test('the liveness probe restarts a silently dead native scan', () {
      fakeAsync((async) {
        final zoned = UniversalBleDiscoveryService(
          watchSupportGate: () => true,
        );
        zoned.initialize();
        async.flushMicrotasks();
        zoned.startDeviceWatch(_watchFilter);
        async.flushMicrotasks();
        expect(platform.startScanCalls, hasLength(1));

        platform.nativeScanning = false;
        async.elapse(const Duration(minutes: 2));
        async.flushMicrotasks();

        expect(
          platform.startScanCalls.length,
          greaterThanOrEqualTo(2),
          reason:
              'the probe must notice the dead scan and restart it '
              'instead of waiting for the 25-min refresh',
        );
        expect(lastStart().filter?.withNamePrefix, ['Decent Scale']);

        zoned.stopDeviceWatch();
        async.flushMicrotasks();
      });
    });

    test('a live scan passes the liveness probe untouched', () {
      fakeAsync((async) {
        final zoned = UniversalBleDiscoveryService(
          watchSupportGate: () => true,
        );
        zoned.initialize();
        async.flushMicrotasks();
        zoned.startDeviceWatch(_watchFilter);
        async.flushMicrotasks();

        async.elapse(const Duration(minutes: 10));
        async.flushMicrotasks();

        expect(
          platform.startScanCalls,
          hasLength(1),
          reason: 'probes on a healthy scan must not churn the session',
        );

        zoned.stopDeviceWatch();
        async.flushMicrotasks();
      });
    });

    test('adapter off kills the watch; adapter on restarts it', () async {
      await service.startDeviceWatch(_watchFilter);
      expect(platform.startScanCalls, hasLength(1));

      platform.updateAvailability(AvailabilityState.poweredOff);
      await pump();
      platform.updateAvailability(AvailabilityState.poweredOn);
      await pump();

      expect(
        platform.startScanCalls,
        hasLength(2),
        reason:
            'a still-requested watch must restart when the adapter '
            'comes back',
      );
      expect(lastStart().filter?.withNamePrefix, ['Decent Scale']);
    });

    test('the periodic refresh restarts the scan before the Android '
        '30-minute opportunistic downgrade', () {
      fakeAsync((async) {
        final zoned = UniversalBleDiscoveryService(
          watchSupportGate: () => true,
        );
        zoned.initialize();
        async.flushMicrotasks();
        zoned.startDeviceWatch(_watchFilter);
        async.flushMicrotasks();
        expect(platform.startScanCalls, hasLength(1));

        async.elapse(const Duration(minutes: 26));
        async.flushMicrotasks();

        expect(
          platform.stopScanCalls,
          greaterThanOrEqualTo(1),
          reason: 'refresh must stop the aging scan',
        );
        expect(
          platform.startScanCalls.length,
          greaterThanOrEqualTo(2),
          reason: 'and start a fresh one',
        );
        expect(lastStart().filter?.withNamePrefix, ['Decent Scale']);

        zoned.stopDeviceWatch();
        async.flushMicrotasks();
      });
    });
  });

  group('quick-connect identity policy', () {
    test(
      'remembered UnifiedDe1 accepts Bengle wire model in degraded mode',
      () async {
        const deviceId = 'AA:BB:CC:DD:EE:01';

        platform.systemDevices.add(BleDevice(deviceId: deviceId, name: 'DE1'));

        final transport = transportForModel(129);
        final sut = UniversalBleDiscoveryService(
          transportFactory:
              ({
                required device,
                required stopScan,
                required requestLargeMtuNonAndroid,
                required lifecycleGate,
              }) {
                return transport;
              },
        );
        await sut.initialize();

        const remembered = RememberedDevice(
          id: deviceId,
          name: 'DE1',
          type: domain.DeviceType.machine,
          implementation: DeviceImplementation.unifiedDe1,
          transportType: TransportType.ble,
        );

        final result = await sut.tryQuickConnect(remembered);

        expect(result, isNotNull);
        expect(
          result!.implementation,
          DeviceImplementation.unifiedDe1,
          reason: 'quick-connect must trust the remembered implementation',
        );
        expect(
          (result as Machine).machineInfo.model,
          DecentMachineModel.Bengle.name,
          reason: 'the wire model is still preserved for diagnostics',
        );
        expect(
          transport.disconnectCalls,
          0,
          reason: 'the safe mismatch direction must remain connected',
        );
        expect(transport.disposeCalls, 0);

        await (result as De1Interface).dispose();
      },
    );

    test(
      'remembered Bengle rejects stock DE1 and falls back to discovery',
      () async {
        const deviceId = 'AA:BB:CC:DD:EE:02';

        platform.systemDevices.add(
          BleDevice(deviceId: deviceId, name: 'Bengle'),
        );

        final transport = transportForModel(3);
        final sut = UniversalBleDiscoveryService(
          transportFactory:
              ({
                required device,
                required stopScan,
                required requestLargeMtuNonAndroid,
                required lifecycleGate,
              }) {
                return transport;
              },
        );
        await sut.initialize();

        final emissions = <List<domain.Device>>[];
        final subscription = sut.devices.listen(emissions.add);
        addTearDown(subscription.cancel);

        const remembered = RememberedDevice(
          id: deviceId,
          name: 'Bengle',
          type: domain.DeviceType.machine,
          implementation: DeviceImplementation.bengle,
          transportType: TransportType.ble,
        );

        final result = await sut.tryQuickConnect(remembered);
        await pump();

        expect(
          result,
          isNull,
          reason: 'a stock DE1 must not be adopted as Bengle',
        );
        expect(
          emissions.expand((devices) => devices),
          isEmpty,
          reason: 'the rejected device must never enter the registry',
        );
        expect(transport.disconnectCalls, greaterThanOrEqualTo(1));
        expect(transport.disposeCalls, greaterThanOrEqualTo(1));
      },
    );
  });

  group('large MTU feature-flag wiring', () {
    test(
      'new transports read the current SettingsController flag value',
      () async {
        final settingsController = SettingsController(MockSettingsService());
        await settingsController.loadSettings();

        final capturedValues = <bool>[];
        final transports = <FakeBleTransport>[];

        final sut = UniversalBleDiscoveryService(
          watchSupportGate: () => true,
          requestLargeMtuNonAndroid: () => settingsController
              .isFeatureFlagEnabled(FeatureFlag.largeBleMtuNonAndroid),
          transportFactory:
              ({
                required device,
                required stopScan,
                required requestLargeMtuNonAndroid,
                required lifecycleGate,
              }) {
                capturedValues.add(requestLargeMtuNonAndroid);

                final transport = FakeBleTransport();
                transports.add(transport);
                return transport;
              },
        );

        addTearDown(() async {
          for (final transport in transports) {
            await transport.dispose();
          }
        });

        await sut.initialize();
        await sut.startDeviceWatch(const DeviceWatchFilter());

        platform.updateScanResult(
          BleDevice(deviceId: 'AA:BB:CC:DD:EE:10', name: 'DE1'),
        );
        await pump();

        await settingsController.setFeatureFlag(
          FeatureFlag.largeBleMtuNonAndroid,
          true,
        );

        platform.updateScanResult(
          BleDevice(deviceId: 'AA:BB:CC:DD:EE:11', name: 'DE1'),
        );
        await pump();

        expect(
          capturedValues,
          [false, true],
          reason:
              'the callback must be evaluated when each transport is created, '
              'not snapshotted during service construction',
        );

        await sut.stopDeviceWatch();
      },
    );
  });
}
