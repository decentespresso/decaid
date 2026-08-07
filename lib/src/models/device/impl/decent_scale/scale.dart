import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:reaprime/src/models/device/ble_service_identifier.dart';
import 'package:reaprime/src/models/device/device_implementation.dart';
import 'package:reaprime/src/models/device/transport/ble_transport.dart';
import 'package:reaprime/src/models/device/transport/data_transport.dart';
import 'package:reaprime/src/services/serial/serial_service_desktop.dart';
import 'package:logging/logging.dart' as logging;
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/scale.dart';
import 'package:reaprime/src/models/errors.dart';
import 'package:rxdart/subjects.dart';

class DecentScale implements Scale, TransportHandoffScale {
  static final BleServiceIdentifier serviceIdentifier =
      BleServiceIdentifier.short('fff0');
  static final BleServiceIdentifier dataCharacteristic =
      BleServiceIdentifier.short('fff4');
  static final BleServiceIdentifier writeCharacteristic =
      BleServiceIdentifier.short('36f5');

  static final bool isUsingHeartBeat = false;
  static const _initializationProbeTimeout = Duration(seconds: 2);
  static const _weightFrameLengths = {7, 10};

  final String _deviceId;

  final StreamController<ScaleSnapshot> _streamController =
      StreamController.broadcast();

  final BLETransport _device;

  final logging.Logger _log = logging.Logger("Decent scale");

  Timer? _heartbeatTimer;

  // Watchdog: heartbeat fires every 4s; warn after 3 missed (12s), disconnect after 5 (20s).
  // BLE is slower than USB so thresholds are more generous than HDSSerial.
  static const _watchdogWarningTicks = 3;
  static const _watchdogDisconnectTicks = 5;
  int _ticksSinceLastNotification = 0;
  bool _watchdogRetryAttempted = false;
  int _totalNotifications = 0;
  int _heartbeatTotalTicks = 0;

  // Notification-level watchdog: scale fires at ~10 Hz (every ~100ms).
  // If no notification arrives for 1s, re-subscribe immediately — the
  // notification stream may have silently broken without the BLE link
  // dropping (GATT busy-window, Android radio starvation, etc).
  // Resets on every notification (_parseNotification).
  Timer? _notificationWatchdog;
  Future<void>? _notificationRecovery;
  Future<void>? _displayOperation;
  Completer<void>? _initializationNotification;
  static const Duration _notificationWatchdogTimeout = Duration(seconds: 5);
  int _maintenanceGeneration = 0;
  int _displayGeneration = 0;
  bool _desiredDisplaySleeping = false;

  DecentScale({required BLETransport transport})
    : _deviceId = transport.id,
      _device = transport;

  /// Build a 7-byte Decent Scale BLE command frame.
  /// Prepends [0x03] header and appends XOR checksum over bytes 0-5.
  /// Matches canonical `calculateChecksum` in openscale: XOR all bytes
  /// (including header), starting from 0.
  static Uint8List _buildCommand(List<int> commandBytes) {
    final bytes = <int>[0x03, ...commandBytes];
    int xor = 0;
    for (final b in bytes) {
      xor ^= b;
    }
    bytes.add(xor);
    return Uint8List.fromList(bytes);
  }

  Future<bool> _writeCommand(
    List<int> commandBytes, {
    Duration? timeout,
    bool withResponse = true,
  }) async {
    try {
      await _device.write(
        serviceIdentifier.long,
        writeCharacteristic.long,
        _buildCommand(commandBytes),
        timeout: timeout,
        withResponse: withResponse,
      );
      return true;
    } on DeviceNotConnectedException {
      _log.info('Write failed: device not connected');
      // Don't call disconnect() here — the transport already emitted
      // disconnected (in _handleGattError), which triggers the
      // connectionState listener that calls disconnect(). Re-entering
      // disconnect from a write path risks a re-entrant teardown.
      // The _isDisconnecting guard would catch it, but the extra
      // log noise is confusing.
      return false;
    }
  }

