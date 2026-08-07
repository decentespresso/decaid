import 'dart:async';
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

/// Atomax Skale2 scale implementation.
///
/// Uses a simple single-byte command protocol for tare, display, and timer
/// controls. Weight is reported as a little-endian int32 divided by 2560.
/// Battery level is read from the standard BLE Battery Service (0x180F).
class Skale2Scale implements Scale {
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

  final String _deviceId;

  final StreamController<ScaleSnapshot> _streamController =
      StreamController.broadcast();

  final BLETransport _transport;

  int _batteryLevel = 0;

  /// Logger for Skale2-specific warnings (e.g. button subscription failure).
  final _log = logging.Logger('Skale2Scale');

  /// Whether we have an active subscription to the weight characteristic (EF81).
  bool _weightSubscribed = false;

  /// Whether we have an active subscription to the button characteristic (EF82).
  bool _buttonSubscribed = false;

  /// Delay between init steps, matching de1app/Decenza staggered sequence.
  static const _initStepDelay = Duration(milliseconds: 1000);

  Skale2Scale({required BLETransport transport})
    : _transport = transport,
      _deviceId = transport.id;

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
            // Subscriptions are lost when the BLE link drops.
            _weightSubscribed = false;
            _buttonSubscribed = false;
            disconnectSub?.cancel();
          });

      final services = await _transport.discoverServices();
      if (!serviceIdentifier.matchesAny(services)) {
        throw Exception(
          'Expected service ${serviceIdentifier.long} not found. '
          'Discovered services: $services',
        );
      }
      await _initScale();
      _connectionStateController.add(ConnectionState.connected);
    } catch (e) {
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

  // --- Initialization ---
  // Follows the de1app / Decenza staggered sequence:
  //   1. LCD ON immediately  (0xED + 0xEC)
  //   2. After 1s: subscribe weight notifications (EF81)
  //   3. After 2s: subscribe button notifications (EF82)
  //   4. After 3s: LCD ON again + set grams (0x03)
  // The Skale2's command buffer is fragile — back-to-back operations
  // without spacing can cause silent drops (de1app double-sends LCD ON
  // for exactly this reason).  See GH #53 / #421.
  Future<void> _initScale() async {
    // 1. Turn display on and set to weight mode — BEFORE subscribing.
    await _sendDisplayOn();
    await _sendDisplayWeight();

    // 2. Subscribe to weight notifications after a settle delay.
    await Future.delayed(_initStepDelay);
    await _subscribeWeight();

    // 3. Subscribe to button notifications after another delay.
    await Future.delayed(_initStepDelay);
    await _subscribeButton();

    // Read battery level (best-effort, does not affect scale operation).
    try {
      final batteryData = await _transport.read(
        batteryService.long,
        batteryCharacteristic.long,
      );
      if (batteryData.isNotEmpty) {
        _batteryLevel = batteryData[0];
      }
    } catch (_) {
      // Battery service may not be available.
    }

    // 4. Re-send LCD ON + set grams after final delay (double-send pattern).
    await Future.delayed(_initStepDelay);
    await _sendDisplayOn();
    await _sendDisplayWeight();
    await _safeWrite(Uint8List.fromList([0x03]));
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
      // Button characteristic may not be available on all devices, but
      // log a warning so the failure is visible (unlike the previous
      // silent swallow).  This is the most likely cause of the
      // "buttons stop working after sleep" bug — if the initial
      // subscription silently failed, it was never retried.
      _log.warning('Failed to subscribe to button notifications: $e');
    }
  }

  /// Safe write — catches [DeviceNotConnectedException] so a write to a
  /// disconnected scale doesn't escape as a FATAL (Crashlytics fa51312d).
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

    // Re-subscribe to notifications if they were lost (e.g. BLE link
    // dropped during sleep).  The Skale2 may silently lose CCCD
    // subscriptions when its display is off — de1app handles this by
    // re-running the full connect sequence, but we take the lighter
    // approach of only re-subscribing what's missing.
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
    if (data.length < 4) return;

    final byteData = ByteData(4);
    byteData.setUint8(0, data[0] & 0xFF);
    byteData.setUint8(1, data[1] & 0xFF);
    byteData.setUint8(2, data[2] & 0xFF);
    byteData.setUint8(3, data[3] & 0xFF);
    final rawValue = byteData.getInt32(0, Endian.little);

    final weight = rawValue / 2560.0;

    _streamController.add(
      ScaleSnapshot(
        timestamp: DateTime.now(),
        weight: weight,
        batteryLevel: _batteryLevel,
      ),
    );
  }

  void _parseButtonNotification(List<int> data) {
    // Button press notifications - currently informational only.
    // Could be used to trigger tare or other actions in the future.
  }

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
