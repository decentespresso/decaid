import 'dart:async';
import 'dart:typed_data';

import 'package:logging/logging.dart';
import 'package:reaprime/src/models/device/ble_service_identifier.dart';
import 'package:reaprime/src/models/device/device_implementation.dart';
import 'package:reaprime/src/models/device/transport/ble_transport.dart';
import 'package:reaprime/src/models/device/transport/data_transport.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/errors.dart';
import 'package:rxdart/subjects.dart';

import '../../scale.dart';
import 'timemore_dot_protocol.dart';

class TimemoreDotScale implements Scale {
  final Logger _log = Logger('TimemoreDotScale');

  static final BleServiceIdentifier serviceIdentifier =
      BleServiceIdentifier.short('fff0');
  static final BleServiceIdentifier weightCharacteristic =
      BleServiceIdentifier.short('fff1');
  static final BleServiceIdentifier commandCharacteristic =
      BleServiceIdentifier.short('fff2');

  static const _initDelayAfterSubscribe = Duration(milliseconds: 500);
  static const _initDelayBeforeMode = Duration(milliseconds: 200);
  static const _initDelayBeforeBattery = Duration(milliseconds: 100);
  static const _maxBufferBytes = 256;

  final BLETransport _transport;
  final Duration _delayAfterSubscribe;
  final Duration _delayBeforeMode;
  final Duration _delayBeforeBattery;

  final StreamController<ScaleSnapshot> _streamController =
      StreamController.broadcast();
  final BehaviorSubject<ConnectionState> _connectionStateController =
      BehaviorSubject.seeded(ConnectionState.discovered);

  final List<int> _buffer = [];
  int _batteryLevel = 0;

  TimemoreDotScale({
    required BLETransport transport,
    Duration initDelayAfterSubscribe = _initDelayAfterSubscribe,
    Duration initDelayBeforeMode = _initDelayBeforeMode,
    Duration initDelayBeforeBattery = _initDelayBeforeBattery,
  }) : _transport = transport,
       _delayAfterSubscribe = initDelayAfterSubscribe,
       _delayBeforeMode = initDelayBeforeMode,
       _delayBeforeBattery = initDelayBeforeBattery;

  @override
  Stream<ScaleSnapshot> get currentSnapshot => _streamController.stream;

  @override
  String get deviceId => _transport.id;

  @override
  DeviceImplementation get implementation => DeviceImplementation.timemoreDot;

  @override
  TransportType get transportType => _transport.transportType;

  @override
  String get name => 'Timemore Dot';

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
            _buffer.clear();
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
      await _initScale();
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
  Future<void> disconnect() async {
    _buffer.clear();
    await _transport.disconnect();
  }

  @override
  DeviceType get type => DeviceType.scale;

  @override
  Future<void> tare() async {
    await _write(TimemoreDotProtocol.tareCommand());
  }

  @override
  Future<void> sleepDisplay() async {
    await disconnect();
  }

  @override
  Future<void> wakeDisplay() async {}

  @override
  Future<void> startTimer() async {
    await _write(TimemoreDotProtocol.timerStartCommand());
  }

  @override
  Future<void> stopTimer() async {
    await _write(TimemoreDotProtocol.timerStopCommand());
  }

  @override
  Future<void> resetTimer() async {
    await _write(TimemoreDotProtocol.timerResetCommand());
  }

  Future<void> _registerNotifications() async {
    await _transport.subscribe(
      serviceIdentifier.long,
      weightCharacteristic.long,
      _parseNotification,
    );
  }

  Future<void> _initScale() async {
    await Future.delayed(_delayAfterSubscribe);
    await _initWrite(TimemoreDotProtocol.initUnitCommand());
    await Future.delayed(_delayBeforeMode);
    await _initWrite(TimemoreDotProtocol.initModeCommand());
    await Future.delayed(_delayBeforeBattery);
    await _initWrite(TimemoreDotProtocol.initBatteryCommand());
  }

  Future<void> _initWrite(Uint8List command) async {
    try {
      await _write(command);
    } catch (e) {
      _log.warning('Init command failed: $e');
    }
  }

  Future<void> _write(Uint8List command) async {
    try {
      await _transport.write(
        serviceIdentifier.long,
        commandCharacteristic.long,
        command,
        withResponse: false,
      );
      // ignore: empty_catches
    } on DeviceNotConnectedException {}
  }

  void _parseNotification(Uint8List data) {
    _log.fine(
      'Dot rx ${data.length} bytes: ${data.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ')}',
    );
    _buffer.addAll(data);
    if (_buffer.length > _maxBufferBytes) {
      _buffer.removeRange(0, _buffer.length - _maxBufferBytes);
    }
    while (true) {
      final frame = _tryNextFrame();
      if (frame == null) break;
      _handleFrame(frame);
    }
  }

  TimemoreDotFrame? _tryNextFrame() {
    while (_buffer.length >= TimemoreDotProtocol.headerSize) {
      if (_buffer[0] != TimemoreDotProtocol.magicFirst ||
          _buffer[1] != TimemoreDotProtocol.magicSecond) {
        _buffer.removeAt(0);
        continue;
      }
      final payloadLength = (_buffer[4] << 8) | _buffer[5];
      if (payloadLength > TimemoreDotProtocol.maxPayloadLength) {
        _buffer.removeAt(0);
        continue;
      }
      final total = payloadLength + TimemoreDotProtocol.frameOverhead;
      if (_buffer.length < total) return null;
      final candidate = _buffer.sublist(0, total);
      _buffer.removeRange(0, total);
      if (!TimemoreDotProtocol.isWellFormedFrame(candidate)) continue;
      return TimemoreDotProtocol.parseFrame(candidate);
    }
    return null;
  }

  void _handleFrame(TimemoreDotFrame frame) {
    if (frame.opcode == 0x03) {
      _log.fine('Dot command ack: cmdId=${frame.cmdId}');
      return;
    }
    switch (frame.cmdId) {
      case 0x01:
        _handleWeight(frame.payload);
        break;
      case 0x05:
        _handleBattery(frame.payload);
        break;
      default:
        _log.fine('Ignoring unknown Dot frame cmdId=${frame.cmdId}');
    }
  }

  void _handleWeight(Uint8List payload) {
    if (payload.length < 8) return;
    var rawWeight =
        (payload[0] << 24) |
        (payload[1] << 16) |
        (payload[2] << 8) |
        payload[3];
    if (rawWeight > 0x7FFFFFFF) rawWeight -= 0x100000000;
    final timerSeconds = (payload[6] << 8) | payload[7];
    _streamController.add(
      ScaleSnapshot(
        timestamp: DateTime.now(),
        weight: rawWeight / 10.0,
        batteryLevel: _batteryLevel,
        timerValue: timerSeconds > 0 ? Duration(seconds: timerSeconds) : null,
      ),
    );
  }

  void _handleBattery(Uint8List payload) {
    if (payload.isEmpty) return;
    final raw = payload.length >= 2 ? payload[1] : payload[0];
    if (raw <= 100) _batteryLevel = raw;
  }
}