  Future<void> _writeRequiredCommand(List<int> commandBytes) async {
    if (!await _writeCommand(commandBytes)) {
      throw const DeviceNotConnectedException.scale();
    }
  }

  @override
  Stream<ScaleSnapshot> get currentSnapshot => _streamController.stream;

  @override
  String get deviceId => _deviceId;

  @override
  DeviceImplementation get implementation => DeviceImplementation.decentScale;

  @override
  TransportType get transportType => _device.transportType;

  @override
  DeviceType get type => DeviceType.scale;

  @override
  String get name => "Decent Scale";

  final BehaviorSubject<ConnectionState> _connectionStateController =
      BehaviorSubject.seeded(ConnectionState.discovered);

  @override
  Stream<ConnectionState> get connectionState =>
      _connectionStateController.stream;

  StreamSubscription<ConnectionState>? subscription;
  @override
  Future<void> onConnect() async {
    _log.info("on connect (id=$deviceId)");
    // Check actual BLE link state via the fork API. The local
    // BehaviorSubject is freshly seeded (discovered) on each new
    // DecentScale instance — it cannot detect an already-live
    // connection created by a prior transport instance.
    if (_connectionStateController.value == ConnectionState.connected &&
        await _device.getConnectionState() == ConnectionState.connected) {
      _log.info('Already connected, skipping');
      return;
    }
    _connectionStateController.add(ConnectionState.connecting);
    _stopMaintenance();

    try {
      await _waitForNotificationRecovery();
      await _device.connect();

      await subscription?.cancel();
      subscription = _device.connectionState
          .where((state) => state == ConnectionState.disconnected)
          .listen((_) {
            _log.info("Transport disconnected");
            unawaited(
              _disconnect(powerOff: false).catchError((
                Object error,
                StackTrace stackTrace,
              ) {
                _log.severe(
                  'Failed to tear down disconnected scale transport',
                  error,
                  stackTrace,
                );
              }),
            );
          });

      final services = await _device.discoverServices();
      if (!serviceIdentifier.matchesAny(services)) {
        throw Exception(
          'Expected service ${serviceIdentifier.long} not found. '
          'Discovered services: $services',
        );
      }
      if (_isSleeping) {
        await _registerNotifications();
      } else {
        await _confirmDataChannel();
      }
      _heartbeatTimer?.cancel();
      _notificationWatchdog?.cancel();
      _ticksSinceLastNotification = 0;
      _watchdogRetryAttempted = false;
      _totalNotifications = 0;
      _heartbeatTotalTicks = 0;
      _resetNotificationWatchdog();
      if (isUsingHeartBeat && !await _sendHeartBeat()) {
        throw const DeviceNotConnectedException.scale();
      }
      if (await _device.getConnectionState() != ConnectionState.connected) {
        throw const DeviceNotConnectedException.scale();
      }
      _connectionStateController.add(ConnectionState.connected);
      _startMaintenance();
    } catch (e, stackTrace) {
      _log.warning('Failed to initialize scale: $e');
      await subscription?.cancel();
      subscription = null;
      _stopMaintenance();
      try {
        await _device.disconnect();
      } catch (disconnectError, disconnectStackTrace) {
        _log.severe(
          'Failed to tear down scale transport',
          disconnectError,
          disconnectStackTrace,
        );
        Error.throwWithStackTrace(disconnectError, disconnectStackTrace);
      }
      _connectionStateController.add(ConnectionState.disconnected);
      Error.throwWithStackTrace(e, stackTrace);
    }
  }

  void _startMaintenance() {
    final generation = ++_maintenanceGeneration;
    _scheduleMaintenance(generation);
  }

  void _scheduleMaintenance(int generation) {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer(const Duration(seconds: 4), () {
      unawaited(_runMaintenance(generation));
    });
  }

