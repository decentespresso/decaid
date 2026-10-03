import 'dart:async';
import 'dart:typed_data';
import 'package:logging/logging.dart';
import 'package:reaprime/src/models/device/ble_service_identifier.dart';
import 'package:reaprime/src/models/device/device_implementation.dart';
import 'package:reaprime/src/models/device/transport/ble_transport.dart';
import 'package:reaprime/src/models/device/transport/data_transport.dart';
import 'package:reaprime/src/models/errors.dart';
import 'package:rxdart/subjects.dart';

import 'package:reaprime/src/models/device/device.dart';
import '../../scale.dart';

// Timemore scale BLE protocol (open-scale-protocol v1.0.3).
//
// Service UUID  : 0000fff0-0000-1000-8000-00805f9b34fb
// Notify char   : 0000fff1-0000-1000-8000-00805f9b34fb  (weight/flow/timer stream)
// Write char    : 0000fff2-0000-1000-8000-00805f9b34fb  (commands)
//
// Frame layout:
//   A5 5A | opcode | cmd | length(2, big-endian) | data | crc(2, big-endian)
//   crc is CRC-16/MODBUS (poly 0x8005 reflected = 0xA001, init 0xFFFF).
//
// Notify weight frame (opcode 0x01, cmd 0x01, length 0x0009):
//   [6..9]   weight    Int32  BE  (divide by 10 -> grams)
//   [10,11]  flow      Int16  BE  (divide by 10 -> grams/second)
//   [12,13]  timer     UInt16 BE  (seconds)
//   [14]     overload  UInt8      (1 = over limit)
//
// Advertising name prefix: "Basic3 Link" (Link) or "TIMEMORE" (Dot family).
class TimemoreScale implements Scale {
  final Logger _log = Logger('TimemoreScale');

  static final BleServiceIdentifier serviceIdentifier =
      BleServiceIdentifier.short('fff0');
  static final BleServiceIdentifier _notifyCharacteristic =
      BleServiceIdentifier.short('fff1');
  static final BleServiceIdentifier _writeCharacteristic =
      BleServiceIdentifier.short('fff2');

  static const _header0 = 0xA5;
  static const _header1 = 0x5A;

  static const _opNotify = 0x01;
  static const _opRead = 0x02;
  static const _opWrite = 0x03;

  static const _cmdWeightStream = 0x01;
  static const _cmdTimer = 0x02;
  static const _cmdBattery = 0x05;
  static const _cmdTare = 0x0D;

  static const _minFrameLength = 8;
  static const _weightFrameLength = 17;

  final BLETransport _transport;
  final StreamController<ScaleSnapshot> _streamController =
      StreamController.broadcast();
  final BehaviorSubject<ConnectionState> _connectionStateController =
      BehaviorSubject.seeded(ConnectionState.discovered);

  int _batteryLevel = 0;

  TimemoreScale({required BLETransport transport}) : _transport = transport;

  @override
  String get deviceId => _transport.id;

  @override
  DeviceImplementation get implementation => DeviceImplementation.timemoreScale;

  @override
  TransportType get transportType => _transport.transportType;

  @override
  String get name => 'Timemore Link';

  @override
  DeviceType get type => DeviceType.scale;

  @override
  Stream<ScaleSnapshot> get currentSnapshot => _streamController.stream;

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
          .where((s) => s == ConnectionState.disconnected)
          .listen((_) {
            _connectionStateController.add(ConnectionState.disconnected);
            disconnectSub?.cancel();
          });

      final services = await _transport.discoverServices();
      if (!serviceIdentifier.matchesAny(services)) {
        throw Exception(
          'Expected service ${serviceIdentifier.long} not found. '
          'Discovered: $services',
        );
      }

      await _transport.subscribe(
        serviceIdentifier.long,
        _notifyCharacteristic.long,
        _onNotification,
      );

      await _sendInitSequence();

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
    await _safeWrite(_frame(_opWrite, _cmdTare));
  }

  @override
  Future<void> startTimer() async {
    await _safeWrite(_frame(_opWrite, _cmdTimer, const [0x01]));
  }

  @override
  Future<void> stopTimer() async {
    await _safeWrite(_frame(_opWrite, _cmdTimer, const [0x02]));
  }

  @override
  Future<void> resetTimer() async {
    await _safeWrite(_frame(_opWrite, _cmdTimer, const [0x03]));
  }

  @override
  Future<void> sleepDisplay() async {
    await disconnect();
  }

  @override
  Future<void> wakeDisplay() async {}

  // Query battery once on connect so snapshots carry a level.
  Future<void> _sendInitSequence() async {
    await _safeWrite(_frame(_opRead, _cmdBattery));
  }

  void _onNotification(List<int> data) {
    if (data.length < _minFrameLength) return;
    if (data[0] != _header0 || data[1] != _header1) return;

    final opcode = data[2];
    final cmd = data[3];

    // Battery response: data = [bars, percent].
    if (cmd == _cmdBattery && data.length >= 8) {
      _batteryLevel = data[7];
      return;
    }

    // Weight/flow/timer stream.
    if (opcode == _opNotify &&
        cmd == _cmdWeightStream &&
        data.length >= _weightFrameLength) {
      final bytes = Uint8List.fromList(data);
      final view = ByteData.sublistView(bytes);

      final weightGrams = view.getInt32(6, Endian.big) / 10.0;
      final flowGramsPerSecond = view.getInt16(10, Endian.big) / 10.0;
      final timerSeconds = view.getUint16(12, Endian.big);

      _streamController.add(
        ScaleSnapshot(
          timestamp: DateTime.now(),
          weight: weightGrams,
          batteryLevel: _batteryLevel,
          flow: flowGramsPerSecond,
          timerValue: Duration(seconds: timerSeconds),
        ),
      );
    }
  }

  Future<void> _safeWrite(List<int> bytes) async {
    try {
      await _transport.write(
        serviceIdentifier.long,
        _writeCharacteristic.long,
        Uint8List.fromList(bytes),
        withResponse: false,
      );
    } on DeviceNotConnectedException {
      // Transport already emitted disconnected; nothing to do.
    }
  }

  // Builds a protocol frame with auto-computed length and CRC-16/MODBUS.
  List<int> _frame(int opcode, int cmd, [List<int> data = const []]) {
    final payload = <int>[
      _header0,
      _header1,
      opcode,
      cmd,
      (data.length >> 8) & 0xFF,
      data.length & 0xFF,
      ...data,
    ];
    final crc = _crc16Modbus(payload);
    return [...payload, (crc >> 8) & 0xFF, crc & 0xFF];
  }

  // CRC-16/MODBUS: poly 0xA001 (reflected 0x8005), init 0xFFFF.
  int _crc16Modbus(List<int> bytes) {
    var crc = 0xFFFF;
    for (final b in bytes) {
      crc ^= b & 0xFF;
      for (var i = 0; i < 8; i++) {
        crc = (crc & 1) != 0 ? ((crc >> 1) ^ 0xA001) : (crc >> 1);
      }
    }
    return crc & 0xFFFF;
  }
}
