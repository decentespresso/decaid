import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:logging/logging.dart' as logging;
import 'package:reaprime/src/models/device/ble_service_identifier.dart';
import 'package:reaprime/src/models/device/device_implementation.dart';
import 'package:reaprime/src/models/device/transport/ble_transport.dart';
import 'package:reaprime/src/models/device/transport/data_transport.dart';
import 'package:reaprime/src/models/errors.dart';
import 'package:rxdart/subjects.dart';

import 'package:reaprime/src/models/device/device.dart';

import '../../scale.dart';

class Skale2Scale implements Scale, DeviceInformationCapable {
  static final BleServiceIdentifier serviceIdentifier =
      BleServiceIdentifier.short('ff08');
  static final BleServiceIdentifier weightCharacteristic =
      BleServiceIdentifier.short('ef81');
  static final BleServiceIdentifier commandCharacteristic =
      BleServiceIdentifier.short('ef80');
  static final BleServiceIdentifier buttonCharacteristic =
      BleServiceIdentifier.short('ef82');
  static final BleServiceIdentifier batteryService = BleServiceIdentifier.short(
    '180f',
  );
  static final BleServiceIdentifier batteryCharacteristic =
      BleServiceIdentifier.short('2a19');
  static final BleServiceIdentifier deviceInformationService =
      BleServiceIdentifier.short('180a');
  static final BleServiceIdentifier firmwareRevisionCharacteristic =
      BleServiceIdentifier.short('2a26');

  final String _deviceId;

  final StreamController<ScaleSnapshot> _streamController =
      StreamController.broadcast();

  final BLETransport _transport;

  int _batteryLevel = 0;

  final _log = logging.Logger('Skale2Scale');

  bool _weightSubscribed = false;

  bool _buttonSubscribed = false;

  int _connectionGeneration = 0;
  StreamSubscription<ConnectionState>? _transportDisconnectSubscription;

  final BehaviorSubject<DeviceInformation?> _deviceInformationController =
      BehaviorSubject<DeviceInformation?>.seeded(null);

  static const _initStepDelay = Duration(milliseconds: 1000);

  Skale2Scale({
    required BLETransport transport,
    Duration initStepDelay = _initStepDelay,
  }) : _transport = transport,
       _deviceId = transport.id,
       _initStepDelayOverride = initStepDelay;

  final Duration _initStepDelayOverride;

  @override
  Stream<ScaleSnapshot> get currentSnapshot => _streamController.stream;

  @override
  String get deviceId => _deviceId;

  @override
  DeviceImplementation get implementation => DeviceImplementation.skale2;

  @override
  TransportType get transportType => _transport.transportType;

  @override
  String get name => "Skale2";

  final BehaviorSubject<ConnectionState> _connectionStateController =
      BehaviorSubject.seeded(ConnectionState.discovered);

  @override
  Stream<ConnectionState> get connectionState =>
      _connectionStateController.stream;

  @override
  DeviceInformation? get currentDeviceInformation =>
      _deviceInformationController.value;

  @override
  Stream<DeviceInformation?> get deviceInformation =>
      _deviceInformationController.stream;

  @override
  Future<void> onConnect() async {
    final transportState = await _transport.connectionState.first;
    if (transportState == ConnectionState.connected &&
        _connectionStateController.value == ConnectionState.connected) {
      return;
    }

    final generation = ++_connectionGeneration;
    _clearDeviceInformation();
    _connectionStateController.add(ConnectionState.connecting);

    try {
      if (transportState != ConnectionState.connected) {
        await _transport.connect();
      }

      await _transportDisconnectSubscription?.cancel();
      _transportDisconnectSubscription = _transport.connectionState
          .where((state) => state == ConnectionState.disconnected)
          .listen((_) {
            if (generation != _connectionGeneration) return;
            _connectionGeneration++;
            _connectionStateController.add(ConnectionState.disconnected);
            _weightSubscribed = false;
            _buttonSubscribed = false;
            _clearDeviceInformation();
          });

      final services = await _transport.discoverServices();
      if (!serviceIdentifier.matchesAny(services)) {
        throw Exception(
          'Expected service ${serviceIdentifier.long} not found. '
          'Discovered services: $services',
        );
      }

      await _initScale(services, generation);
      if (!await _isConnectionActive(generation)) return;
      _connectionStateController.add(ConnectionState.connected);
    } catch (e, st) {
      if (generation != _connectionGeneration) return;
      _log.warning('Connect failed: $e');
      _log.fine('Skale connection failure details', e, st);
      _connectionGeneration++;
      await _transportDisconnectSubscription?.cancel();
      _transportDisconnectSubscription = null;
      _clearDeviceInformation();
      _connectionStateController.add(ConnectionState.disconnected);
      try {
        await _transport.disconnect();
      } catch (_) {}
    }
  }

  @override
  Future<void> disconnect() async {
    _connectionGeneration++;
    _clearDeviceInformation();
    try {
      await _transport.disconnect();
    } finally {
      await _transportDisconnectSubscription?.cancel();
      _transportDisconnectSubscription = null;
      _weightSubscribed = false;
      _buttonSubscribed = false;
      _connectionStateController.add(ConnectionState.disconnected);
    }
  }