  Future<void> _runMaintenance(int generation) async {
    if (!_isCurrentMaintenance(generation)) return;
    try {
      _heartbeatTotalTicks++;
      if (_heartbeatTotalTicks.isEven && !_isSleeping) {
        await _requestBatteryData();
      }
      if (!_isSleeping) {
        _ticksSinceLastNotification++;
        if (_ticksSinceLastNotification >= _watchdogDisconnectTicks) {
          await _disconnect(powerOff: false);
          return;
        }
        if (_ticksSinceLastNotification >= _watchdogWarningTicks &&
            !_watchdogRetryAttempted) {
          _watchdogRetryAttempted = true;
          await _retryNotifications();
        }
      }
      await _sendHeartBeat();
    } on TimeoutException catch (error) {
      _log.warning('Scale maintenance timed out: $error');
    } catch (error, stackTrace) {
      _log.warning('Scale maintenance failed', error, stackTrace);
    } finally {
      if (_isCurrentMaintenance(generation)) {
        _scheduleMaintenance(generation);
      }
    }
  }

  bool _isCurrentMaintenance(int generation) =>
      generation == _maintenanceGeneration &&
      _connectionStateController.value == ConnectionState.connected &&
      !_isDisconnecting;

  void _stopMaintenance() {
    _maintenanceGeneration++;
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    _notificationWatchdog?.cancel();
    _notificationWatchdog = null;
  }

  Future<bool> _confirmDataChannel({bool Function()? isCurrent}) async {
    bool current() => isCurrent?.call() ?? true;
    final firstNotification = Completer<void>();
    _initializationNotification = firstNotification;
    try {
      for (var attempt = 0; attempt < 2; attempt++) {
        if (attempt == 0) {
          await _registerNotifications();
        } else {
          await _device.resetSubscription(
            serviceIdentifier.long,
            dataCharacteristic.long,
            _parseNotification,
          );
        }
        if (!current()) return false;
        final requestSent = await _sendOledOn(isCurrent: current);
        if (!current()) return false;
        if (!requestSent) {
          throw const DeviceNotConnectedException.scale();
        }
        try {
          await firstNotification.future.timeout(_initializationProbeTimeout);
          return current();
        } on TimeoutException {
          if (!current()) return false;
          if (attempt == 1) {
            await _readSilentDataChannelDiagnostic();
            rethrow;
          }
        }
      }
      return false;
    } finally {
      if (identical(_initializationNotification, firstNotification)) {
        _initializationNotification = null;
      }
    }
  }

  Future<void> _readSilentDataChannelDiagnostic() async {
    try {
      final data = await _device.read(
        serviceIdentifier.long,
        dataCharacteristic.long,
        timeout: const Duration(seconds: 1),
      );
      _log.warning(
        'Silent FFF4 diagnostic read returned ${data.length} bytes '
        '(${_dataFrameType(data) ?? 'invalid'})',
      );
    } catch (error, stackTrace) {
      _log.warning('Silent FFF4 diagnostic read failed', error, stackTrace);
    }
  }

  bool _isDisconnecting = false;

  @override
  disconnect() async => _disconnect(powerOff: true);

  /// [TransportHandoffScale]: release the BLE link WITHOUT powering the
  /// physical scale off, so the controller can hand the active-scale role to
  /// another transport (USB/WiFi) of the SAME physical Half Decent Scale.
  /// Powering off here would turn the shared device off mid-switch.
  @override
  Future<void> disconnectForHandoff() => _disconnect(powerOff: false);

  Future<void> _disconnect({required bool powerOff}) async {
    if (_isDisconnecting) {
      return;
    }
    _isDisconnecting = true;
    final uptimeSec = _heartbeatTotalTicks * 4;
    _log.info(
      "disconnecting (notifications=$_totalNotifications, "
      "uptime=${uptimeSec}s, powerOff=$powerOff)",
    );
    final activeSubscription = subscription;
    subscription = null;
    activeSubscription?.cancel();
    _stopMaintenance();
    if (powerOff) {
      try {
        // Best-effort: `disconnect()` often fires *on* a transport-state
        // disconnected event, in which case the write throws `device is
        // disconnected` immediately. On the happy path the scale powers
        // off after acking and severs BLE — neither outcome should block
        // or escalate. The 2 s timeout caps the wait so a flaky link
        // can't stall the rest of the disconnect sequence.
        await _sendPowerOff().timeout(const Duration(seconds: 2));
      } catch (e) {
        _log.fine('power-off write skipped (device likely already off): $e');
      }
    }
    // `BluePlusTransport.disconnect` swallows its own errors internally,
    // so no extra try/catch needed here.
    try {
      await _device.disconnect();
      _connectionStateController.add(ConnectionState.disconnected);
    } finally {
      _isDisconnecting = false;
    }
  }

