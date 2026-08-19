import 'dart:async';
import 'dart:typed_data';
import 'package:logging/logging.dart';
import 'package:reaprime/src/models/device/ble_service_identifier.dart';
import 'package:reaprime/src/models/device/device_implementation.dart';
import 'package:reaprime/src/models/device/transport/ble_transport.dart';
import 'package:reaprime/src/models/device/transport/data_transport.dart';
import 'package:rxdart/subjects.dart';

import 'package:reaprime/src/models/device/device.dart';

import '../../scale.dart';

class DifluidScale implements Scale {
  final Logger _log = Logger('DifluidScale');

  static final BleServiceIdentifier serviceIdentifier =
      BleServiceIdentifier.short('00ee');
  static final BleServiceIdentifier dataCharacteristic =
      BleServiceIdentifier.short('aa01');

  static final List<int> _cmdStartWeightNotifications = [
    0xDF,
    0xDF,
    0x01,
    0x00,
    0x01,
    0x01,
    0xC1,
  ];
  static final List<int> _cmdSetUnitToGram = [
    0xDF,
    0xDF,
    0x01,
    0x04,
    0x01,
    0x00,
    0xC4,
  ];
  static final List<int> _cmdTare = [0xDF, 0xDF, 0x03, 0x02, 0x01, 0x01, 0xC5];

  final String _deviceId;

  final StreamController<ScaleSnapshot> _streamController =
      StreamController.broadcast();

  final BLETransport _transport;

  DifluidScale({required BLETransport transport})
    : _transport = transport,
      _deviceId = transport.id;

  @override
  Stream<ScaleSnapshot> get currentSnapshot => _streamController.stream;

  @override
  String get deviceId => _deviceId;

  @override
  DeviceImplementation get implementation => DeviceImplementation.difluidScale;

  @override
  TransportType get transportType => _transport.transportType;

  @override
  String get name => "Difluid Microbalance";

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
    await _transport.write(
      serviceIdentifier.long,
      dataCharacteristic.long,
      Uint8List.fromList(_cmdTare),
      withResponse: true,
    );
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

    await _transport.write(
      serviceIdentifier.long,
      dataCharacteristic.long,
      Uint8List.fromList(_cmdStartWeightNotifications),
      withResponse: true,
    );

    await _transport.write(
      serviceIdentifier.long,
      dataCharacteristic.long,
      Uint8List.fromList(_cmdSetUnitToGram),
      withResponse: true,
    );
  }

  void _parseNotification(List<int> data) {
    if (data.length < 19 || data[3] != 0) {
      return;
    }

    if (data[17] != 0) {
      _transport.write(
        serviceIdentifier.long,
        dataCharacteristic.long,
        Uint8List.fromList(_cmdSetUnitToGram),
        withResponse: true,
      );
    }

    final weightRaw = _getInt32(data.sublist(5, 9));
    final weight = weightRaw / 10.0;

    _streamController.add(
      ScaleSnapshot(timestamp: DateTime.now(), weight: weight, batteryLevel: 0),
    );
  }

  int _getInt32(List<int> buffer) {
    final bytes = ByteData(buffer.length);
    for (var i = 0; i < buffer.length; i++) {
      bytes.setUint8(i, buffer[i]);
    }
    return bytes.getInt32(0, Endian.big);
  }

  static final List<int> _cmdTimerStart = [
    0xDF,
    0xDF,
    0x03,
    0x02,
    0x01,
    0x00,
    0xC4,
  ];
  static final List<int> _cmdTimerStop = [
    0xDF,
    0xDF,
    0x03,
    0x01,
    0x01,
    0x00,
    0xC3,
  ];

  @override
  Future<void> startTimer() async {
    await _transport.write(
      serviceIdentifier.long,
      dataCharacteristic.long,
      Uint8List.fromList(_cmdTimerStart),
      withResponse: true,
    );
  }

  @override
  Future<void> stopTimer() async {
    await _transport.write(
      serviceIdentifier.long,
      dataCharacteristic.long,
      Uint8List.fromList(_cmdTimerStop),
      withResponse: true,
    );
    await _transport.write(
      serviceIdentifier.long,
      dataCharacteristic.long,
      Uint8List.fromList(_cmdTimerStart),
      withResponse: true,
    );
  }

  @override
  Future<void> resetTimer() async {}
}
