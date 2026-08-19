import 'dart:async';
import 'dart:typed_data';
import 'package:logging/logging.dart';
import 'package:collection/collection.dart';
import 'package:reaprime/src/models/device/ble_service_identifier.dart';
import 'package:reaprime/src/models/device/device_implementation.dart';
import 'package:reaprime/src/models/device/transport/ble_transport.dart';
import 'package:reaprime/src/models/device/transport/data_transport.dart';
import 'package:rxdart/subjects.dart';

import 'package:reaprime/src/models/device/device.dart';

import 'package:reaprime/src/models/errors.dart';
import '../../scale.dart';

class FelicitaArc implements Scale {
  final Logger _log = Logger('FelicitaArc');

  static final BleServiceIdentifier serviceIdentifier =
      BleServiceIdentifier.short('ffe0');
  static final BleServiceIdentifier dataCharacteristic =
      BleServiceIdentifier.short('ffe1');

  final String _deviceId;

  final StreamController<ScaleSnapshot> _streamController =
      StreamController.broadcast();

  final BLETransport _transport;

  FelicitaArc({required BLETransport transport})
    : _transport = transport,
      _deviceId = transport.id;

  @override
  Stream<ScaleSnapshot> get currentSnapshot => _streamController.stream;

  @override
  String get deviceId => _deviceId;

  @override
  DeviceImplementation get implementation => DeviceImplementation.felicitaArc;

  @override
  TransportType get transportType => _transport.transportType;

  @override
  String get name => "Felicita Arc";

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
            _notificationsSubscription?.cancel();
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
        dataCharacteristic.long,
        data,
      );
    } on DeviceNotConnectedException {
      // Transport already emitted disconnected.
    }
  }

  @override
  Future<void> tare() async {
    final writeData = Uint8List(1);
    writeData[0] = 0x54;
    await _safeWrite(writeData);
  }

  @override
  Future<void> sleepDisplay() async {
    await disconnect();
  }

  @override
  Future<void> wakeDisplay() async {}

  StreamSubscription<Uint8List>? _notificationsSubscription;

  Future<void> _registerNotifications() async {
    await _transport.subscribe(
      serviceIdentifier.long,
      dataCharacteristic.long,
      _parseNotification,
    );
  }

  static const int minBattLevel = 129;
  static const int maxBattLevel = 158;

  void _parseNotification(List<int> data) {
    if (data.length != 18) {
      return;
    }
    var negative = data.slice(2).first - 45 == 0;
    var weight = int.parse(
      data.slice(3, 9).map((value) => value - 48).join(''),
    );
    if (negative) {
      weight *= -1;
    }
    var battery =
        ((data[15] - minBattLevel) / (maxBattLevel - minBattLevel) * 100)
            .round();
    _streamController.add(
      ScaleSnapshot(
        timestamp: DateTime.now(),
        weight: weight / 100,
        batteryLevel: battery,
      ),
    );
  }

  @override
  Future<void> startTimer() async {
    await _safeWrite(Uint8List.fromList([0x52]));
  }

  @override
  Future<void> stopTimer() async {
    await _safeWrite(Uint8List.fromList([0x53]));
  }

  @override
  Future<void> resetTimer() async {
    await _safeWrite(Uint8List.fromList([0x43]));
  }
}
