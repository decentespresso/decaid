import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/device/device.dart' as device;
import 'package:reaprime/src/services/ble/universal_ble_transport.dart';
import 'package:universal_ble/universal_ble.dart';

class _MtuRecordingBlePlatform extends UniversalBlePlatform {
  final List<(String, int)> mtuRequests = [];

  bool throwOnRequestMtu = false;
  UniversalBleErrorCode? readErrorCode;
  bool systemConnected = true;
  bool attached = false;
  int connectCalls = 0;
  int physicalConnectCalls = 0;

  @override
  Future<int> requestMtu(String deviceId, int expectedMtu) async {
    mtuRequests.add((deviceId, expectedMtu));
    if (throwOnRequestMtu) {
      throw UniversalBleException(
        code: UniversalBleErrorCode.failed,
        message: 'simulated MTU negotiation failure',
      );
    }
    return expectedMtu;
  }

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
  }) async {}

  @override
  Future<void> stopScan() async {}

  @override
  Future<bool> isScanning() async => false;

  @override
  Future<void> connect(
    String deviceId, {
    Duration? connectionTimeout,
    bool autoConnect = false,
    ConnectionPlatformConfig? platformConfig,
  }) async {
    connectCalls++;
    attached = true;
    if (!systemConnected) physicalConnectCalls++;
    systemConnected = true;
    updateConnection(deviceId, true);
  }

  @override
  Future<void> disconnect(String deviceId) async {
    systemConnected = false;
    attached = false;
    updateConnection(deviceId, false);
  }

  @override
  Future<List<BleService>> discoverServices(
    String deviceId,
    bool withDescriptors,
  ) async {
    if (!attached) throw StateError('Peripheral is not attached');
    return [];
  }

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
  }) async {
    final code = readErrorCode;
    if (code != null) {
      throw UniversalBleException(
        code: code,
        message: 'simulated read failure',
      );
    }
    return Uint8List(0);
  }

  @override
  Future<void> writeValue(
    String deviceId,
    String service,
    String characteristic,
    Uint8List value,
    BleOutputProperty bleOutputProperty,
  ) async {}

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
    return systemConnected
        ? BleConnectionState.connected
        : BleConnectionState.disconnected;
  }

  @override
  Future<List<BleDevice>> getSystemDevices(List<String>? withServices) async =>
      [];

  void emitDisconnected(String deviceId) {
    systemConnected = false;
    attached = false;
    updateConnection(deviceId, false);
  }
}

void main() {
  late _MtuRecordingBlePlatform platform;
  var deviceCounter = 0;
  late String deviceId;

  setUp(() {
    platform = _MtuRecordingBlePlatform();
    UniversalBle.setInstance(platform);
    UniversalBle.clearQueue();
    deviceId = 'AA:BB:CC:DD:FF:${(deviceCounter++).toString().padLeft(2, '0')}';
  });

  UniversalBleTransport transport({
    required bool android,
    required bool linux,
    bool flag = false,
  }) => UniversalBleTransport(
    device: BleDevice(deviceId: deviceId, name: 'Bengle'),
    isAndroidOverride: android,
    isLinuxOverride: linux,
    requestLargeMtuNonAndroid: flag,
  );

  test('missing characteristic on a live link does not disconnect', () async {
    final value = transport(android: false, linux: false);
    final states = <device.ConnectionState>[];
    final subscription = value.connectionState.listen(states.add);
    await value.connect();
    platform.readErrorCode = UniversalBleErrorCode.characteristicNotFound;

    await expectLater(
      value.read(
        '0000180f-0000-1000-8000-00805f9b34fb',
        '00002a19-0000-1000-8000-00805f9b34fb',
      ),
      throwsA(isA<UniversalBleException>()),
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(states, isNot(contains(device.ConnectionState.disconnected)));
    await subscription.cancel();
    await value.dispose();
  });

  test(
    'missing characteristic after the link died reports disconnected',
    () async {
      final value = transport(android: false, linux: false);
      final states = <device.ConnectionState>[];
      final subscription = value.connectionState.listen(states.add);
      await value.connect();
      platform.readErrorCode = UniversalBleErrorCode.characteristicNotFound;
      platform.systemConnected = false;

      await expectLater(
        value.read(
          '0000180f-0000-1000-8000-00805f9b34fb',
          '00002a19-0000-1000-8000-00805f9b34fb',
        ),
        throwsA(isA<UniversalBleException>()),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(states, contains(device.ConnectionState.disconnected));
      await subscription.cancel();
      await value.dispose();
    },
  );

  test('Android requests 517 once with the flag off or on', () async {
    for (final flag in [false, true]) {
      final value = transport(android: true, linux: false, flag: flag);
      await value.connect();
      await value.dispose();
    }

    expect(platform.mtuRequests, [(deviceId, 517), (deviceId, 517)]);
  });

  test('Linux never requests an MTU', () async {
    final value = transport(android: false, linux: true, flag: true);
    await value.connect();
    expect(platform.mtuRequests, isEmpty);
    await value.dispose();
  });

  test('other native platforms request only when the flag is on', () async {
    var value = transport(android: false, linux: false);
    await value.connect();
    await value.dispose();
    expect(platform.mtuRequests, isEmpty);

    value = transport(android: false, linux: false, flag: true);
    await value.connect();
    expect(platform.mtuRequests, [(deviceId, 517)]);
    await value.dispose();
  });

  test('failed negotiation does not fail connect', () async {
    platform.throwOnRequestMtu = true;
    final value = transport(android: false, linux: false, flag: true);
    await value.connect();
    expect(platform.mtuRequests, [(deviceId, 517)]);
    await value.dispose();
  });

  test('reconnect requests once per physical connection', () async {
    final value = transport(android: false, linux: false, flag: true);
    await value.connect();
    await value.disconnect();
    await value.connect();
    expect(platform.mtuRequests, [(deviceId, 517), (deviceId, 517)]);
    await value.dispose();
  });

  test(
    'system-connected transport attaches before service discovery',
    () async {
      final value = transport(android: false, linux: false);
      final states = <device.ConnectionState>[];
      final subscription = value.connectionState.listen(states.add);

      await value.connect();
      await value.discoverServices();
      await Future<void>.delayed(Duration.zero);
      expect(platform.connectCalls, 1);
      expect(platform.physicalConnectCalls, 0);
      expect(platform.attached, isTrue);
      expect(states, contains(device.ConnectionState.connected));

      platform.emitDisconnected(deviceId);
      await Future<void>.delayed(Duration.zero);
      expect(states.last, device.ConnectionState.disconnected);

      await subscription.cancel();
      await value.dispose();
    },
  );

  test('disconnected transport performs a native connect', () async {
    platform.systemConnected = false;
    final value = transport(android: false, linux: false);

    await value.connect();

    expect(platform.connectCalls, 1);
    expect(platform.physicalConnectCalls, 1);
    await value.dispose();
  });
}