  @override
  DeviceType get type => DeviceType.scale;

  Future<void> _initScale(List<String> services, int generation) async {
    await _sendDisplayOn();
    await _sendDisplayWeight();

    await Future.delayed(_initStepDelayOverride);
    if (!await _isConnectionActive(generation)) return;
    await _subscribeWeight();

    await Future.delayed(_initStepDelayOverride);
    if (!await _isConnectionActive(generation)) return;
    await _subscribeButton();

    if (deviceInformationService.matchesAny(services)) {
      await _readFirmwareVersion(generation);
    }
    if (!await _isConnectionActive(generation)) return;

    try {
      final batteryData = await _transport.read(
        batteryService.long,
        batteryCharacteristic.long,
      );
      if (!await _isConnectionActive(generation)) return;
      if (batteryData.isNotEmpty) {
        _batteryLevel = batteryData[0];
      }
    } catch (_) {}

    await Future.delayed(_initStepDelayOverride);
    await _sendDisplayOn();
    await _sendDisplayWeight();
    await _safeWrite(Uint8List.fromList([0x03]));
  }

  Future<void> _readFirmwareVersion(int generation) async {
    try {
      final data = await _transport.read(
        deviceInformationService.long,
        firmwareRevisionCharacteristic.long,
      );
      if (!await _isConnectionActive(generation) || data.isEmpty) return;

      final value = utf8
          .decode(data)
          .replaceFirst(RegExp(r'\x00+$'), '')
          .trim();
      if (value.isEmpty ||
          value.runes.any((rune) => rune < 0x20 || rune == 0x7F)) {
        return;
      }

      _deviceInformationController.add(
        DeviceInformation(firmwareVersion: value),
      );
    } on FormatException catch (e) {
      _log.fine('Ignoring malformed Skale firmware revision: $e');
    } catch (e) {
      _log.fine('Skale firmware revision unavailable: $e');
    }
  }

  Future<bool> _isConnectionActive(int generation) async {
    if (generation != _connectionGeneration) return false;
    return await _transport.connectionState.first == ConnectionState.connected;
  }

  void _clearDeviceInformation() {
    _deviceInformationController.add(null);
  }

  Future<void> _subscribeWeight() async {
    await _transport.subscribe(
      serviceIdentifier.long,
      weightCharacteristic.long,
      _parseWeightNotification,
    );
    _weightSubscribed = true;
  }

  Future<void> _subscribeButton() async {
    try {
      await _transport.subscribe(
        serviceIdentifier.long,
        buttonCharacteristic.long,
        _parseButtonNotification,
      );
      _buttonSubscribed = true;
    } catch (e) {
      _log.warning('Failed to subscribe to button notifications: $e');
    }
  }

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

  Future<void> _sendDisplayOn() async {
    await _safeWrite(Uint8List.fromList([0xED]));
  }

  Future<void> _sendDisplayWeight() async {
    await _safeWrite(Uint8List.fromList([0xEC]));
  }

  Future<void> _sendDisplayOff() async {
    await _safeWrite(Uint8List.fromList([0xEE]));
  }

  @override
  Future<void> tare() async {
    await _safeWrite(Uint8List.fromList([0x10]));
  }

  @override
  Future<void> sleepDisplay() async {
    await _sendDisplayOff();
  }

  @override
  Future<void> wakeDisplay() async {
    await _sendDisplayOn();
    await _sendDisplayWeight();

    if (!_weightSubscribed) {
      _log.info('Re-subscribing to weight notifications during wake');
      await _subscribeWeight();
    }
    if (!_buttonSubscribed) {
      _log.info('Re-subscribing to button notifications during wake');
      await _subscribeButton();
    }
  }

  void _parseWeightNotification(List<int> data) {
    double? weight;
    if (data.length == 5) {
      var mantissa =
          (data[1] & 0xFF) | ((data[2] & 0xFF) << 8) | ((data[3] & 0xFF) << 16);
      if (mantissa & 0x800000 != 0) {
        mantissa -= 0x1000000;
      }
      final rawExponent = data[4];
      final exponent = rawExponent >= 0x80 ? rawExponent - 256 : rawExponent;
      weight = mantissa * math.pow(10, exponent).toDouble();
    } else if (data.length == 4) {
      final byteData = ByteData(4);
      byteData.setUint8(0, data[0] & 0xFF);
      byteData.setUint8(1, data[1] & 0xFF);
      byteData.setUint8(2, data[2] & 0xFF);
      byteData.setUint8(3, data[3] & 0xFF);
      final rawValue = byteData.getInt32(0, Endian.little);
      weight = rawValue / 2560.0;
    } else {
      return;
    }
    _streamController.add(
      ScaleSnapshot(
        timestamp: DateTime.now(),
        weight: weight,
        batteryLevel: _batteryLevel,
      ),
    );
  }

  void _parseButtonNotification(List<int> data) {}

  @override
  Future<void> startTimer() async {
    await _safeWrite(Uint8List.fromList([0xDD]));
  }

  @override
  Future<void> stopTimer() async {
    await _safeWrite(Uint8List.fromList([0xD1]));
  }

  @override
  Future<void> resetTimer() async {
    await _safeWrite(Uint8List.fromList([0xD0]));
  }
}
