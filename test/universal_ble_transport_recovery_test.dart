import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/device/device.dart' as device;
import 'package:reaprime/src/models/errors.dart';
import 'package:reaprime/src/services/ble/universal_ble_transport.dart';
import 'package:universal_ble/universal_ble.dart';

const _serviceUuid = '0000a000-0000-1000-8000-00805f9b34fb';
const _charUuid = '0000a00e-0000-1000-8000-00805f9b34fb';
const _writeTimeout = Duration(milliseconds: 50);

class _FakeBlePlatform extends UniversalBlePlatform {
  BleConnectionState connectionStateResult = BleConnectionState.connected;
  Completer<BleConnectionState>? connectionStateBlocker;
  bool emitDisconnectEvent = true;
  bool hangWrites = false;
  Completer<void>? writeBlocker;
  Completer<void>? notifiableBlocker;
  UniversalBleException? writeError;
  int connectCalls = 0;
  int writeCalls = 0;
  int getConnectionStateCalls = 0;
  int clearGattCacheCalls = 0;
  int discoverServicesCalls = 0;
  int stopScanCalls = 0;
  bool scanning = false;
  bool updateConnectionStateOnLifecycle = false;
  Completer<void>? clearGattCacheBlocker;
  Completer<void>? serviceDiscoveryBlocker;
  BleDevice? scanResult;
  final List<Object> serviceDiscoveryResults = [];
  final List<String> disconnectCalls = [];
  final List<BleInputProperty> notificationProperties = [];

  bool throwOnSecondSetNotifiable = false;
  final Map<String, int> _setNotifiableCounts = {};

  @override
  Future<AvailabilityState> getBluetoothAvailabilityState() async =>
      AvailabilityState.poweredOn;

  @override
  Future<bool> enableBluetooth() async => true;

  @override
  Future<bool> disableBluetooth() async => false;

  @override
  Future<void> startScan({
    ScanFilter? scanFilter,
    PlatformConfig? platformConfig,
  }) async {
    scanning = true;
    final result = scanResult;
    if (result != null) updateScanResult(result);
  }

  @override
  Future<void> stopScan() async {
    stopScanCalls++;
    scanning = false;
  }

  @override
  Future<bool> isScanning() async => scanning;

  @override
  Future<void> connect(
    String deviceId, {
    Duration? connectionTimeout,
    bool autoConnect = false,
    ConnectionPlatformConfig? platformConfig,
  }) async {
    connectCalls++;
    if (updateConnectionStateOnLifecycle) {
      connectionStateResult = BleConnectionState.connected;
    }
    updateConnection(deviceId, true);
  }

  @override
  Future<void> disconnect(String deviceId) async {
    disconnectCalls.add(deviceId);
    if (updateConnectionStateOnLifecycle) {
      connectionStateResult = BleConnectionState.disconnected;
    }
    if (emitDisconnectEvent) updateConnection(deviceId, false);
  }

  @override
  Future<List<BleService>> discoverServices(
    String deviceId,
    bool withDescriptors,
  ) async {
    discoverServicesCalls++;
    await serviceDiscoveryBlocker?.future;
    if (serviceDiscoveryResults.isEmpty) return [];
    final result = serviceDiscoveryResults.removeAt(0);
    if (result is Error || result is Exception) throw result;
    return result as List<BleService>;
  }

  @override
  Future<void> clearGattCache(String deviceId) async {
    clearGattCacheCalls++;
    await clearGattCacheBlocker?.future;
  }

  @override
  Future<void> setNotifiable(
    String deviceId,
    String service,
    String characteristic,
    BleInputProperty bleInputProperty,
  ) async {
    notificationProperties.add(bleInputProperty);
    final key = '$deviceId/$characteristic';
    final count = (_setNotifiableCounts[key] ?? 0) + 1;
    _setNotifiableCounts[key] = count;
    final blocker = notifiableBlocker;
    if (count == 2 && blocker != null) {
      await blocker.future;
    }
    if (throwOnSecondSetNotifiable && count == 2) {
      throw UniversalBleException(
        code: UniversalBleErrorCode.failed,
        message: 'simulated CCCD write failure',
      );
    }
  }

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
  ) async {
    writeCalls++;
    if (writeError case final error?) throw error;
    if (hangWrites) {
      await (writeBlocker ?? Completer<void>()).future;
    }
  }

  @override
  Future<int> requestMtu(String deviceId, int expectedMtu) async => 23;

  @override
  Future<int> readRssi(String deviceId) async => -50;

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
    getConnectionStateCalls++;
    return connectionStateBlocker?.future ?? connectionStateResult;
  }

  @override
  Future<List<BleDevice>> getSystemDevices(List<String>? withServices) async =>
      [];
}

