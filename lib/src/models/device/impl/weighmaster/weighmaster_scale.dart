import 'dart:async';
import 'dart:typed_data';

import 'package:logging/logging.dart';
import 'package:reaprime/src/models/device/ble_service_identifier.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/device_implementation.dart';
import 'package:reaprime/src/models/device/transport/ble_transport.dart';
import 'package:reaprime/src/models/device/transport/data_transport.dart';
import 'package:reaprime/src/models/errors.dart';
import 'package:rxdart/subjects.dart';

import '../../scale.dart';

class WeighMasterScale implements Scale {
  final Logger _log = Logger('WeighMasterScale');

  static final BleServiceIdentifier serviceIdentifier =
      BleServiceIdentifier.short('fff0');
  static final BleServiceIdentifier dataCharacteristic =
      BleServiceIdentifier.short('fff4');
  static final BleServiceIdentifier commandCharacteristic =
      BleServiceIdentifier.short('fff1');

  static const int _cmdTare = 0x02;
  static const int _cmdSleepDisplay = 0x03;
  static const int _cmdBuzzer = 0x05;

  static const int _frameLength = 7;
  static const int _headerByte1 = 0x01;
  static const int _headerByte2 = 0x02;
  static const int _statusOffset = 3;
  static const int _weightOffset = 4;
  static const int _statusNegative = 0x01;

  final String _deviceId;
  final BLETransport _transport;

  final StreamController<ScaleSnapshot> _streamController =
      StreamController.broadcast();
  final StreamController<ConnectionState> _connectionStateController =
      BehaviorSubject.seeded(ConnectionState.discovered);

  WeighMasterScale({required BLETransport transport})
    : _transport = transport,
      _deviceId = transport.id;

  @override
  Stream<ScaleSnapshot> get currentSnapshot => _streamController.stream;

  @override
  String get deviceId => _deviceId;

  @override
  DeviceImplementation get implementation =>
      DeviceImplementation.weighMasterScale;

  @override
  TransportType get transportType => _transport.transportType;

  @override
  String get name => 'WeighMaster Scale';

  @override
  Stream<ConnectionState> get connectionState =>
      _connectionStateController.stream;

  @override
  DeviceType get type => DeviceType.scale;

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
  Future<void> disconnect() async {
    await _transport.disconnect();
  }

  @override
  Future<void> tare() async {
    await _write(const [_cmdTare]);
    unawaited(
      Future<void>.delayed(
        const Duration(milliseconds: 300),
      ).then((_) => _write(const [_cmdBuzzer, 0x00])).catchError((_) {}),
    );
  }

  @override
  Future<void> sleepDisplay() async {
    await _write(const [_cmdSleepDisplay, 0x00, 0x01]);
  }

  @override
  Future<void> wakeDisplay() async {}

  @override
  Future<void> startTimer() async {}

  @override
  Future<void> stopTimer() async {}

  @override
  Future<void> resetTimer() async {}

  Future<void> _write(List<int> bytes) async {
    try {
      await _transport.write(
        serviceIdentifier.long,
        commandCharacteristic.long,
        Uint8List.fromList(bytes),
      );
    } on DeviceNotConnectedException {
      // Transport already emitted disconnected.
    }
  }

  Future<void> _registerNotifications() async {
    await _transport.subscribe(
      serviceIdentifier.long,
      dataCharacteristic.long,
      _parseNotification,
    );
  }

  static ScaleSnapshot? parseFrame(List<int> data) {
    if (data.length < _frameLength) {
      return null;
    }

    if (data[0] != _headerByte1 || data[1] != _headerByte2) {
      return null;
    }

    final status = data[_statusOffset];
    final isNegative = (status & _statusNegative) == _statusNegative;
    final weightRaw =
        (data[_weightOffset] << 16) |
        (data[_weightOffset + 1] << 8) |
        data[_weightOffset + 2];

    var weight = weightRaw / 10.0;
    if (isNegative) {
      weight = -weight;
    }

    return ScaleSnapshot(
      timestamp: DateTime.now(),
      weight: weight,
      batteryLevel: 0,
    );
  }

  void _parseNotification(List<int> data) {
    final snapshot = parseFrame(data);
    if (snapshot != null) {
      _streamController.add(snapshot);
    }
  }
}
