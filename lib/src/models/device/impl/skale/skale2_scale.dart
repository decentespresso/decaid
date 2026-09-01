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

class Skale2Scale
    implements Scale, DeviceInformationCapable, UsbPowerConfigurable {
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

  int? _batteryLevel;
  final Map<int, Future<void>> _batteryReads = {};
  bool _usbPowered = false;
  int _powerSourceGeneration = 0;
  Timer? _batteryRefreshTimer;

  final _log = logging.Logger('Skale2Scale');

  bool _weightSubscribed = false;

  bool _buttonSubscribed = false;

  int _connectionGeneration = 0;
  StreamSubscription<ConnectionState>? _transportDisconnectSubscription;
  String? _firmwareVersion;
  bool _batterySupported = false;
  bool _deviceInformationActive = false;

  final BehaviorSubject<DeviceInformation?> _deviceInformationController =
      BehaviorSubject<DeviceInformation?>.seeded(null);

  static const _initStepDelay = Duration(milliseconds: 1000);
  static const _batteryRefreshInterval = Duration(minutes: 30);

  Skale2Scale({
    required BLETransport transport,
    Duration initStepDelay = _initStepDelay,
    Duration batteryRefreshInterval = _batteryRefreshInterval,
  }) : _transport = transport,
       _deviceId = transport.id,
       _initStepDelayOverride = initStepDelay,
       _batteryRefreshIntervalOverride = batteryRefreshInterval;

  final Duration _initStepDelayOverride;
  final Duration _batteryRefreshIntervalOverride;

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
  bool get usbPowered => _usbPowered;

  @override
  Future<void> setUsbPowered(bool value) async {
    if (value == _usbPowered) return;
    _usbPowered = value;
    final powerSourceGeneration = ++_powerSourceGeneration;
    if (value) {
      _stopBatteryRefresh();
      _batteryLevel = null;
      _publishDeviceInformation();
      return;
    }

    final connectionGeneration = _connectionGeneration;
    final pendingRead = _batteryReads[connectionGeneration];
    if (pendingRead != null) await pendingRead;
    if (powerSourceGeneration != _powerSourceGeneration ||
        _usbPowered ||
        !_batterySupported ||
        !await _isConnectionActive(connectionGeneration)) {
      return;
    }
    await _readBatteryLevel(connectionGeneration);
    if (powerSourceGeneration == _powerSourceGeneration &&
        !_usbPowered &&
        await _isConnectionActive(connectionGeneration)) {
      _startBatteryRefresh(connectionGeneration);
    }
  }

  @override
  Future<void> onConnect() async {
    final transportState = await _transport.connectionState.first;
    if (transportState == ConnectionState.connected &&
        _connectionStateController.value == ConnectionState.connected) {
      return;
    }

    final generation = ++_connectionGeneration;
    _stopBatteryRefresh();
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
            _stopBatteryRefresh();
            _batteryLevel = null;
            _batterySupported = false;
            _clearDeviceInformation();
          });

      final services = await _transport.discoverServices();
      if (!serviceIdentifier.matchesAny(services)) {
        throw Exception(
          'Expected service ${serviceIdentifier.long} not found. '
          'Discovered services: $services',
        );
      }

      _deviceInformationActive = true;
      _batterySupported = batteryService.matchesAny(services);
      if (_usbPowered) _publishDeviceInformation();
      await _initScale(services, generation);
      if (!await _isConnectionActive(generation)) return;
      _connectionStateController.add(ConnectionState.connected);
      if (!_usbPowered) _startBatteryRefresh(generation);
    } catch (e, st) {
      if (generation != _connectionGeneration) return;
      _log.warning('Connect failed: $e');
      _log.fine('Skale connection failure details', e, st);
      _connectionGeneration++;
      _stopBatteryRefresh();
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
    _stopBatteryRefresh();
    _batteryLevel = null;
    _batterySupported = false;
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

    if (_batterySupported && !_usbPowered) {
      await _readBatteryLevel(generation);
    }
    if (!await _isConnectionActive(generation)) return;

    await Future.delayed(_initStepDelayOverride);
    await _sendDisplayOn();
    await _sendDisplayWeight();
    await _safeWrite(Uint8List.fromList([0x03]));
  }

  Future<void> _readBatteryLevel(int generation) {
    if (_usbPowered ||
        generation != _connectionGeneration ||
        !_batterySupported) {
      return Future.value();
    }
    final existing = _batteryReads[generation];
    if (existing != null) return existing;

    late final Future<void> read;
    read = _performBatteryRead(generation).whenComplete(() {
      if (identical(_batteryReads[generation], read)) {
        _batteryReads.remove(generation);
      }
    });
    _batteryReads[generation] = read;
    return read;
  }

  Future<void> _performBatteryRead(int generation) async {
    final powerSourceGeneration = _powerSourceGeneration;
    int? level;
    try {
      final data = await _transport.read(
        batteryService.long,
        batteryCharacteristic.long,
      );
      if (data.length == 1 && data[0] <= 100) {
        level = data[0];
      }
    } catch (e) {
      _log.fine('Skale battery level unavailable: $e');
    }
    if (generation != _connectionGeneration ||
        powerSourceGeneration != _powerSourceGeneration ||
        _usbPowered ||
        await _transport.connectionState.first != ConnectionState.connected) {
      return;
    }
    _batteryLevel = level;
    _publishDeviceInformation();
  }

  void _startBatteryRefresh(int generation) {
    if (!_batterySupported || _usbPowered) return;
    _batteryRefreshTimer?.cancel();
    _batteryRefreshTimer = Timer.periodic(_batteryRefreshIntervalOverride, (_) {
      _readBatteryLevel(generation);
    });
  }

  void _stopBatteryRefresh() {
    _batteryRefreshTimer?.cancel();
    _batteryRefreshTimer = null;
  }

  Future<void> _readFirmwareVersion(int generation) async {
    try {
      final data = await _transport.read(
        deviceInformationService.long,
        firmwareRevisionCharacteristic.long,
      );
      if (!await _isConnectionActive(generation) || data.isEmpty) return;

      var contentLength = data.length;
      while (contentLength > 0 && data[contentLength - 1] == 0) {
        contentLength--;
      }
      final value = utf8.decode(data.sublist(0, contentLength)).trim();
      if (value.isEmpty ||
          value.runes.any((rune) => rune < 0x20 || rune == 0x7F)) {
        return;
      }

      _firmwareVersion = value;
      _publishDeviceInformation();
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

  void _publishDeviceInformation() {
    if (!_deviceInformationActive) return;
    final information = DeviceInformation(
      firmwareVersion: _firmwareVersion,
      batteryLevel: _usbPowered ? null : _batteryLevel,
      powerSource: _usbPowered ? DevicePowerSource.usb : null,
      powerSourceProvenance: _usbPowered
          ? DevicePowerSourceProvenance.manualOverride
          : null,
    );
    _deviceInformationController.add(information.isEmpty ? null : information);
  }

  void _clearDeviceInformation() {
    _firmwareVersion = null;
    _batteryLevel = null;
    _batterySupported = false;
    _deviceInformationActive = false;
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
    double weight;
    if (data.length == 5 || data.length == 9) {
      weight = _decodeFirstWeightBlock(data);
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
        batteryLevel: _batteryLevel ?? 0,
      ),
    );
  }

  double _decodeFirstWeightBlock(List<int> data) {
    var mantissa =
        (data[1] & 0xFF) | ((data[2] & 0xFF) << 8) | ((data[3] & 0xFF) << 16);
    if (mantissa & 0x800000 != 0) {
      mantissa -= 0x1000000;
    }
    final rawExponent = data[4];
    final exponent = rawExponent >= 0x80 ? rawExponent - 256 : rawExponent;
    return mantissa * math.pow(10, exponent).toDouble();
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
