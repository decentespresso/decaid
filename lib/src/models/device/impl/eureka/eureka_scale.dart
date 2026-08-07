import 'dart:async';
import 'dart:typed_data';
import 'package:reaprime/src/models/device/ble_service_identifier.dart';
import 'package:reaprime/src/models/device/device_implementation.dart';
import 'package:reaprime/src/models/device/transport/ble_transport.dart';
import 'package:reaprime/src/models/device/transport/data_transport.dart';
import 'package:rxdart/subjects.dart';

import 'package:reaprime/src/models/device/device.dart';

import 'package:reaprime/src/models/errors.dart';
import '../../scale.dart';

class EurekaScale implements Scale {
  static final BleServiceIdentifier serviceIdentifier =
      BleServiceIdentifier.short('fff0');
  static final BleServiceIdentifier dataCharacteristic =
      BleServiceIdentifier.short('fff1');
  static final BleServiceIdentifier commandCharacteristic =
      BleServiceIdentifier.short('fff2');
  static final BleServiceIdentifier batteryService = BleServiceIdentifier.short(
    '180f',
  );
  static final BleServiceIdentifier batteryCharacteristic =
      BleServiceIdentifier.short('2a19');

  final String _deviceId;

  final StreamController<ScaleSnapshot> _streamController =
      StreamController.broadcast();

  final BLETransport _transport;

  int _batteryLevel = 0;

  EurekaScale({required BLETransport transport})
    : _transport = transport,
      _deviceId = transport.id;

  @override
  Stream<ScaleSnapshot> get currentSnapshot => _streamController.stream;

  @override
  String get deviceId => _deviceId;

  @override
  DeviceImplementation get implementation => DeviceImplementation.eurekaScale;

  @override
  TransportType get transportType => _transport.transportType;

  @override
  String get name => "Eureka Precisa";

  final StreamController<ConnectionState> _connectionStateController =
      BehaviorSubject.seeded(ConnectionState.discovered);

  @override
  Stream<ConnectionState> get connectionState =>
      _connectionStateController.stream;

  @override
  Future<void> onConnect() async {
    if (await _transport.connectionState.first == ConnectionState.connected) {
      return;
    }
    _connectionStateController.add(ConnectionState.connecting);

    StreamSubscription<ConnectionState>? disconnectSub;

    try {
      await _transport.connect();

      disconnectSub = _transport.connectionState
          .where((state) => state == ConnectionState.disconnected)
          .listen((_) {
            _connectionStateController.add(ConnectionState.disconnected);
            disconnectSub?.cancel();
          });

      final services = await _transport.discoverServices();
      if (!serviceIdentifier.matchesAny(services)) {
        throw Exception(
          'Expected service ${serviceIdentifier.long} not found. '
          'Discovered services: $services',
        );
      }
      await _registerNotifications();
      _readBattery();
      _connectionStateController.add(ConnectionState.connected);
    } catch (e) {
      disconnectSub?.cancel();
      _connectionStateController.add(ConnectionState.disconnected);
      try {
        await _transport.disconnect();
      } catch (_) {}
    }
  }

  @override
  disconnect() async {
    await _transport.disconnect();
  }

  @override
  DeviceType get type => DeviceType.scale;

  /// Safe write — catches [DeviceNotConnectedException] from the transport
  /// layer's gone-device handler so a write to a disconnected scale doesn't
  /// escape to the framework error handler as a FATAL (Crashlytics fa51312d).
  Future<void> _safeWrite(Uint8List data) async {
    try {
      await _transport.write(
        serviceIdentifier.long,
        commandCharacteristic.long,
        data,
        withResponse: false,
      );
    } on DeviceNotConnectedException {
      // Transport already emitted disconnected; the connectionState
      // listener handles cleanup.
    }
  }

  @override
  Future<void> tare() async {
    await _safeWrite(Uint8List.fromList([0xAA, 0x02, 0x31, 0x31]));
  }

  /// Start the scale timer
  @override
  Future<void> startTimer() async {
    await _safeWrite(Uint8List.fromList([0xAA, 0x02, 0x33, 0x33]));
  }

  /// Stop the scale timer
  @override
  Future<void> stopTimer() async {
    await _safeWrite(Uint8List.fromList([0xAA, 0x02, 0x34, 0x34]));
  }

  /// Reset the scale timer
  @override
  Future<void> resetTimer() async {
    await _safeWrite(Uint8List.fromList([0xAA, 0x02, 0x35, 0x35]));
  }

  @override
  Future<void> sleepDisplay() async {
    await disconnect();
  }

  @override
  Future<void> wakeDisplay() async {}

  Future<void> _registerNotifications() async {
    await _transport.subscribe(
      serviceIdentifier.long,
      dataCharacteristic.long,
      _parseNotification,
    );
  }

  void _readBattery() async {
    try {
      final data = await _transport.read(
        batteryService.long,
        batteryCharacteristic.long,
      );
      if (data.isNotEmpty) {
        _batteryLevel = data[0];
      }
    } catch (_) {
      // Battery read may fail on some devices; ignore
    }
  }

  void _parseNotification(List<int> data) {
    if (data.length < 9) return;

    bool isNeg = data[6] != 0;
    int weight = data[7] + (data[8] << 8);
    if (isNeg) {
      weight = weight * -1;
    }

    _streamController.add(
      ScaleSnapshot(
        timestamp: DateTime.now(),
        weight: weight / 10.0,
        batteryLevel: _batteryLevel,
      ),
    );
  }
}
