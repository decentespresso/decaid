import 'dart:async';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/device/de1_interface.dart';
import 'package:reaprime/src/models/device/device.dart' as domain;
import 'package:reaprime/src/models/device/ble_scan_state.dart';
import 'package:reaprime/src/models/device/watch_filter.dart';
import 'package:reaprime/src/models/device/watch_state.dart';
import 'package:reaprime/src/services/universal_ble_discovery_service.dart';
import 'package:universal_ble/universal_ble.dart';

import 'package:reaprime/src/models/device/device_implementation.dart';
import 'package:reaprime/src/models/device/impl/de1/de1.models.dart';
import 'package:reaprime/src/models/device/machine.dart';
import 'package:reaprime/src/models/device/remembered_device.dart';
import 'package:reaprime/src/models/device/transport/data_transport.dart';
import 'package:reaprime/src/settings/feature_flags.dart';
import 'package:reaprime/src/settings/settings_controller.dart';
import 'package:reaprime/src/plugins/plugin_manager.dart';
import 'package:reaprime/src/plugins/plugin_manifest.dart';
import 'package:reaprime/src/plugins/plugin_ble_matcher.dart';

import '../helpers/fake_ble_transport.dart';
import '../helpers/mock_settings_service.dart';
import '../plugins/plugin_test_helpers.dart';

class _FakeBlePlatform extends UniversalBlePlatform {
  final List<BleDevice> systemDevices = [];
  final Map<String, BleConnectionState> connectionStates = {};
  Future<BleConnectionState> Function(String deviceId)?
  getConnectionStateOverride;
  int disconnectCalls = 0;

  final List<({ScanFilter? filter, PlatformConfig? config})> startScanCalls =
      [];
  int stopScanCalls = 0;
  Object? failNextStartScanWith;
  Object? failNextStopScanWith;

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
    final error = failNextStopScanWith;
    failNextStopScanWith = null;
    if (error != null) throw error;
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
  Future<void> disconnect(String deviceId) async {
    disconnectDevice(deviceId);
  }

  void connectDevice(
    String deviceId, {
    BleConnectionState state = BleConnectionState.connected,
  }) {
    connectionStates[deviceId.toLowerCase()] = state;
  }

  void disconnectDevice(String deviceId) {
    disconnectCalls++;
    connectionStates[deviceId.toLowerCase()] = BleConnectionState.disconnected;
  }

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
  Future<BleConnectionState> getConnectionState(String deviceId) async {
    final override = getConnectionStateOverride;
    if (override != null) return override(deviceId);
    return connectionStates[deviceId.toLowerCase()] ??
        BleConnectionState.disconnected;
  }

  @override
  Future<List<BleDevice>> getSystemDevices(List<String>? withServices) async {
    return List<BleDevice>.unmodifiable(systemDevices);
  }
}

class _TrackingFakeBleTransport extends FakeBleTransport {
  _TrackingFakeBleTransport({this.deviceId, this.onConnect, this.onDisconnect});

  final String? deviceId;
  final Future<void> Function()? onConnect;
  final Future<void> Function()? onDisconnect;
  Stream<domain.ConnectionState>? connectionStateOverride;

  @override
  String get id => deviceId ?? super.id;

  @override
  Stream<domain.ConnectionState> get connectionState =>
      connectionStateOverride ?? super.connectionState;

  // disconnectCalls is inherited from FakeBleTransport, which now counts it.
  // Re-declaring it here would SHADOW the parent's field, so the parent's
  // disconnectCalls++ would update a different variable than the test reads.
  int disposeCalls = 0;
  bool _disposed = false;

  @override
  Future<void> connect() async {
    final callback = onConnect;
    if (callback != null) {
      await callback();
      return;
    }
    await super.connect();
  }

  @override
  Future<void> disconnectConfirmed() => disconnect();

