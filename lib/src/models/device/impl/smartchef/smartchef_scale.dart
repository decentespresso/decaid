import 'dart:async';
import 'package:logging/logging.dart';
import 'package:reaprime/src/models/device/ble_service_identifier.dart';
import 'package:reaprime/src/models/device/device_implementation.dart';
import 'package:reaprime/src/models/device/transport/ble_transport.dart';
import 'package:reaprime/src/models/device/transport/data_transport.dart';
import 'package:rxdart/subjects.dart';

import 'package:reaprime/src/models/device/device.dart';

import '../../scale.dart';

class SmartChefScale implements Scale {
  final Logger _log = Logger('SmartChefScale');

  static final BleServiceIdentifier serviceIdentifier =
      BleServiceIdentifier.short('fff0');
  static final BleServiceIdentifier dataCharacteristic =
      BleServiceIdentifier.short('fff1');

  final String _deviceId;

  final StreamController<ScaleSnapshot> _streamController =
      StreamController.broadcast();

  final BLETransport _transport;

  double _weightAtTare = 0.0;

  SmartChefScale({required BLETransport transport})
    : _transport = transport,
      _deviceId = transport.id;

  @override
  Stream<ScaleSnapshot> get currentSnapshot => _streamController.stream;

  @override
  String get deviceId => _deviceId;

  @override
  DeviceImplementation get implementation =>
      DeviceImplementation.smartChefScale;

  @override
  TransportType get transportType => _transport.transportType;

  @override
  String get name => "SmartChef Scale";

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
      _log.warning('Connect failed: $e');
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
    _weightAtTare = _lastRawWeight;
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

  double _lastRawWeight = 0.0;

  void _parseNotification(List<int> data) {
    if (data.length < 7) return;

    double weight = ((data[5] << 8) + data[6]) / 10.0;

    if (data[3] > 10) {
      weight *= -1;
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

  @override
  Future<void> startTimer() async {}

  @override
  Future<void> stopTimer() async {}

  @override
  Future<void> resetTimer() async {}
}
