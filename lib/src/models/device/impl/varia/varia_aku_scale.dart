import 'dart:async';
import 'dart:typed_data';
import 'package:logging/logging.dart';
import 'package:reaprime/src/models/device/ble_service_identifier.dart';
import 'package:reaprime/src/models/device/device_implementation.dart';
import 'package:reaprime/src/models/device/transport/ble_transport.dart';
import 'package:reaprime/src/models/device/transport/data_transport.dart';
import 'package:rxdart/subjects.dart';

import 'package:reaprime/src/models/device/device.dart';

import 'package:reaprime/src/models/errors.dart';
import '../../scale.dart';

class VariaAkuScale implements Scale {
  final Logger _log = Logger('VariaAkuScale');

  static final BleServiceIdentifier serviceIdentifier =
      BleServiceIdentifier.short('fff0');
  static final BleServiceIdentifier dataCharacteristic =
      BleServiceIdentifier.short('fff1');
  static final BleServiceIdentifier commandCharacteristic =
      BleServiceIdentifier.short('fff2');

  final String _deviceId;

  final StreamController<ScaleSnapshot> _streamController =
      StreamController.broadcast();

  final BLETransport _transport;

  int _batteryLevel = 0;

  VariaAkuScale({required BLETransport transport})
    : _transport = transport,
      _deviceId = transport.id;

  @override
  Stream<ScaleSnapshot> get currentSnapshot => _streamController.stream;

  @override
  String get deviceId => _deviceId;

  @override
  DeviceImplementation get implementation => DeviceImplementation.variaAkuScale;

  @override
  TransportType get transportType => _transport.transportType;

  @override
  String get name => "Varia AKU";

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

  Future<void> _safeWrite(Uint8List data) async {
    try {
      await _transport.write(
        serviceIdentifier.long,
        commandCharacteristic.long,
        data,
        withResponse: false,
      );
    } on DeviceNotConnectedException {
      // Transport already emitted disconnected.
    }
  }

  @override
  Future<void> tare() async {
    await _safeWrite(Uint8List.fromList([0xFA, 0x82, 0x01, 0x01, 0x82]));
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

  void _parseNotification(List<int> data) {
    if (data.length < 4) return;

    int command = data[1];
    int length = data[2];

    if (command == 0x01 && length == 0x03 && data.length >= 7) {
      int w1 = data[3];
      int w2 = data[4];
      int w3 = data[5];

      bool isNegative = (w1 & 0x10) != 0;

      int weightRaw = ((w1 & 0x0F) << 16) | (w2 << 8) | w3;
      double weight = weightRaw / 100.0;

      if (isNegative) {
        weight = -weight;
      }

      _streamController.add(
        ScaleSnapshot(
          timestamp: DateTime.now(),
          weight: weight,
          batteryLevel: _batteryLevel,
        ),
      );
    } else if (command == 0x85 && length == 0x01 && data.length >= 5) {
      _batteryLevel = data[3];
    }
  }

  @override
  Future<void> startTimer() async {}

  @override
  Future<void> stopTimer() async {}

  @override
  Future<void> resetTimer() async {}
}