  @override
  Future<void> disconnect() async {
    disconnectCalls++;
    final callback = onDisconnect;
    if (callback != null) await callback();
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

class _DelayedCancelSubscription<T> implements StreamSubscription<T> {
  _DelayedCancelSubscription(
    this._delegate,
    this._cancelRequested,
    this._release,
  );

  final StreamSubscription<T> _delegate;
  final Completer<void> _cancelRequested;
  final Completer<void> _release;

  @override
  Future<void> cancel() async {
    if (!_cancelRequested.isCompleted) _cancelRequested.complete();
    await _release.future;
    return _delegate.cancel();
  }

  @override
  void onData(void Function(T)? handleData) => _delegate.onData(handleData);

  @override
  void onError(Function? handleError) => _delegate.onError(handleError);

  @override
  void onDone(void Function()? handleDone) => _delegate.onDone(handleDone);

  @override
  void pause([Future<void>? resumeSignal]) => _delegate.pause(resumeSignal);

  @override
  void resume() => _delegate.resume();

  @override
  bool get isPaused => _delegate.isPaused;

  @override
  Future<E> asFuture<E>([E? futureValue]) => _delegate.asFuture(futureValue);
}

class _DelayedCancelConnectionStream extends Stream<domain.ConnectionState> {
  _DelayedCancelConnectionStream({
    domain.ConnectionState initialState = domain.ConnectionState.connected,
  }) : _state = initialState;

  final _controller = StreamController<domain.ConnectionState>.broadcast();
  final cancelRequested = Completer<void>();
  final release = Completer<void>();
  domain.ConnectionState _state;
  var _listenCount = 0;

  void emit(domain.ConnectionState state) {
    _state = state;
    _controller.add(state);
  }

  @override
  bool get isBroadcast => true;

  @override
  StreamSubscription<domain.ConnectionState> listen(
    void Function(domain.ConnectionState)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    final delegate = _controller.stream.listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
    _controller.add(_state);
    if (++_listenCount != 1) return delegate;
    return _DelayedCancelSubscription(delegate, cancelRequested, release);
  }
}

const _watchFilter = DeviceWatchFilter(namePrefix: 'Decent Scale');

void main() {
  late _FakeBlePlatform platform;
  late UniversalBleDiscoveryService service;

  _TrackingFakeBleTransport transportForModel(int model, {String? deviceId}) {
    return _TrackingFakeBleTransport(deviceId: deviceId)
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

    test(
      'diagnostics reports native disagreement and advertisements',
      () async {
        await service.startDeviceWatch(_watchFilter);
        platform.updateScanResult(
          BleDevice(deviceId: 'AA:BB:CC:DD:EE:FF', name: 'Decent Scale'),
        );
        await pump();

        platform.nativeScanning = false;
        final diagnostics = await service.diagnostics();
        final scan = diagnostics['scan'] as Map;
        final watch = diagnostics['watch'] as Map;
        final advertisements = diagnostics['advertisements'] as Map;

        expect(scan['owner'], 'watch');
        expect(scan['phase'], 'active');
        expect(scan['nativeIsScanning'], isFalse);
        expect(watch['state'], 'active');
        expect(advertisements['aa:bb:cc:dd:ee:ff']['count'], 1);
        expect(advertisements['aa:bb:cc:dd:ee:ff']['lastSeen'], isA<String>());
      },
    );

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

  group('watch ownership contract', () {
    test(
      'reports a queued watch as queued until the burst releases ownership',
      () async {
        final burst = service.scanForDevices();
        await pump();

        final result = await service.startDeviceWatch(_watchFilter);

        expect(result, DeviceWatchStartResult.queuedBehindBurst);
        expect(service.currentDeviceWatchState, DeviceWatchState.queued);
        expect(platform.startScanCalls, hasLength(1));

        service.stopScan();
        await burst;
        await pump();

        expect(service.currentDeviceWatchState, DeviceWatchState.active);
        expect(platform.startScanCalls, hasLength(2));
      },
    );

    test(
      'a failed watch-to-burst stop faults ownership and blocks the burst',
      () async {
        await service.startDeviceWatch(_watchFilter);
        platform.failNextStopScanWith = Exception('stop denied');

        final burst = service.scanForDevices();

        await expectLater(burst, throwsA(isA<Exception>()));
        expect(service.currentDeviceWatchState, DeviceWatchState.faulted);
        expect(platform.startScanCalls, hasLength(1));
      },
    );

    test(
      'an initial start failure clears the request and does not resurrect',
      () async {
        platform.failNextStartScanWith = Exception('start denied');

        final result = await service.startDeviceWatch(_watchFilter);

        expect(result, DeviceWatchStartResult.failed);
        expect(service.currentDeviceWatchState, DeviceWatchState.faulted);
        platform.updateAvailability(AvailabilityState.poweredOff);
        await pump();
        platform.updateAvailability(AvailabilityState.poweredOn);
        await pump();
        expect(platform.startScanCalls, isEmpty);
      },
    );

    test(
      'adapter off and on resets faulted ownership for a fresh burst',
      () async {
        await service.startDeviceWatch(_watchFilter);
        platform.failNextStopScanWith = Exception('stop denied');

        final failedBurst = service.scanForDevices();
        await expectLater(failedBurst, throwsA(isA<Exception>()));
        expect(service.scanPhase, BleScanPhase.faulted);

        platform.updateAvailability(AvailabilityState.poweredOff);
        await pump();
        expect(service.scanPhase, BleScanPhase.faulted);

        platform.updateAvailability(AvailabilityState.poweredOn);
        await pump();
        expect(service.scanPhase, BleScanPhase.active);
        expect(platform.startScanCalls, hasLength(2));

        await service.stopDeviceWatch();
        final burst = service.scanForDevices();
        await pump();
        expect(platform.startScanCalls, hasLength(3));
        service.stopScan();
        await burst;
      },
    );
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
        expect(prefixes.first, [
          'Decent Scale',
        ], reason: 'the raced watch start settles before the burst starts');
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
    for (final (apple, stopWatch) in [
      (true, false),
      (false, false),
      (true, true),
    ]) {
      test(
        'quick-connect uses only fresh system names with apple=$apple, stopWatch=$stopWatch',
        () async {
          final manager = PluginManager(kvStore: FakeKeyValueStoreService());
          addTearDown(manager.dispose);
          manager.bleService.registry.register(
            pluginId: 'bookoo',
            generation: 1,
            declaration: PluginDriverDeclaration(
              id: 'scale',
              type: PluginDriverType.scale,
              ble: PluginBleMatcher.fromJson({
                'name': {'exact': 'Bookoo'},
              }),
            ),
            permissions: {PluginPermissions.transportBle},
            factoryHandle: 'factory',
          );
          const deviceId = 'AA:BB:CC:DD:EE:01';
          platform.systemDevices.add(
            BleDevice(deviceId: deviceId, name: 'DE1'),
          );
          final transport = transportForModel(129);
          final sut = UniversalBleDiscoveryService(
            watchSupportGate: () => true,
            requiresSystemDevice: () => apple,
            pluginBleService: () => manager.bleService,
            transportFactory:
                ({
                  required device,
                  required stopScan,
                  required requestLargeMtuNonAndroid,
                  required lifecycleGate,
                }) => transport,
          );
          addTearDown(sut.dispose);
          await sut.initialize();
          if (stopWatch) {
            await sut.startDeviceWatch(_watchFilter);
            await sut.stopDeviceWatch();
          }
          final result = await sut.tryQuickConnect(
            const RememberedDevice(
              id: deviceId,
              name: 'DE1',
              type: domain.DeviceType.machine,
              implementation: DeviceImplementation.unifiedDe1,
              transportType: TransportType.ble,
            ),
          );
          if (apple) {
            expect(result, isA<De1Interface>());
            await (result as De1Interface).dispose();
          } else {
            expect(result, isNull);
          }
        },
      );
    }

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
      'a connecting cached device is protected before native-state probing',
      () async {
        const deviceId = 'AA:BB:CC:DD:EE:05';
        final transports = <_TrackingFakeBleTransport>[];
        final sut = UniversalBleDiscoveryService(
          watchSupportGate: () => true,
          transportFactory:
              ({
                required device,
                required stopScan,
                required requestLargeMtuNonAndroid,
                required lifecycleGate,
              }) {
                final transport = transportForModel(
                  129,
                  deviceId: device.deviceId,
                );
                transports.add(transport);
                return transport;
              },
        );
        addTearDown(sut.dispose);
        platform.systemDevices.add(BleDevice(deviceId: deviceId, name: 'DE1'));
        await sut.initialize();

        const remembered = RememberedDevice(
          id: deviceId,
          name: 'DE1',
          type: domain.DeviceType.machine,
          implementation: DeviceImplementation.unifiedDe1,
          transportType: TransportType.ble,
        );
        await sut.tryQuickConnect(remembered);
        final cached = transports.single;
        cached.emitConnectionState(domain.ConnectionState.connecting);
        platform.connectionStates[deviceId.toLowerCase()] =
            BleConnectionState.disconnected;

        await sut.startDeviceWatch(_watchFilter);
        platform.updateScanResult(BleDevice(deviceId: deviceId, name: 'DE1'));
        await pump();

        expect(transports, hasLength(1));
        expect(cached.disconnectCalls, 0);
      },
    );

    test(
      'a native connecting link protects a cached connected device',
      () async {
        const deviceId = 'AA:BB:CC:DD:EE:0C';
        final transports = <_TrackingFakeBleTransport>[];
        final sut = UniversalBleDiscoveryService(
          watchSupportGate: () => true,
          transportFactory:
              ({
                required device,
                required stopScan,
                required requestLargeMtuNonAndroid,
                required lifecycleGate,
              }) {
                final transport = transportForModel(
                  129,
                  deviceId: device.deviceId,
                );
                transports.add(transport);
                return transport;
              },
        );
        addTearDown(sut.dispose);
        platform.systemDevices.add(BleDevice(deviceId: deviceId, name: 'DE1'));
        await sut.initialize();

        const remembered = RememberedDevice(
          id: deviceId,
          name: 'DE1',
          type: domain.DeviceType.machine,
          implementation: DeviceImplementation.unifiedDe1,
          transportType: TransportType.ble,
        );
        await sut.tryQuickConnect(remembered);
        platform.connectDevice(deviceId, state: BleConnectionState.connecting);

        await sut.startDeviceWatch(_watchFilter);
        platform.updateScanResult(BleDevice(deviceId: deviceId, name: 'DE1'));
        await pump();

        expect(transports, hasLength(1));
        expect(transports.single.disconnectCalls, 0);
      },
    );

    test(
      'a connection becoming active during stale observation stays cached',
      () async {
        const deviceId = 'AA:BB:CC:DD:EE:06';
        final probeObserved = Completer<void>();
        final releaseProbe = Completer<void>();
        final transports = <_TrackingFakeBleTransport>[];
        final sut = UniversalBleDiscoveryService(
          watchSupportGate: () => true,
          transportFactory:
              ({
                required device,
                required stopScan,
                required requestLargeMtuNonAndroid,
                required lifecycleGate,
              }) {
                final transport = transportForModel(
                  129,
                  deviceId: device.deviceId,
                );
                transports.add(transport);
                return transport;
              },
        );
        addTearDown(sut.dispose);
        platform.systemDevices.add(BleDevice(deviceId: deviceId, name: 'DE1'));
        await sut.initialize();
        platform.connectionStates[deviceId.toLowerCase()] =
            BleConnectionState.disconnected;
        platform.getConnectionStateOverride = (_) async {
          if (!probeObserved.isCompleted) probeObserved.complete();
          await releaseProbe.future;
          return BleConnectionState.disconnected;
        };

        const remembered = RememberedDevice(
          id: deviceId,
          name: 'DE1',
          type: domain.DeviceType.machine,
          implementation: DeviceImplementation.unifiedDe1,
          transportType: TransportType.ble,
        );
        final emissions = <List<domain.Device>>[];
        final subscription = sut.devices.listen(emissions.add);
        addTearDown(subscription.cancel);
        final connected = await sut.tryQuickConnect(remembered);
        final cached = transports.single;

        await sut.startDeviceWatch(_watchFilter);
        platform.updateScanResult(BleDevice(deviceId: deviceId, name: 'DE1'));
        await probeObserved.future;
        cached.emitConnectionState(domain.ConnectionState.connecting);
        releaseProbe.complete();
        await pump(6);

        expect(transports, hasLength(1));
        expect(cached.disconnectCalls, 0);
        expect(emissions.last, contains(same(connected)));
      },
    );

    test(
      'a native link returning during stale observation stays cached',
      () async {
        const deviceId = 'AA:BB:CC:DD:EE:0D';
        final probeObserved = Completer<void>();
        final releaseProbe = Completer<void>();
        var probeCount = 0;
        final transports = <_TrackingFakeBleTransport>[];
        final sut = UniversalBleDiscoveryService(
          watchSupportGate: () => true,
          transportFactory:
              ({
                required device,
                required stopScan,
                required requestLargeMtuNonAndroid,
                required lifecycleGate,
              }) {
                final transport = transportForModel(
                  129,
                  deviceId: device.deviceId,
                );
                transports.add(transport);
                return transport;
              },
        );
        addTearDown(sut.dispose);
        platform.systemDevices.add(BleDevice(deviceId: deviceId, name: 'DE1'));
        await sut.initialize();
        platform.connectionStates[deviceId.toLowerCase()] =
            BleConnectionState.disconnected;
        platform.getConnectionStateOverride = (_) async {
          if (probeCount++ == 0) {
            probeObserved.complete();
            await releaseProbe.future;
            return BleConnectionState.disconnected;
          }
          return platform.connectionStates[deviceId.toLowerCase()] ??
              BleConnectionState.disconnected;
        };

        const remembered = RememberedDevice(
          id: deviceId,
          name: 'DE1',
          type: domain.DeviceType.machine,
          implementation: DeviceImplementation.unifiedDe1,
          transportType: TransportType.ble,
        );
        final emissions = <List<domain.Device>>[];
        final subscription = sut.devices.listen(emissions.add);
        addTearDown(subscription.cancel);
        final connected = await sut.tryQuickConnect(remembered);
        await sut.startDeviceWatch(_watchFilter);
        platform.updateScanResult(BleDevice(deviceId: deviceId, name: 'DE1'));
        await probeObserved.future;
        platform.connectionStates[deviceId.toLowerCase()] =
            BleConnectionState.connected;
        releaseProbe.complete();
        await pump(6);

        expect(transports, hasLength(1));
        expect(emissions.last, contains(same(connected)));
        expect(transports.single.disconnectCalls, 0);
      },
    );

    for (final (state, deviceId) in const [
      (domain.ConnectionState.connecting, 'AA:BB:CC:DD:EE:12'),
      (domain.ConnectionState.discovered, 'AA:BB:CC:DD:EE:15'),
      (domain.ConnectionState.disconnecting, 'AA:BB:CC:DD:EE:16'),
    ]) {
      test(
        'a cached device moving to ${state.name} during the final stale probe '
        'stays cached',
        () async {
          final secondProbeStarted = Completer<void>();
          final releaseSecondProbe = Completer<void>();
          var probeCount = 0;
          final transports = <_TrackingFakeBleTransport>[];
          final sut = UniversalBleDiscoveryService(
            watchSupportGate: () => true,
            transportFactory:
                ({
                  required device,
                  required stopScan,
                  required requestLargeMtuNonAndroid,
                  required lifecycleGate,
                }) {
                  final transport = transportForModel(
                    129,
                    deviceId: device.deviceId,
                  );
                  transports.add(transport);
                  return transport;
                },
          );
          addTearDown(sut.dispose);
          platform.systemDevices.add(
            BleDevice(deviceId: deviceId, name: 'DE1'),
          );
          await sut.initialize();
          platform.getConnectionStateOverride = (_) async {
            if (probeCount++ == 0) {
              return BleConnectionState.disconnected;
            }
            secondProbeStarted.complete();
            await releaseSecondProbe.future;
            return BleConnectionState.disconnected;
          };

          final remembered = RememberedDevice(
            id: deviceId,
            name: 'DE1',
            type: domain.DeviceType.machine,
            implementation: DeviceImplementation.unifiedDe1,
            transportType: TransportType.ble,
          );
          final emissions = <List<domain.Device>>[];
          final subscription = sut.devices.listen(emissions.add);
          addTearDown(subscription.cancel);
          final connected = await sut.tryQuickConnect(remembered);
          final cached = transports.single;

          await sut.startDeviceWatch(_watchFilter);
          platform.updateScanResult(BleDevice(deviceId: deviceId, name: 'DE1'));
          await secondProbeStarted.future;
          cached.emitConnectionState(state);
          releaseSecondProbe.complete();
          await pump(6);

          expect(transports, hasLength(1));
          expect(emissions.last, contains(same(connected)));
          expect(cached.disconnectCalls, 0);
          expect(platform.disconnectCalls, 0);
        },
      );
    }

    test('a cached device returning to discovered during stale probing stays '
        'cached', () async {
      const deviceId = 'AA:BB:CC:DD:EE:13';
      final firstProbeObserved = Completer<void>();
      final releaseFirstProbe = Completer<void>();
      var nativeProbeCount = 0;
      final transports = <_TrackingFakeBleTransport>[];
      final sut = UniversalBleDiscoveryService(
        watchSupportGate: () => true,
        transportFactory:
            ({
              required device,
              required stopScan,
              required requestLargeMtuNonAndroid,
              required lifecycleGate,
            }) {
              final transport = transportForModel(
                129,
                deviceId: device.deviceId,
              );
              transports.add(transport);
              return transport;
            },
      );
      addTearDown(sut.dispose);
      platform.systemDevices.add(BleDevice(deviceId: deviceId, name: 'DE1'));
      await sut.initialize();
      platform.getConnectionStateOverride = (_) async {
        if (nativeProbeCount++ == 0) {
          firstProbeObserved.complete();
          await releaseFirstProbe.future;
          return BleConnectionState.disconnected;
        }
        return BleConnectionState.disconnected;
      };

      const remembered = RememberedDevice(
        id: deviceId,
        name: 'DE1',
        type: domain.DeviceType.machine,
        implementation: DeviceImplementation.unifiedDe1,
        transportType: TransportType.ble,
      );
      final emissions = <List<domain.Device>>[];
      final subscription = sut.devices.listen(emissions.add);
      addTearDown(subscription.cancel);
      final connected = await sut.tryQuickConnect(remembered);
      final cached = transports.single;

      await sut.startDeviceWatch(_watchFilter);
      platform.updateScanResult(BleDevice(deviceId: deviceId, name: 'DE1'));
      await firstProbeObserved.future;
      cached.emitConnectionState(domain.ConnectionState.discovered);
      releaseFirstProbe.complete();
      await pump(6);

      expect(transports, hasLength(1));
      expect(emissions.last, contains(same(connected)));
      expect(
        nativeProbeCount,
        1,
        reason:
            'discovered state must end stale probing after the '
            'first native probe',
      );
      expect(cached.disconnectCalls, 0);
      expect(platform.disconnectCalls, 0);
    });

    test(
      'discovery does not disconnect behind a shared-native connect',
      () async {
        const deviceId = 'AA:BB:CC:DD:EE:07';
        final connectStarted = Completer<void>();
        final releaseConnect = Completer<void>();
        final transports = <_TrackingFakeBleTransport>[];
        final sut = UniversalBleDiscoveryService(
          watchSupportGate: () => true,
          transportFactory:
              ({
                required device,
                required stopScan,
                required requestLargeMtuNonAndroid,
                required lifecycleGate,
              }) {
                final isReconnect = transports.isNotEmpty;
                final transport = _TrackingFakeBleTransport(
                  deviceId: device.deviceId,
                  onConnect: () async {
                    if (!isReconnect) {
                      platform.connectDevice(device.deviceId);
                      return;
                    }
                    await lifecycleGate.run(device.deviceId, () async {
                      connectStarted.complete();
                      await releaseConnect.future;
                      platform.connectDevice(device.deviceId);
                    });
                  },
                  onDisconnect: () async {
                    platform.disconnectDevice(device.deviceId);
                  },
                )..queueOnConnectResponses(v13Model: 129, calFlowEst: 100);
                transports.add(transport);
                return transport;
              },
        );
        addTearDown(sut.dispose);
        platform.systemDevices.add(BleDevice(deviceId: deviceId, name: 'DE1'));
        await sut.initialize();

        const remembered = RememberedDevice(
          id: deviceId,
          name: 'DE1',
          type: domain.DeviceType.machine,
          implementation: DeviceImplementation.unifiedDe1,
          transportType: TransportType.ble,
        );
        final first = await sut.tryQuickConnect(remembered);
        platform.connectionStates[deviceId.toLowerCase()] =
            BleConnectionState.disconnected;

        final reconnect = sut.tryQuickConnect(remembered);
        await connectStarted.future;
        await sut.startDeviceWatch(_watchFilter);
        platform.updateScanResult(BleDevice(deviceId: deviceId, name: 'DE1'));
        await pump();
        releaseConnect.complete();
        await reconnect;

        expect(transports, hasLength(2));
        expect(transports.first.disconnectCalls, 0);
        expect(platform.disconnectCalls, 0);
        expect(
          platform.connectionStates[deviceId.toLowerCase()],
          BleConnectionState.connected,
        );
        expect(first, isNotNull);
      },
    );

    test(
      'a cached discovered device is protected during native connect',
      () async {
        const deviceId = 'AA:BB:CC:DD:EE:0E';
        final connectStarted = Completer<void>();
        final releaseConnect = Completer<void>();
        final connectionState = _DelayedCancelConnectionStream(
          initialState: domain.ConnectionState.discovered,
        );
        final transports = <_TrackingFakeBleTransport>[];
        final emissions = <List<domain.Device>>[];
        final sut = UniversalBleDiscoveryService(
          watchSupportGate: () => true,
          transportFactory:
              ({
                required device,
                required stopScan,
                required requestLargeMtuNonAndroid,
                required lifecycleGate,
              }) {
                final first = transports.isEmpty;
                final transport = _TrackingFakeBleTransport(
                  deviceId: device.deviceId,
                  onConnect: first
                      ? () async {
                          platform.connectDevice(
                            device.deviceId,
                            state: BleConnectionState.disconnected,
                          );
                          connectStarted.complete();
                          await releaseConnect.future;
                          connectionState.emit(
                            domain.ConnectionState.connected,
                          );
                          platform.connectDevice(device.deviceId);
                        }
                      : null,
                )..queueOnConnectResponses(v13Model: 129, calFlowEst: 100);
                if (first) {
                  transport.connectionStateOverride = connectionState;
                }
                transports.add(transport);
                return transport;
              },
        );
        addTearDown(sut.dispose);
        addTearDown(() {
          if (!connectionState.release.isCompleted) {
            connectionState.release.complete();
          }
        });
        final emissionsSubscription = sut.devices.listen(emissions.add);
        addTearDown(emissionsSubscription.cancel);
        platform.systemDevices.add(BleDevice(deviceId: deviceId, name: 'DE1'));
        await sut.initialize();
        var nativeProbeCount = 0;
        platform.getConnectionStateOverride = (_) async {
          nativeProbeCount++;
          return BleConnectionState.disconnected;
        };
        await sut.startDeviceWatch(_watchFilter);
        platform.updateScanResult(BleDevice(deviceId: deviceId, name: 'DE1'));
        await pump();

        expect(emissions, isNotEmpty);
        final cached = emissions.last.single;
        final connect = cached.onConnect();
        await connectStarted.future;
        expect(
          platform.connectionStates[deviceId.toLowerCase()],
          BleConnectionState.disconnected,
        );

        platform.updateScanResult(BleDevice(deviceId: deviceId, name: 'DE1'));
        await pump();

        expect(transports, hasLength(1));
        expect(emissions.last, contains(same(cached)));
        expect(nativeProbeCount, 0);
        expect(transports.single.disconnectCalls, 0);
        expect(platform.disconnectCalls, 0);
        releaseConnect.complete();
        await connect;
      },
    );

    test(
      'unknown cached connection state is preserved without teardown',
      () async {
        const deviceId = 'AA:BB:CC:DD:EE:08';
        final transports = <_TrackingFakeBleTransport>[];
        final sut = UniversalBleDiscoveryService(
          watchSupportGate: () => true,
          transportFactory:
              ({
                required device,
                required stopScan,
                required requestLargeMtuNonAndroid,
                required lifecycleGate,
              }) {
                final transport = transportForModel(
                  129,
                  deviceId: device.deviceId,
                );
                transports.add(transport);
                return transport;
              },
        );
        addTearDown(sut.dispose);
        platform.systemDevices.add(BleDevice(deviceId: deviceId, name: 'DE1'));
        await sut.initialize();

        const remembered = RememberedDevice(
          id: deviceId,
          name: 'DE1',
          type: domain.DeviceType.machine,
          implementation: DeviceImplementation.unifiedDe1,
          transportType: TransportType.ble,
        );
        await sut.tryQuickConnect(remembered);
        final cached = transports.single;
        cached.connectionStateOverride = Stream<domain.ConnectionState>.error(
          TimeoutException('unknown'),
        );

        await sut.startDeviceWatch(_watchFilter);
        platform.updateScanResult(BleDevice(deviceId: deviceId, name: 'DE1'));
        await pump();

        expect(transports, hasLength(1));
        expect(cached.disconnectCalls, 0);
      },
    );

    test(
      'unknown native connection state is preserved without teardown',
      () async {
        const deviceId = 'AA:BB:CC:DD:EE:09';
        final transports = <_TrackingFakeBleTransport>[];
        final sut = UniversalBleDiscoveryService(
          watchSupportGate: () => true,
          transportFactory:
              ({
                required device,
                required stopScan,
                required requestLargeMtuNonAndroid,
                required lifecycleGate,
              }) {
                final transport = transportForModel(
                  129,
                  deviceId: device.deviceId,
                );
                transports.add(transport);
                return transport;
              },
        );
        addTearDown(sut.dispose);
        platform.systemDevices.add(BleDevice(deviceId: deviceId, name: 'DE1'));
        await sut.initialize();
        platform.getConnectionStateOverride = (_) async {
          throw TimeoutException('unknown');
        };

        const remembered = RememberedDevice(
          id: deviceId,
          name: 'DE1',
          type: domain.DeviceType.machine,
          implementation: DeviceImplementation.unifiedDe1,
          transportType: TransportType.ble,
        );
        await sut.tryQuickConnect(remembered);

        await sut.startDeviceWatch(_watchFilter);
        platform.updateScanResult(BleDevice(deviceId: deviceId, name: 'DE1'));
        await pump();

        expect(transports, hasLength(1));
        expect(transports.single.disconnectCalls, 0);
      },
    );

    test(
      'a delayed normal-discovery disconnect cannot evict a replacement',
      () async {
        const deviceId = 'AA:BB:CC:DD:EE:0A';
        final delayedState = _DelayedCancelConnectionStream();
        final transports = <_TrackingFakeBleTransport>[];
        final sut = UniversalBleDiscoveryService(
          watchSupportGate: () => true,
          transportFactory:
              ({
                required device,
                required stopScan,
                required requestLargeMtuNonAndroid,
                required lifecycleGate,
              }) {
                final transport = transportForModel(
                  129,
                  deviceId: device.deviceId,
                );
                if (transports.isEmpty) {
                  transport.connectionStateOverride = delayedState;
                }
                transports.add(transport);
                return transport;
              },
        );
        addTearDown(sut.dispose);
        platform.systemDevices.add(BleDevice(deviceId: deviceId, name: 'DE1'));
        await sut.initialize();
        final emissions = <List<domain.Device>>[];
        final subscription = sut.devices.listen(emissions.add);
        addTearDown(subscription.cancel);

        const remembered = RememberedDevice(
          id: deviceId,
          name: 'DE1',
          type: domain.DeviceType.machine,
          implementation: DeviceImplementation.unifiedDe1,
          transportType: TransportType.ble,
        );
        await sut.startDeviceWatch(_watchFilter);
        platform.updateScanResult(BleDevice(deviceId: deviceId, name: 'DE1'));
        await pump();
        expect(transports, hasLength(1));

        platform.connectionStates[deviceId.toLowerCase()] =
            BleConnectionState.disconnected;
        platform.updateScanResult(BleDevice(deviceId: deviceId, name: 'DE1'));
        await delayedState.cancelRequested.future;
        await sut.tryQuickConnect(remembered);
        delayedState.emit(domain.ConnectionState.disconnected);
        await pump();

        expect(emissions.any((devices) => devices.isEmpty), isFalse);
        delayedState.release.complete();
        await pump(6);
      },
    );

    test(
      'a delayed quick-connect disconnect cannot evict its replacement',
      () async {
        const deviceId = 'AA:BB:CC:DD:EE:0B';
        final delayedState = _DelayedCancelConnectionStream();
        final transports = <_TrackingFakeBleTransport>[];
        final sut = UniversalBleDiscoveryService(
          watchSupportGate: () => true,
          transportFactory:
              ({
                required device,
                required stopScan,
                required requestLargeMtuNonAndroid,
                required lifecycleGate,
              }) {
                final transport = transportForModel(
                  129,
                  deviceId: device.deviceId,
                );
                if (transports.isEmpty) {
                  transport.connectionStateOverride = delayedState;
                }
                transports.add(transport);
                return transport;
              },
        );
        addTearDown(sut.dispose);
        platform.systemDevices.add(BleDevice(deviceId: deviceId, name: 'DE1'));
        await sut.initialize();
        final emissions = <List<domain.Device>>[];
        final subscription = sut.devices.listen(emissions.add);
        addTearDown(subscription.cancel);

        const remembered = RememberedDevice(
          id: deviceId,
          name: 'DE1',
          type: domain.DeviceType.machine,
          implementation: DeviceImplementation.unifiedDe1,
          transportType: TransportType.ble,
        );
        await sut.startDeviceWatch(_watchFilter);
        platform.updateScanResult(BleDevice(deviceId: deviceId, name: 'DE1'));
        await pump();
        expect(transports, hasLength(1));

        final reconnect = sut.tryQuickConnect(remembered);
        await delayedState.cancelRequested.future;
        delayedState.emit(domain.ConnectionState.disconnected);
        await pump();

        expect(emissions.any((devices) => devices.isEmpty), isFalse);
        delayedState.release.complete();
        await reconnect;
        await pump();
      },
    );

    test(
      'fresh advertisement replaces a cached connected device after native link loss',
      () async {
        const deviceId = 'AA:BB:CC:DD:EE:03';
        final transports = <_TrackingFakeBleTransport>[];
        final sut = UniversalBleDiscoveryService(
          watchSupportGate: () => true,
          transportFactory:
              ({
                required device,
                required stopScan,
                required requestLargeMtuNonAndroid,
                required lifecycleGate,
              }) {
                final transport = transportForModel(
                  129,
                  deviceId: device.deviceId,
                );
                transports.add(transport);
                return transport;
              },
        );
        addTearDown(sut.dispose);
        platform.systemDevices.add(BleDevice(deviceId: deviceId, name: 'DE1'));
        await sut.initialize();
        final emissions = <List<domain.Device>>[];
        final subscription = sut.devices.listen(emissions.add);
        addTearDown(subscription.cancel);

        final remembered = RememberedDevice(
          id: deviceId,
          name: 'DE1',
          type: domain.DeviceType.machine,
          implementation: DeviceImplementation.unifiedDe1,
          transportType: TransportType.ble,
        );
        final connected = await sut.tryQuickConnect(remembered);
        expect(connected, isNotNull);
        expect(transports, hasLength(1));
        platform.connectionStates[deviceId.toLowerCase()] =
            BleConnectionState.disconnected;
        await sut.startDeviceWatch(_watchFilter);

        platform.updateScanResult(BleDevice(deviceId: deviceId, name: 'DE1'));
        await pump();

        expect(
          transports,
          hasLength(2),
          reason: 'fresh advertisement must create a new transport instance',
        );
        expect(transports.first.disconnectCalls, 0);
        expect(platform.disconnectCalls, 0);
        expect(emissions.last, hasLength(1));
        expect(emissions.last.single, isNot(same(connected)));
        await (connected as De1Interface).dispose();
      },
    );

    test(
      'fresh advertisement preserves a cached device with a live native link',
      () async {
        const deviceId = 'AA:BB:CC:DD:EE:04';
        final transports = <_TrackingFakeBleTransport>[];
        final sut = UniversalBleDiscoveryService(
          watchSupportGate: () => true,
          transportFactory:
              ({
                required device,
                required stopScan,
                required requestLargeMtuNonAndroid,
                required lifecycleGate,
              }) {
                final transport = transportForModel(
                  129,
                  deviceId: device.deviceId,
                );
                transports.add(transport);
                return transport;
              },
        );
        addTearDown(sut.dispose);
        platform.systemDevices.add(BleDevice(deviceId: deviceId, name: 'DE1'));
        platform.connectionStates[deviceId.toLowerCase()] =
            BleConnectionState.connected;
        await sut.initialize();

        const remembered = RememberedDevice(
          id: deviceId,
          name: 'DE1',
          type: domain.DeviceType.machine,
          implementation: DeviceImplementation.unifiedDe1,
          transportType: TransportType.ble,
        );
        final connected = await sut.tryQuickConnect(remembered);
        await sut.startDeviceWatch(_watchFilter);

        platform.updateScanResult(BleDevice(deviceId: deviceId, name: 'DE1'));
        await pump();

        expect(transports, hasLength(1));
        expect(connected, isNotNull);
        await (connected as De1Interface).dispose();
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
