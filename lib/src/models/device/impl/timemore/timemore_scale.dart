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

// Timemore Link scale BLE protocol.
//
// Service UUID  : 0000fff0-0000-1000-8000-00805f9b34fb
// Notify char   : 0000fff1-0000-1000-8000-00805f9b34fb  (weight notifications)
// Write char    : 0000fff2-0000-1000-8000-00805f9b34fb  (commands)
//
// Notify packet layout (type=0x01):
//   [0] 0xA5  [1] 0x5A  [2] type  [3] stat
//   [4..7] varies  [8] wHigh  [9] wLow  ...
//   weight = signed_int16(bytes[8], bytes[9]) / 10.0  (grams)
//
// Commands use CRC-16/MODBUS appended as two big-endian bytes.
// Advertising name prefix: "Basic3 Link"
//
// Protocol reverse-engineered from HCI snoop logs (12/12 verified).
class TimemoreScale implements Scale {
  final Logger _log = Logger('TimemoreScale');

  static final BleServiceIdentifier serviceIdentifier =
      BleServiceIdentifier.short('fff0');
  static final BleServiceIdentifier _notifyCharacteristic =
      BleServiceIdentifier.short('fff1');
  static final BleServiceIdentifier _writeCharacteristic =
      BleServiceIdentifier.short('fff2');

  static const _packetHeader0 = 0xA5;
  static const _packetHeader1 = 0x5A;
  static const _typeWeight = 0x01;
  static const _minPacketLength = 10;

  final BLETransport _transport;
  final StreamController<ScaleSnapshot> _streamController =
      StreamController.broadcast();
  final BehaviorSubject<ConnectionState> _connectionStateController =
      BehaviorSubject.seeded(ConnectionState.discovered);

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
    // Link tare: A5 5A 03 0D 00 02 00 00 + CRC16/MODBUS (2 bytes, big-endian)
    // Precede with a 02-05 state query as observed in HCI snoop logs.
    await _safeWrite(_linkQuery(0x05));
    await Future<void>.delayed(const Duration(milliseconds: 150));
    await _safeWrite(_withCrc([0xA5, 0x5A, 0x03, 0x0D, 0x00, 0x02, 0x00, 0x00]));
  }

  @override
  Future<void> startTimer() async {
    await _safeWrite(_withCrc([0xA5, 0x5A, 0x03, 0x02, 0x00, 0x01, 0x01]));
  }

  @override
  Future<void> stopTimer() async {
    await _safeWrite(_withCrc([0xA5, 0x5A, 0x03, 0x02, 0x00, 0x01, 0x02]));
  }

  @override
  Future<void> resetTimer() async {
    await _safeWrite(_withCrc([0xA5, 0x5A, 0x03, 0x02, 0x00, 0x01, 0x03]));
  }

  @override
  Future<void> sleepDisplay() async {
    await disconnect();
  }

  @override
  Future<void> wakeDisplay() async {}

  // Init sequence: query args 0x13, 0x08, 0x05, 0x02, 0x06, 0x0C
  // Sent twice as observed in the reference implementation.
  Future<void> _sendInitSequence() async {
    const initArgs = [0x13, 0x08, 0x05, 0x02, 0x06, 0x0C];
    for (final arg in initArgs) {
      await _safeWrite(_linkQuery(arg));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    await Future<void>.delayed(const Duration(milliseconds: 200));
    for (final arg in initArgs) {
      await _safeWrite(_linkQuery(arg));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    // Follow-up 02-05 query observed after init in HCI logs.
    await Future<void>.delayed(const Duration(milliseconds: 200));
    await _safeWrite(_linkQuery(0x05));
  }

  void _onNotification(List<int> data) {
    if (data.length < _minPacketLength) return;
    if (data[0] != _packetHeader0 || data[1] != _packetHeader1) return;
    if (data[2] != _typeWeight) return;

    final rawWord = (data[8] << 8) | data[9];
    // Treat as signed 16-bit.
    final signed = rawWord > 32767 ? rawWord - 65536 : rawWord;
    final weightGrams = signed / 10.0;

    _streamController.add(
      ScaleSnapshot(
        timestamp: DateTime.now(),
        weight: weightGrams,
        batteryLevel: 0,
      ),
    );
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

  // Builds a Link query command: A5 5A 02 <arg> 00 00 + CRC16/MODBUS
  List<int> _linkQuery(int arg) =>
      _withCrc([0xA5, 0x5A, 0x02, arg, 0x00, 0x00]);

  // Appends CRC-16/MODBUS checksum (big-endian) to payload.
  List<int> _withCrc(List<int> payload) {
    final crc = _crc16Modbus(payload);
    return [...payload, (crc >> 8) & 0xFF, crc & 0xFF];
  }

  // CRC-16/MODBUS: poly 0xA001, init 0xFFFF, reflect in/out.
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