  @override
  Future<void> tare() async {
    await _writeRequiredCommand([0x0F, 0x00, 0x00, 0x00, 0x01]);
  }

  Future<bool> _sendHeartBeat() async {
    if (!isUsingHeartBeat) {
      return true;
    }
    _log.finest("send hb");
    // Heartbeat ping: tells the scale the app is still alive so it won't
    // auto-sleep or disconnect. Send even when _isSleeping — without it
    // HDS firmware times out and disconnects BLE, which wakes the display.
    try {
      final sent = await _writeCommand(
        [0x0A, 0x03, 0xFF, 0xFF, 0x00],
        timeout: const Duration(seconds: 2),
        withResponse: true,
      );
      if (!sent) {
        await _disconnect(powerOff: false);
      }
      return sent;
    } catch (e) {
      _log.warning('Heartbeat write failed (transient): $e');
      return true;
    }
  }

  /// Causes the scale to respond with battery level, while the actual request
  /// is to turn on the display (OledOn)
  Future<bool> _requestBatteryData() async {
    final heartbeatByte = isUsingHeartBeat ? 0x01 : 0x00;
    return _writeCommand([0x0A, 0x01, 0x01, 0x00, heartbeatByte]);
  }

  Future<bool> _sendOledOn({bool Function()? isCurrent}) async {
    if (isCurrent?.call() == false) return false;
    final heartbeatByte = isUsingHeartBeat ? 0x01 : 0x00;
    if (!await _requestBatteryData()) {
      return false;
    }
    await Future.delayed(Duration(milliseconds: 100));
    if (isCurrent?.call() == false) return false;
    return _writeCommand([0x0A, 0x04, 0x00, 0x00, heartbeatByte]);
  }

  Future<void> _sendOledOff() async {
    await _writeCommand([0x0A, 0x04, 0x01, 0x00, 0x01]);
    await Future.delayed(Duration(milliseconds: 100));
    await _writeCommand([0x0A, 0x00, 0x01, 0x00, 0x01]);
  }

  bool _isSleeping = false;

  @override
  Future<void> sleepDisplay() async {
    _desiredDisplaySleeping = true;
    _displayGeneration++;
    _isSleeping = true;
    _notificationWatchdog?.cancel();
    _log.info('Putting Decent Scale display to sleep');
    await _sendOledOff();
  }

  Future<void> _sendPowerOff() async {
    _log.info("sending power off");
    await _writeCommand([
      0x0A,
      0x02,
      0x00,
      0x00,
      0x00,
    ], timeout: Duration(seconds: 10));
  }

  @override
  Future<void> wakeDisplay() {
    _desiredDisplaySleeping = false;
    _displayGeneration++;
    return _displayOperation ??= _runWakeDisplay();
  }

  Future<void> _runWakeDisplay() async {
    try {
      while (!_desiredDisplaySleeping) {
        final generation = _displayGeneration;
        _isSleeping = false;
        _notificationWatchdog?.cancel();
        try {
          final confirmed = await _confirmDataChannel(
            isCurrent: () =>
                generation == _displayGeneration && !_desiredDisplaySleeping,
          );
          if (!confirmed) continue;
          _ticksSinceLastNotification = 0;
          _watchdogRetryAttempted = false;
          _resetNotificationWatchdog();
          return;
        } catch (_) {
          if (generation == _displayGeneration && !_desiredDisplaySleeping) {
            await _disconnect(powerOff: false);
            rethrow;
          }
        }
      }
    } finally {
      _displayOperation = null;
    }
  }

