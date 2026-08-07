import 'dart:async';
import 'dart:typed_data';

import 'package:logging/logging.dart';
import 'package:reaprime/src/models/device/ble_service_identifier.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/sensor.dart';
import 'package:reaprime/src/models/device/device_implementation.dart';
import 'package:reaprime/src/models/device/transport/ble_transport.dart';
import 'package:reaprime/src/models/device/transport/data_transport.dart';
import 'package:rxdart/rxdart.dart';

class DecentTemp implements Sensor {
  static final BleServiceIdentifier serviceIdentifier =
      BleServiceIdentifier.long('0001c155-5f7c-ce0b-3342-a58cf0def2d9');
  static final BleServiceIdentifier temperatureCharacteristic =
      BleServiceIdentifier.long('0002c155-5f7c-ce0b-3342-a58cf0def2d9');

  late Logger _log;
  final BLETransport _transport;

  DecentTemp({required BLETransport transport}) : _transport = transport {
    _log = Logger("DecentTemp(${transport.name})");
  }

  @override
  Stream<ConnectionState> get connectionState =>
      _connectionStateController.stream;

  final BehaviorSubject<Map<String, dynamic>> _streamSubject =
      BehaviorSubject();
  @override
  Stream<Map<String, dynamic>> get data => _streamSubject.stream;

  @override
  String get deviceId => _transport.id;

  @override
  DeviceImplementation get implementation => DeviceImplementation.decentTemp;

  @override
  TransportType get transportType => _transport.transportType;

  @override
  Future<void> disconnect() async {
    await _transport.disconnect();
  }

  @override
  Future<Map<String, dynamic>> execute(
    String commandId,
    Map<String, dynamic>? parameters,
  ) {
    throw UnimplementedError();
  }

  @override
  SensorInfo get info => SensorInfo(
    name: "Decent Temp",
    vendor: "Decent Espresso",
    dataChannels: [
      DataChannel(key: 'temperature', type: 'number', unit: 'Celsius'),
    ],
    commands: [],
  );

  @override
  String get name => 'Decent Temp';

  final StreamController<ConnectionState> _connectionStateController =
      BehaviorSubject.seeded(ConnectionState.discovered);

  StreamSubscription<ConnectionState>? subscription;

  @override
  Future<void> onConnect() async {
    _log.info("on connect (id=$deviceId)");
    if (await _transport.connectionState.first == .connected) {
      return;
    }
    _connectionStateController.add(.connecting);
    try {
      await _transport.connect();
      subscription = _transport.connectionState
          .where((state) => state == ConnectionState.disconnected)
          .listen((_) {
            _log.info("Transport disconnected");
            disconnect();
          });

      final services = await _transport.discoverServices();
      if (!serviceIdentifier.matchesAny(services)) {
        throw Exception(
          'Expected service ${serviceIdentifier.long} not found. '
          'Discovered services: $services',
        );
      }
      await _registerNotifications();
    } catch (e) {
      _log.warning('Failed to initialize temp: $e');
      subscription?.cancel();
      _connectionStateController.add(ConnectionState.disconnected);
      try {
        await _transport.disconnect();
      } catch (_) {}
    }
  }

  Future<void> _registerNotifications() async {
    await _transport.subscribe(
      serviceIdentifier.long,
      temperatureCharacteristic.long,
      _parseNotification,
    );
  }

  void _parseNotification(List<int> data) {
    var b = ByteData(2);
    b.setInt8(0, data[1]);
    b.setInt8(1, data[0]);

    _streamSubject.add({'temperature': b.getInt16(0) / 100});
  }

  @override
  DeviceType get type => .sensor;
}
