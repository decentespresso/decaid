import 'dart:async';
import 'dart:typed_data';

import 'package:reaprime/src/models/device/device.dart';
import 'package:rxdart/rxdart.dart';
import 'package:universal_ble/universal_ble.dart';

import 'fake_ble_transport.dart';

class PluginBleFixtureTransport extends FakeBleTransport {
  PluginBleFixtureTransport(this.physicalId);

  final String physicalId;
  final states = BehaviorSubject.seeded(ConnectionState.discovered);
  final operations = <String>[];
  Completer<void>? teardown;
  int connectCalls = 0;
  int disposeCalls = 0;
  final disposed = Completer<void>();

  @override
  String get id => physicalId;
  @override
  Stream<ConnectionState> get connectionState => states.stream;
  @override
  Future<ConnectionState> getConnectionState() async => states.value;

  @override
  Future<void> connect() async {
    connectCalls++;
    states.add(ConnectionState.connected);
  }

  @override
  Future<List<String>> discoverServices() async => ['180f'];

  @override
  Future<void> subscribe(
    String service,
    String characteristic,
    void Function(Uint8List) callback,
  ) async {
    operations.add('subscribe:$service:$characteristic');
    await super.subscribe(service, characteristic, callback);
    callback(Uint8List.fromList([52]));
  }

  @override
  Future<void> unsubscribe(String service, String characteristic) async {
    operations.add('unsubscribe:$service:$characteristic');
    subscribers.remove(characteristic);
  }

  @override
  Future<void> resetSubscription(
    String service,
    String characteristic,
    void Function(Uint8List) callback,
  ) async {
    await unsubscribe(service, characteristic);
    await subscribe(service, characteristic, callback);
  }

  @override
  Future<void> disconnect() => disconnectConfirmed();

  @override
  Future<void> disconnectConfirmed() async {
    await teardown?.future;
    if (!states.isClosed) states.add(ConnectionState.disconnected);
  }

  @override
  Future<void> dispose() async {
    if (disposeCalls++ != 0) return;
    subscribers.clear();
    await states.close();
    await super.dispose();
    disposed.complete();
  }
}

class PluginBleFixturePlatform extends UniversalBlePlatform {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);

  final systemDevices = <BleDevice>[];
  bool scanning = false;
  final started = Completer<void>();
  final connectionStates = <String, BleConnectionState>{};
  final notificationProperties = <BleInputProperty>[];
  final writeProperties = <BleOutputProperty>[];
  final scanFilters = <ScanFilter?>[];
  Object? readError;
  Object? writeError;
  BleDevice? firstAdvertisement;

  @override
  Future<void> connect(
    String deviceId, {
    Duration? connectionTimeout,
    bool autoConnect = false,
    ConnectionPlatformConfig? platformConfig,
  }) async {
    connectionStates[deviceId] = BleConnectionState.connected;
    updateConnection(deviceId, true);
  }

  @override
  Future<void> disconnect(String deviceId) async {
    connectionStates[deviceId] = BleConnectionState.disconnected;
    updateConnection(deviceId, false);
  }

  @override
  Future<List<BleService>> discoverServices(
    String deviceId,
    bool withDescriptors,
  ) async => [BleService('0000180f-0000-1000-8000-00805f9b34fb', [])];
  @override
  Future<void> setNotifiable(
    String deviceId,
    String service,
    String characteristic,
    BleInputProperty bleInputProperty,
  ) async {
    notificationProperties.add(bleInputProperty);
    if (bleInputProperty == BleInputProperty.notification) {
      updateCharacteristicValue(
        deviceId,
        characteristic,
        Uint8List.fromList([52]),
        null,
      );
    }
  }

  @override
  Future<Uint8List> readValue(
    String deviceId,
    String service,
    String characteristic, {
    Duration? timeout,
  }) async {
    if (readError case final error?) throw error;
    return Uint8List.fromList([52]);
  }

  @override
  Future<void> writeValue(
    String deviceId,
    String service,
    String characteristic,
    Uint8List value,
    BleOutputProperty bleOutputProperty,
  ) async {
    writeProperties.add(bleOutputProperty);
    if (writeError case final error?) throw error;
  }

  @override
  Future<AvailabilityState> getBluetoothAvailabilityState() async =>
      AvailabilityState.poweredOn;
  @override
  Future<void> startScan({
    ScanFilter? scanFilter,
    PlatformConfig? platformConfig,
  }) async {
    scanFilters.add(scanFilter);
    scanning = true;
    if (!started.isCompleted) started.complete();
    if (firstAdvertisement case final device?) updateScanResult(device);
  }

  @override
  Future<void> stopScan() async {
    scanning = false;
  }

  @override
  Future<bool> isScanning() async => scanning;
  @override
  Future<List<BleDevice>> getSystemDevices(List<String>? withServices) async =>
      systemDevices;
  @override
  Future<BleConnectionState> getConnectionState(String deviceId) async =>
      connectionStates[deviceId] ?? BleConnectionState.disconnected;
}