void main() {
  late _FakeBlePlatform platform;
  late UniversalBleTransport transport;
  late List<device.ConnectionState> observedStates;
  late StreamSubscription<device.ConnectionState> stateSub;
  var deviceCounter = 0;
  late String deviceId;

  BleDevice bleDevice(String id, {String name = 'DE1'}) =>
      BleDevice(deviceId: id, name: name);

  Future<void> pump([int ms = 50]) =>
      Future<void>.delayed(Duration(milliseconds: ms));

  setUp(() async {
    platform = _FakeBlePlatform();
    UniversalBle.setInstance(platform);
    UniversalBle.clearQueue();
    UniversalBle.queueType = QueueType.perDevice;
    deviceId = 'AA:BB:CC:DD:EE:${(deviceCounter++).toString().padLeft(2, '0')}';
    transport = UniversalBleTransport(
      device: bleDevice(deviceId),
      // Platform-neutral: the generic recovery tests must not depend on the
      // CI runner's OS (Linux would add real BlueZ settle/connect delays).
      isAndroidOverride: false,
      isLinuxOverride: false,
      faultRecoveryGrace: const Duration(milliseconds: 200),
      faultRecoveryDisconnectTimeout: const Duration(milliseconds: 20),
    );
    observedStates = [];
    stateSub = transport.connectionState.listen(observedStates.add);
    await transport.connect();
    await pump(10);
    expect(observedStates, contains(device.ConnectionState.connected));
  });

  tearDown(() async {
    await stateSub.cancel();
    await transport.dispose();
    UniversalBle.clearQueue();
    UniversalBle.queueType = QueueType.global;
  });

  Future<void> timedOutWrite() async {
    await expectLater(
      transport.write(
        _serviceUuid,
        _charUuid,
        Uint8List.fromList([1]),
        timeout: _writeTimeout,
      ),
      throwsA(isA<TimeoutException>()),
    );
  }

  group('GATT timeout link verification (fix 1)', () {
    test(
      'write timeout with OS reporting disconnected → emits disconnected',
      () async {
        platform.hangWrites = true;
        platform.connectionStateResult = BleConnectionState.disconnected;

        await timedOutWrite();
        await pump();

        expect(observedStates, contains(device.ConnectionState.disconnected));
      },
    );

    test(
      'write timeout with OS reporting connected → stays connected',
      () async {
        platform.hangWrites = true;
        platform.connectionStateResult = BleConnectionState.connected;

        await timedOutWrite();
        await pump();

        expect(
          observedStates,
          isNot(contains(device.ConnectionState.disconnected)),
          reason:
              'a single timeout on a live link must stay fail-fast only '
              '(profile-upload safety)',
        );
        expect(
          platform.getConnectionStateCalls,
          greaterThan(0),
          reason: 'the timeout should have probed the OS link state',
        );
      },
    );

    test('unresolved native write past grace period forces teardown', () async {
      platform.hangWrites = true;
      platform.connectionStateResult = BleConnectionState.connected;

      await timedOutWrite();
      await pump(250);

      expect(observedStates, contains(device.ConnectionState.disconnected));
      expect(
        platform.disconnectCalls,
        contains(deviceId),
        reason: 'forced teardown must release the OS-level handle',
      );
    });

    test('failed disconnect leaves unresolved queue faulted', () async {
      platform.hangWrites = true;
      platform.emitDisconnectEvent = false;

      await timedOutWrite();
      await pump(300);

      expect(platform.disconnectCalls, contains(deviceId));
      expect(
        UniversalBle.getQueueDiagnostics(deviceId).state,
        QueueDiagnosticsState.faulted,
      );
      expect(
        observedStates,
        isNot(contains(device.ConnectionState.disconnected)),
      );
    });

    test(
      'late native completion clears the faulted queue without disconnecting',
      () async {
        platform.hangWrites = true;
        platform.writeBlocker = Completer<void>();
        platform.connectionStateResult = BleConnectionState.connected;

        await timedOutWrite();
        platform.writeBlocker!.complete();
        await pump(100);

        platform.hangWrites = false;
        await transport.write(
          _serviceUuid,
          _charUuid,
          Uint8List.fromList([2]),
          timeout: _writeTimeout,
        );

        expect(platform.writeCalls, 2);
        expect(
          observedStates,
          isNot(contains(device.ConnectionState.disconnected)),
        );
      },
    );
  });

  group('queue reset error handling', () {
    test(
      'post-timeout write is not dispatched while native write is unresolved',
      () async {
        platform.hangWrites = true;

        await timedOutWrite();
        await expectLater(
          transport.write(
            _serviceUuid,
            _charUuid,
            Uint8List.fromList([2]),
            timeout: _writeTimeout,
          ),
          throwsA(
            isA<UniversalBleException>().having(
              (e) => e.code,
              'code',
              UniversalBleErrorCode.operationCancelled,
            ),
          ),
        );
        await pump(100);

        expect(platform.writeCalls, 1);
      },
    );

    test(
      'faulted queue cancels pending writes without disconnecting',
      () async {
        platform.hangWrites = true;

        final active = expectLater(
          transport.write(
            _serviceUuid,
            _charUuid,
            Uint8List.fromList([1]),
            timeout: _writeTimeout,
          ),
          throwsA(isA<TimeoutException>()),
        );
        final nextActive = expectLater(
          transport.write(
            _serviceUuid,
            _charUuid,
            Uint8List.fromList([2]),
            timeout: const Duration(milliseconds: 100),
          ),
          throwsA(
            isA<UniversalBleException>().having(
              (e) => e.code,
              'code',
              UniversalBleErrorCode.operationCancelled,
            ),
          ),
        );
        final pending = expectLater(
          transport.write(
            _serviceUuid,
            _charUuid,
            Uint8List.fromList([3]),
            timeout: const Duration(seconds: 5),
          ),
          throwsA(
            isA<UniversalBleException>().having(
              (e) => e.code,
              'code',
              UniversalBleErrorCode.operationCancelled,
            ),
          ),
        );

        await active;
        await pending;
        await nextActive;
        await pump();

        expect(
          observedStates,
          isNot(contains(device.ConnectionState.disconnected)),
        );
      },
    );

    test(
      'deviceDisconnected maps and emits disconnected exactly once',
      () async {
        platform.writeError = UniversalBleException(
          code: UniversalBleErrorCode.deviceDisconnected,
          message: 'simulated native disconnect',
        );

        await expectLater(
          transport.write(_serviceUuid, _charUuid, Uint8List.fromList([1])),
          throwsA(isA<DeviceNotConnectedException>()),
        );
        await pump();

        expect(
          observedStates.where(
            (state) => state == device.ConnectionState.disconnected,
          ),
          hasLength(1),
        );
      },
    );
  });

  group('advertising-while-connected detection (fix 2)', () {
    test(
      'own advert + OS reporting disconnected → emits disconnected',
      () async {
        platform.connectionStateResult = BleConnectionState.disconnected;

        platform.updateScanResult(bleDevice(deviceId));
        await pump();

        expect(observedStates, contains(device.ConnectionState.disconnected));
      },
    );

    test('own advert + OS reporting connected → no teardown', () async {
      platform.connectionStateResult = BleConnectionState.connected;

      platform.updateScanResult(bleDevice(deviceId));
      await pump();

      expect(
        observedStates,
        isNot(contains(device.ConnectionState.disconnected)),
      );
      expect(
        platform.getConnectionStateCalls,
        greaterThan(0),
        reason: 'the advert should have triggered an OS probe',
      );
    });

    test('advert for a different device is ignored', () async {
      platform.connectionStateResult = BleConnectionState.disconnected;

      platform.updateScanResult(bleDevice('11:22:33:44:55:66'));
      await pump();

      expect(
        observedStates,
        isNot(contains(device.ConnectionState.disconnected)),
      );
      expect(platform.getConnectionStateCalls, 0);
    });

    test('advert while transport already disconnected is ignored', () async {
      platform.updateConnection(deviceId, false);
      await pump(10);
      expect(observedStates, contains(device.ConnectionState.disconnected));
      final probesBefore = platform.getConnectionStateCalls;

      platform.updateScanResult(bleDevice(deviceId));
      await pump();

      expect(
        platform.getConnectionStateCalls,
        probesBefore,
        reason: 'no probe when we already know we are disconnected',
      );
    });

    test(
      'probe completing after reconnect cannot tear down new connection',
      () async {
        platform.connectionStateBlocker = Completer<BleConnectionState>();
        platform.updateScanResult(bleDevice(deviceId));
        await pump(10);
        expect(platform.getConnectionStateCalls, 1);

        await transport.connect();
        platform.hangWrites = true;
        platform.writeBlocker = Completer<void>();
        final active = transport.write(
          _serviceUuid,
          _charUuid,
          Uint8List.fromList([1]),
          timeout: const Duration(seconds: 1),
        );
        final pending = transport.write(
          _serviceUuid,
          _charUuid,
          Uint8List.fromList([2]),
          timeout: const Duration(seconds: 1),
        );
        await pump(10);

        platform.connectionStateBlocker!.complete(
          BleConnectionState.disconnected,
        );
        await pump(10);
        expect(observedStates.last, device.ConnectionState.connected);

        platform.hangWrites = false;
        platform.writeBlocker!.complete();
        await Future.wait([active, pending]);
        expect(platform.writeCalls, 2);
      },
    );

    test('advert probes are throttled', () async {
      platform.connectionStateResult = BleConnectionState.connected;

      platform.updateScanResult(bleDevice(deviceId));
      platform.updateScanResult(bleDevice(deviceId));
      platform.updateScanResult(bleDevice(deviceId));
      await pump();

      expect(
        platform.getConnectionStateCalls,
        1,
        reason:
            'adverts arrive ~1/s during a scan; one probe per '
            'throttle window is enough',
      );
    });
  });

  group('re-subscribe push channel (universal_ble broadcast controller)', () {
    const service = '0000a000-0000-1000-8000-00805f9b34fb';
    const chars = [
      '0000a00e-0000-1000-8000-00805f9b34fb',
      '0000a005-0000-1000-8000-00805f9b34fb',
      '0000a00b-0000-1000-8000-00805f9b34fb',
      '0000a00d-0000-1000-8000-00805f9b34fb',
      '0000a011-0000-1000-8000-00805f9b34fb',
      '0000a009-0000-1000-8000-00805f9b34fb',
    ];

    void push(String char, int byte) => platform.updateCharacteristicValue(
      deviceId,
      char,
      Uint8List.fromList([byte]),
      null,
    );

    test(
      'single-char re-subscribe: new callback fires, old does not',
      () async {
        final oldReceived = <int>[];
        await transport.subscribe(
          service,
          chars[0],
          (d) => oldReceived.add(d[0]),
        );
        push(chars[0], 1);
        await pump();
        expect(oldReceived, [1]);

        final newReceived = <int>[];
        await transport.subscribe(
          service,
          chars[0],
          (d) => newReceived.add(d[0]),
        );
        push(chars[0], 2);
        await pump();

        expect(newReceived, [
          2,
        ], reason: 'the re-subscribed callback must receive the push');
        expect(oldReceived, [
          1,
        ], reason: 'the cancelled callback must NOT receive the push');
      },
    );

    test('sequential 6-char re-subscribe: all new callbacks fire (≥5 listeners '
        'always remain, so onCancel:close never fires mid-sequence)', () async {
      final oldReceived = <int, List<int>>{};
      final newReceived = <int, List<int>>{};
      for (var i = 0; i < chars.length; i++) {
        oldReceived[i] = [];
        newReceived[i] = [];
        await transport.subscribe(
          service,
          chars[i],
          (d) => oldReceived[i]!.add(d[0]),
        );
      }
      for (var i = 0; i < chars.length; i++) {
        push(chars[i], i + 1);
      }
      await pump();
      for (var i = 0; i < chars.length; i++) {
        expect(oldReceived[i], [i + 1]);
      }

      for (var i = 0; i < chars.length; i++) {
        await transport.subscribe(
          service,
          chars[i],
          (d) => newReceived[i]!.add(d[0]),
        );
      }
      for (var i = 0; i < chars.length; i++) {
        push(chars[i], (i + 1) * 10);
      }
      await pump();

      for (var i = 0; i < chars.length; i++) {
        expect(
          newReceived[i],
          [(i + 1) * 10],
          reason: 'new callback for ${chars[i]} must receive the push',
        );
        expect(
          oldReceived[i],
          [i + 1],
          reason: 'old callback for ${chars[i]} must NOT receive the push',
        );
      }
    });

    test(
      'setNotifiable throwing on 2nd call surfaces the error, not silent',
      () async {
        platform.throwOnSecondSetNotifiable = true;

        await transport.subscribe(service, chars[0], (_) {});

        await expectLater(
          transport.subscribe(service, chars[0], (_) {}),
          throwsA(isA<UniversalBleException>()),
        );
      },
    );

    test(
      'reset disables and re-enables CCCD without dropping listener',
      () async {
        final received = <int>[];
        await transport.subscribe(service, chars[0], (data) {
          received.add(data[0]);
        });

        final reset = transport.resetSubscription(service, chars[0], (_) {});
        await pump(20);
        push(chars[0], 1);
        await pump(20);
        await reset;

        expect(received, [1]);
        expect(platform.notificationProperties, [
          BleInputProperty.notification,
          BleInputProperty.disabled,
          BleInputProperty.notification,
        ]);
      },
    );

    test(
      'timed-out reset blocks replacement work until native completion',
      () async {
        await transport.subscribe(service, chars[0], (_) {});
        platform.notifiableBlocker = Completer<void>();
        platform.emitDisconnectEvent = false;

        await expectLater(
          transport.resetSubscription(service, chars[0], (_) {}),
          throwsA(isA<TimeoutException>()),
        );
        await expectLater(transport.disconnect(), throwsA(anything));

        expect(
          UniversalBle.getQueueDiagnostics(deviceId).state,
          QueueDiagnosticsState.faulted,
        );
        expect(
          observedStates,
          isNot(contains(device.ConnectionState.disconnected)),
        );
        await expectLater(transport.connect(), throwsA(isA<StateError>()));
        await expectLater(
          transport.write(
            service,
            chars[0],
            Uint8List.fromList([1]),
            timeout: _writeTimeout,
          ),
          throwsA(isA<UniversalBleException>()),
        );
        expect(platform.connectCalls, 1);
        expect(platform.writeCalls, 0);

        platform.notifiableBlocker!.complete();
        await pump(100);

        await transport.write(
          service,
          chars[0],
          Uint8List.fromList([2]),
          timeout: _writeTimeout,
        );
        expect(platform.writeCalls, 1);
      },
      timeout: const Timeout(Duration(seconds: 5)),
    );

    test('disconnect cancels listeners without writing CCCDs', () async {
      final received = <int>[];
      await transport.subscribe(
        service,
        chars[0],
        (data) => received.add(data[0]),
      );

      await transport.disconnect();
      push(chars[0], 1);
      await pump();

      expect(received, isEmpty);
      expect(platform.notificationProperties, [BleInputProperty.notification]);
      expect(platform.disconnectCalls, [deviceId]);
    });
  });

  group('Linux stale service recovery', () {
    Future<
      (
        UniversalBleTransport,
        List<device.ConnectionState>,
        StreamSubscription<device.ConnectionState>,
      )
    >
    createLinuxTransport({Duration cacheRefreshScan = Duration.zero}) async {
      final linux = UniversalBleTransport(
        device: bleDevice('$deviceId-linux'),
        isLinuxOverride: true,
        bluezPostConnectDelay: Duration.zero,
        bluezScanSettleDelay: Duration.zero,
        bluezCacheRefreshScan: cacheRefreshScan,
        faultRecoveryDisconnectTimeout: const Duration(milliseconds: 100),
      );
      final states = <device.ConnectionState>[];
      final subscription = linux.connectionState.listen(states.add);
      platform.updateConnectionStateOnLifecycle = true;
      await linux.connect();
      await pump(10);
      return (linux, states, subscription);
    }

    UniversalBleException unresolved() => UniversalBleException(
      code: UniversalBleErrorCode.servicesNotResolved,
      message: 'stale',
    );

    test('successful recovery hides the maintenance disconnect', () async {
      final (linux, states, subscription) = await createLinuxTransport();
      addTearDown(subscription.cancel);
      addTearDown(linux.dispose);
      platform.serviceDiscoveryResults.addAll([
        unresolved(),
        <BleService>[BleService(_serviceUuid, [])],
      ]);

      final services = await linux.discoverServices();

      expect(services, [_serviceUuid]);
      expect(platform.clearGattCacheCalls, 1);
      expect(states, isNot(contains(device.ConnectionState.disconnected)));
    });

    test('cache refresh advert does not cancel recovery', () async {
      final (linux, states, subscription) = await createLinuxTransport();
      addTearDown(subscription.cancel);
      addTearDown(linux.dispose);
      platform.scanResult = bleDevice(linux.id);
      platform.serviceDiscoveryResults.addAll([
        unresolved(),
        <BleService>[BleService(_serviceUuid, [])],
      ]);
      final connectCallsBeforeRecovery = platform.connectCalls;
      var teardownCalls = 0;
      final teardownSubscription = linux.connectionState
          .where((state) => state == device.ConnectionState.disconnected)
          .listen((_) {
            teardownCalls++;
            unawaited(linux.disconnect());
          });
      addTearDown(teardownSubscription.cancel);

      final services = await linux.discoverServices();

      expect(services, [_serviceUuid]);
      expect(states, isNot(contains(device.ConnectionState.disconnected)));
      expect(teardownCalls, 0);
      expect(platform.disconnectCalls, [linux.id]);
      expect(platform.connectCalls, connectCallsBeforeRecovery + 1);
    });

    test('second unresolved result disconnects exactly once', () async {
      final (linux, states, subscription) = await createLinuxTransport();
      addTearDown(subscription.cancel);
      addTearDown(linux.dispose);
      platform.serviceDiscoveryResults.addAll([unresolved(), unresolved()]);

      await expectLater(
        linux.discoverServices(),
        throwsA(
          isA<UniversalBleException>().having(
            (error) => error.code,
            'code',
            UniversalBleErrorCode.servicesNotResolved,
          ),
        ),
      );

      expect(
        states.where((state) => state == device.ConnectionState.disconnected),
        hasLength(1),
      );
    });

    test('explicit disconnect cancels maintenance before reconnect', () async {
      final (linux, _, subscription) = await createLinuxTransport();
      addTearDown(subscription.cancel);
      addTearDown(linux.dispose);
      platform.clearGattCacheBlocker = Completer<void>();
      platform.serviceDiscoveryResults.add(unresolved());
      final connectCallsBeforeDiscovery = platform.connectCalls;

      final discovery = linux.discoverServices();
      while (platform.clearGattCacheCalls == 0) {
        await pump(1);
      }
      final disconnect = linux.disconnect();
      platform.clearGattCacheBlocker!.complete();

      await expectLater(
        discovery,
        throwsA(
          isA<UniversalBleException>().having(
            (error) => error.code,
            'code',
            UniversalBleErrorCode.operationCancelled,
          ),
        ),
      );
      await disconnect;
      expect(platform.connectCalls, connectCallsBeforeDiscovery);
    });

    test('disconnect during initial discovery prevents reconnect', () async {
      final (linux, _, subscription) = await createLinuxTransport();
      addTearDown(subscription.cancel);
      addTearDown(linux.dispose);
      platform.serviceDiscoveryBlocker = Completer<void>();
      platform.serviceDiscoveryResults.add(unresolved());
      final connectCallsBeforeDiscovery = platform.connectCalls;

      final discovery = linux.discoverServices();
      while (platform.discoverServicesCalls == 0) {
        await pump(1);
      }
      final disconnect = linux.disconnect();
      platform.serviceDiscoveryBlocker!.complete();

      await expectLater(
        discovery,
        throwsA(
          isA<UniversalBleException>().having(
            (error) => error.code,
            'code',
            UniversalBleErrorCode.operationCancelled,
          ),
        ),
      );
      await disconnect;
      expect(platform.connectCalls, connectCallsBeforeDiscovery);
      expect(platform.clearGattCacheCalls, 0);
    });

    test('disconnect during refresh scan stops the scan', () async {
      final (linux, _, subscription) = await createLinuxTransport(
        cacheRefreshScan: const Duration(milliseconds: 50),
      );
      addTearDown(subscription.cancel);
      addTearDown(linux.dispose);
      platform.serviceDiscoveryResults.add(unresolved());

      final discovery = linux.discoverServices();
      while (!platform.scanning) {
        await pump(1);
      }
      final stopCallsBeforeCancellation = platform.stopScanCalls;
      final disconnect = linux.disconnect();

      await expectLater(
        discovery,
        throwsA(
          isA<UniversalBleException>().having(
            (error) => error.code,
            'code',
            UniversalBleErrorCode.operationCancelled,
          ),
        ),
      );
      await disconnect;
      expect(platform.stopScanCalls, greaterThan(stopCallsBeforeCancellation));
      expect(platform.scanning, isFalse);
    });
  });
}
