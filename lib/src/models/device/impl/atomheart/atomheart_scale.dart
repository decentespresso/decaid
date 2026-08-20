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

class AtomheartScale implements Scale {
  final Logger _log = Logger('AtomheartScale');

  static final BleServiceIdentifier serviceIdentifier =
      BleServiceIdentifier.long('b905eaea-2e63-0e04-7582-7913f10d8f81');
  static final BleServiceIdentifier dataCharacteristic =
      BleServiceIdentifier.long('ad736c5f-bbc9-1f96-d304-cb5d5f41e160');
  static final BleServiceIdentifier commandCharacteristic =
      BleServiceIdentifier.long('4f9a45ba-8e1b-4e07-e157-0814d393b968');

  static const _notificationAttempts = 3;
  static const _frameLength = 10;

  final String _deviceId;

  final StreamController<ScaleSnapshot> _streamController =
      StreamController.broadcast();

  final BLETransport _transport;
  final Duration _notificationTimeout;
  Completer<void>? _firstValidFrame;

  AtomheartScale({
    required BLETransport transport,
    Duration notificationTimeout = const Duration(milliseconds: 800),
  }) : _transport = transport,
       _notificationTimeout = notificationTimeout,
       _deviceId = transport.id;

  @override
  Stream<ScaleSnapshot> get currentSnapshot => _streamController.stream;

  @override
  String get deviceId => _deviceId;

  @override
  DeviceImplementation get implementation =>
      DeviceImplementation.atomheartScale;

  @override
  TransportType get transportType => _transport.transportType;

  @override
  String get name => "Atomheart Eclair";

  final BehaviorSubject<ConnectionState> _connectionStateController =
      BehaviorSubject.seeded(ConnectionState.discovered);

  @override
  Stream<ConnectionState> get connectionState =>
      _connectionStateController.stream;

  @override
  Future<void> onConnect() async {
    if (_connectionStateController.value == ConnectionState.connected &&
        await _transport.connectionState.first == ConnectionState.connected) {
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
      await _confirmNotifications();
      if (_connectionStateController.value != ConnectionState.connecting) {
        throw const DeviceNotConnectedException.scale();
      }
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
    await _safeWrite(Uint8List.fromList([0x54, 0x01, 0x01]));
  }

  @override
  Future<void> sleepDisplay() async {
    await disconnect();
  }

  @override
  Future<void> wakeDisplay() async {}

  @override
  Future<void> startTimer() async {
    await _safeWrite(Uint8List.fromList([0x53, 0x01, 0x01]));
  }

  @override
  Future<void> stopTimer() async {
    await _safeWrite(Uint8List.fromList([0x45, 0x01, 0x01]));
  }

  @override
  Future<void> resetTimer() async {
    await _safeWrite(Uint8List.fromList([0x52, 0x01, 0x01]));
  }

  Future<void> _registerNotifications() async {
    await _transport.subscribe(
      serviceIdentifier.long,
      dataCharacteristic.long,
      _parseNotification,
    );
  }

  Future<void> _confirmNotifications() async {
    final firstValidFrame = Completer<void>();
    _firstValidFrame = firstValidFrame;
    try {
      for (var attempt = 0; attempt < _notificationAttempts; attempt++) {
        if (attempt == 0) {
          await _registerNotifications();
        } else {
          await _transport.resetSubscription(
            serviceIdentifier.long,
            dataCharacteristic.long,
            _parseNotification,
          );
        }
        if (firstValidFrame.isCompleted) return;
        try {
          await firstValidFrame.future.timeout(_notificationTimeout);
          return;
        } on TimeoutException {
          if (attempt == _notificationAttempts - 1) rethrow;
        }
      }
    } finally {
      if (identical(_firstValidFrame, firstValidFrame)) {
        _firstValidFrame = null;
      }
    }
  }

  static ScaleSnapshot? parseFrame(List<int> data) {
    if (data.length != _frameLength) return null;
    if (data[0] != 0x57) return null;

    var xorResult = 0;
    for (var i = 1; i < data.length - 1; i++) {
      xorResult ^= data[i];
    }
    if ((xorResult & 0xFF) != (data.last & 0xFF)) return null;

    final byteData = ByteData(4);
    byteData.setUint8(0, data[1]);
    byteData.setUint8(1, data[2]);
    byteData.setUint8(2, data[3]);
    byteData.setUint8(3, data[4]);
    final weightMg = byteData.getInt32(0, Endian.little);

    final timerData = ByteData(4);
    timerData.setUint8(0, data[5]);
    timerData.setUint8(1, data[6]);
    timerData.setUint8(2, data[7]);
    timerData.setUint8(3, data[8]);
    final timerMs = timerData.getUint32(0, Endian.little);

    return ScaleSnapshot(
      timestamp: DateTime.now(),
      weight: weightMg / 1000.0,
      batteryLevel: 0,
      timerValue: timerMs > 0 ? Duration(milliseconds: timerMs) : null,
    );
  }

  void _parseNotification(List<int> data) {
    final snapshot = parseFrame(data);
    if (snapshot != null) {
      _streamController.add(snapshot);
      final firstValidFrame = _firstValidFrame;
      if (firstValidFrame != null && !firstValidFrame.isCompleted) {
        firstValidFrame.complete();
      }
    }
  }
}
