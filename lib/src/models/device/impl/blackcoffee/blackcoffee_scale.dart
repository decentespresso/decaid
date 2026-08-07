import 'dart:async';
import 'dart:typed_data';
import 'package:reaprime/src/models/device/ble_service_identifier.dart';
import 'package:reaprime/src/models/device/device_implementation.dart';
import 'package:reaprime/src/models/device/transport/ble_transport.dart';
import 'package:reaprime/src/models/device/transport/data_transport.dart';
import 'package:rxdart/subjects.dart';

import 'package:reaprime/src/models/device/device.dart';

import '../../scale.dart';

class BlackCoffeeScale implements Scale {
  static final BleServiceIdentifier serviceIdentifier =
      BleServiceIdentifier.short('ffb0');
  static final BleServiceIdentifier dataCharacteristic =
      BleServiceIdentifier.short('ffb2');

  final String _deviceId;

  final StreamController<ScaleSnapshot> _streamController =
      StreamController.broadcast();

  final BLETransport _transport;

  double _weightAtTare = 0.0;

  BlackCoffeeScale({required BLETransport transport})
    : _transport = transport,
      _deviceId = transport.id;

  @override
  Stream<ScaleSnapshot> get currentSnapshot => _streamController.stream;

  @override
  String get deviceId => _deviceId;

  @override
  DeviceImplementation get implementation =>
      DeviceImplementation.blackCoffeeScale;

  @override
  TransportType get transportType => _transport.transportType;

  @override
  String get name => "BlackCoffee Scale";

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

  @override
  Future<void> tare() async {
    // BlackCoffee scale doesn't support BLE tare commands
    // Implement software tare by recording the current weight offset
    _weightAtTare = _lastRawWeight;
  }

  @override
  Future<void> sleepDisplay() async {
    // BlackCoffee scale doesn't have documented display sleep commands
    // Fallback to disconnect as per scale interface contract
    await disconnect();
  }

  @override
  Future<void> wakeDisplay() async {
    // BlackCoffee scale doesn't have documented wake display commands
    // This is a no-op
  }

  double _lastRawWeight = 0.0;

  Future<void> _registerNotifications() async {
    await _transport.subscribe(
      serviceIdentifier.long,
      dataCharacteristic.long,
      _parseNotification,
    );
  }

  void _parseNotification(List<int> data) {
    if (data.length < 7) {
      return;
    }

    final weightRaw = _getInt32(data.sublist(3, 7));
    var weight = weightRaw / 1000.0;

    if (data[2] >= 128) {
      weight = -weight;
    }

    _lastRawWeight = weight;

    _streamController.add(
      ScaleSnapshot(
        timestamp: DateTime.now(),
        weight: weight - _weightAtTare,
        batteryLevel: 0,
      ),
    );
  }

  int _getInt32(List<int> buffer) {
    final bytes = ByteData(buffer.length);
    for (var i = 0; i < buffer.length; i++) {
      bytes.setUint8(i, buffer[i]);
    }
    return bytes.getInt32(0, Endian.big);
  }

  @override
  Future<void> startTimer() async {}

  @override
  Future<void> stopTimer() async {}

  @override
  Future<void> resetTimer() async {}
}