  bool _timerCommandInFlight = false;

  @override
  Future<void> startTimer() async {
    if (_timerCommandInFlight) return;
    _timerCommandInFlight = true;
    try {
      await _writeRequiredCommand([0x0B, 0x03, 0x00, 0x00, 0x00]);
    } finally {
      _timerCommandInFlight = false;
    }
  }

  @override
  Future<void> stopTimer() async {
    if (_timerCommandInFlight) return;
    _timerCommandInFlight = true;
    try {
      await _writeRequiredCommand([0x0B, 0x00, 0x00, 0x00, 0x00]);
    } finally {
      _timerCommandInFlight = false;
    }
  }

  @override
  Future<void> resetTimer() async {
    if (_timerCommandInFlight) return;
    _timerCommandInFlight = true;
    try {
      await _writeRequiredCommand([0x0B, 0x02, 0x00, 0x00, 0x00]);
    } finally {
      _timerCommandInFlight = false;
    }
  }

  // --- BLE notifications -----------------------------------------------

  Future<void> _registerNotifications() async {
    await _waitForNotificationRecovery();
    await _subscribeNotifications();
  }

  Future<void> _waitForNotificationRecovery() async {
    final pending = _notificationRecovery;
    if (pending != null) {
      try {
        await pending;
      } catch (_) {}
    }
  }

  Future<void> _subscribeNotifications() async {
    await _device.subscribe(
      serviceIdentifier.long,
      dataCharacteristic.long,
      _parseNotification,
    );
  }

  Future<void> _retryNotifications() async {
    if (_notificationRecovery != null || _isDisconnecting) return;
    final operation = _subscribeNotifications();
    _notificationRecovery = operation;
    try {
      await operation;
    } catch (error, stackTrace) {
      _log.warning('BLE notification re-subscribe failed', error, stackTrace);
    } finally {
      if (identical(_notificationRecovery, operation)) {
        _notificationRecovery = null;
      }
    }
  }

  void _resetNotificationWatchdog() {
    _notificationWatchdog?.cancel();
    if (!_isSleeping && !_isDisconnecting) {
      _notificationWatchdog = Timer(_notificationWatchdogTimeout, () {
        _log.warning(
          'No BLE notifications for ${_notificationWatchdogTimeout.inMilliseconds}ms '
          '(total=$_totalNotifications), re-subscribing',
        );
        unawaited(_retryNotifications());
      });
    }
  }

  void _parseNotification(List<int> data) {
    final frameType = _dataFrameType(data);
    if (frameType == null) return;
    if (!(_initializationNotification?.isCompleted ?? true)) {
      _initializationNotification!.complete();
    }
    _ticksSinceLastNotification = 0;
    _watchdogRetryAttempted = false;
    _totalNotifications++;
    _resetNotificationWatchdog();
    _log.finest("$hashCode recv: ${data[1].toHex()}");
    if (frameType == 'weight') {
      _parseWeight(data);
    } else {
      _parseStatusResponse(data);
    }
  }

  static String? _dataFrameType(List<int> data) {
    if (data.length < 2 || data[0] != 0x03) return null;
    final command = data[1];
    if ((command == 0xCE || command == 0xCA) &&
        _weightFrameLengths.contains(data.length)) {
      return 'weight';
    }
    if (command == 0x0A && data.length == 7) return 'status';
    return null;
  }

  void _parseWeight(List<int> data) {
    var raw = (data[2] << 8) | data[3];
    if ((raw & 0x8000) != 0) raw -= 0x10000;
    _streamController.add(
      ScaleSnapshot(
        timestamp: DateTime.now(),
        weight: raw / 10,
        batteryLevel: _batteryLevel.toInt(),
      ),
    );
  }

  int _batteryLevel = 100;
  void _parseStatusResponse(List<int> data) {
    final level = data[4];
    _log.fine("status response: ${data.map((e) => e.toRadixString(16))}");
    _batteryLevel = min(level, 100);
  }
}
