import 'dart:async';
import 'dart:math';

import 'package:reaprime/src/models/device/ble_service_identifier.dart';
import 'package:reaprime/src/models/device/device_implementation.dart';
import 'package:reaprime/src/models/device/transport/ble_transport.dart';
import 'package:reaprime/src/models/device/transport/data_transport.dart';
import 'package:reaprime/src/models/device/impl/decent_scale/profile.dart';
import 'package:reaprime/src/models/device/impl/decent_scale/protocol.dart';
import 'package:reaprime/src/services/serial/serial_service_desktop.dart';
import 'package:logging/logging.dart' as logging;
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/scale.dart';
import 'package:reaprime/src/models/errors.dart';
import 'package:rxdart/subjects.dart';

class DecentScale
    implements Scale, TransportHandoffScale, DisconnectToSleepScale {
  static final BleServiceIdentifier serviceIdentifier =
      BleServiceIdentifier.short('fff0');
  static final BleServiceIdentifier dataCharacteristic =
      BleServiceIdentifier.short('fff4');
  static final BleServiceIdentifier writeCharacteristic =
      BleServiceIdentifier.short('36f5');

  static const _initializationProbeTimeout = Duration(seconds: 2);
  static const _profileProbeTimeout = Duration(milliseconds: 800);
  static const _duplicateCommandDelay = Duration(milliseconds: 50);
  static const _weightFrameLengths = {7, 10};

  final String _deviceId;

  final StreamController<ScaleSnapshot> _streamController =
      StreamController.broadcast();

  final BLETransport _device;

  final logging.Logger _log = logging.Logger("Decent scale");

  Timer? _maintenanceTimer;

  static const _watchdogWarningTicks = 3;
  static const _watchdogDisconnectTicks = 5;
  int _ticksSinceLastNotification = 0;
  bool _watchdogRetryAttempted = false;
  int _totalNotifications = 0;
  int _maintenanceTicks = 0;

  Timer? _notificationWatchdog;
  Future<void>? _notificationRecovery;
  Future<void>? _displayOperation;
  Completer<void>? _initializationNotification;
  static const Duration _notificationWatchdogTimeout = Duration(seconds: 5);
  int _maintenanceGeneration = 0;
  int _displayGeneration = 0;
  bool _desiredDisplaySleeping = false;

  DecentScaleProfile _profile = DecentScaleProfile.conservative;
  int _profileAttempt = 0;
  Completer<void>? _statusEvidence;
  Completer<void>? _voltageEvidence;
  bool _statusResponseSeen = false;
  int? _statusFirmwareMarker;
  DecentHdsFirmwareVersion? _hdsFirmwareVersion;
  bool _sawTimestampedWeightFrame = false;
  bool _voltageProbeAccepted = false;

  DecentScale({required BLETransport transport})
    : _deviceId = transport.id,
      _device = transport;

  Future<bool> _writeCommand(
    List<int> commandBytes, {
    Duration? timeout,
    bool withResponse = true,
  }) async {
    try {
      await _device.write(
        serviceIdentifier.long,
        writeCharacteristic.long,
        buildDecentScaleCommand(commandBytes),
        timeout: timeout,
        withResponse: withResponse,
      );
      return true;
    } on DeviceNotConnectedException {
      _log.info('Write failed: device not connected');
      return false;
    }
  }

  Future<void> _writeRequiredCommand(List<int> commandBytes) async {
    if (!await _writeCommand(commandBytes)) {
      throw const DeviceNotConnectedException.scale();
    }
    if (!_profile.capabilities.unreliableCommandBuffer) return;
    await Future<void>.delayed(_duplicateCommandDelay);
    await _writeCommand(commandBytes);
  }

  Future<bool> _writeNonEssentialCommand(
    List<int> commandBytes, {
    Duration? timeout,
  }) async {
    try {
      final write = _writeCommand(commandBytes, timeout: timeout);
      return timeout == null ? await write : await write.timeout(timeout);
    } catch (error) {
      _log.warning(
        'Nonessential scale write failed (link may still be alive): '
        '$error',
      );
      return false;
    }
  }

  @override
  bool get disconnectsToSleep => !_profile.capabilities.supportsSoftSleep;

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
    if (_connectionStateController.value == ConnectionState.connected &&
        await _device.getConnectionState() == ConnectionState.connected) {
      _log.info('Already connected, skipping');
      return;
    }
    _connectionStateController.add(ConnectionState.connecting);
    _stopMaintenance();
    final attempt = _armProfileEvidence();

    try {
      await _waitForNotificationRecovery();
      await _device.connect();

      await subscription?.cancel();
      late final StreamSubscription<ConnectionState> transportListener;
      transportListener = _device.connectionState
          .where((state) => state == ConnectionState.disconnected)
          .listen((_) {
            if (!identical(subscription, transportListener)) return;
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
      subscription = transportListener;

      final services = await _device.discoverServices();
      if (!serviceIdentifier.matchesAny(services)) {
        throw Exception(
          'Expected service ${serviceIdentifier.long} not found. '
          'Discovered services: $services',
        );
      }
      if (_isSleeping) {
        await _registerNotifications(attempt);
      } else {
        await _confirmDataChannel(attempt);
        unawaited(
          _negotiateProfile(attempt).catchError((
            Object error,
            StackTrace stackTrace,
          ) {
            _log.warning(
              'Decent scale: profile negotiation failed',
              error,
              stackTrace,
            );
          }),
        );
      }
      _maintenanceTimer?.cancel();
      _notificationWatchdog?.cancel();
      _ticksSinceLastNotification = 0;
      _watchdogRetryAttempted = false;
      _totalNotifications = 0;
      _maintenanceTicks = 0;
      _resetNotificationWatchdog();
      if (await _device.getConnectionState() != ConnectionState.connected) {
        throw const DeviceNotConnectedException.scale();
      }
      if (attempt != _profileAttempt) return;
      _connectionStateController.add(ConnectionState.connected);
      _startMaintenance();
    } catch (e, stackTrace) {
      if (attempt != _profileAttempt) {
        Error.throwWithStackTrace(e, stackTrace);
      }
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
    final generation = _maintenanceGeneration;
    _scheduleMaintenance(generation);
  }

  void _scheduleMaintenance(int generation) {
    _maintenanceTimer?.cancel();
    _maintenanceTimer = Timer(const Duration(seconds: 4), () {
      unawaited(_runMaintenance(generation));
    });
  }

  Future<void> _runMaintenance(int generation) async {
    if (!_isCurrentMaintenance(generation)) return;
    try {
      _maintenanceTicks++;
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
    _maintenanceTimer?.cancel();
    _maintenanceTimer = null;
    _notificationWatchdog?.cancel();
    _notificationWatchdog = null;
  }

  int _armProfileEvidence() {
    final attempt = ++_profileAttempt;
    _profile = DecentScaleProfile.conservative;
    _statusResponseSeen = false;
    _statusFirmwareMarker = null;
    _hdsFirmwareVersion = null;
    _sawTimestampedWeightFrame = false;
    _voltageProbeAccepted = false;
    _statusEvidence = Completer<void>();
    _voltageEvidence = Completer<void>();
    _log.info(
      'Decent scale: initial profile=${_profile.identity.name} '
      'capabilities=${_profile.capabilities.labels.join(',')}',
    );
    return attempt;
  }

  void _applyProfileEvidence() {
    _profile = DecentScaleProfile.fromEvidence(
      statusResponseSeen: _statusResponseSeen,
      sawTimestampedWeightFrame: _sawTimestampedWeightFrame,
      voltageProbeAccepted: _voltageProbeAccepted,
      originalFirmwareMarker: _statusFirmwareMarker,
      hdsFirmwareVersion: _hdsFirmwareVersion,
    );
  }

  bool _isCurrentProfileAttempt(int attempt) =>
      attempt == _profileAttempt &&
      !_isSleeping &&
      !_isDisconnecting &&
      _connectionStateController.value != ConnectionState.disconnected;

  Future<void> _negotiateProfile(int attempt) async {
    _log.info('Decent scale: profile negotiation started');
    final statusSeen = await _awaitStatusEvidence();
    if (!_isCurrentProfileAttempt(attempt)) return;
    _statusResponseSeen = statusSeen;
    _applyProfileEvidence();
    final voltageAccepted = await _probeHdsCapabilities(attempt);
    if (!_isCurrentProfileAttempt(attempt)) return;
    _voltageProbeAccepted = _voltageProbeAccepted || voltageAccepted;
    _applyProfileEvidence();
    _log.info(
      'Decent scale: profile=${_profile.identity.name} '
      'capabilities=${_profile.capabilities.labels.join(',')}',
    );
    if (_profile.capabilities.supportsSoftSleep) {
      await _writeNonEssentialCommand([0x0A, 0x04, 0x00, 0x00, 0x00]);
    } else {
      _log.info('Decent scale: SoftSleep withheld (capability not detected)');
    }
  }

  Future<bool> _awaitStatusEvidence() async {
    final evidence = _statusEvidence;
    if (evidence == null) return false;
    try {
      await evidence.future.timeout(_profileProbeTimeout);
      return _statusResponseSeen;
    } on TimeoutException {
      _log.info('Decent scale: status probe: no response');
      return false;
    }
  }

  Future<bool> _probeHdsCapabilities(int attempt) async {
    final evidence = _voltageEvidence;
    if (evidence == null || !_isCurrentProfileAttempt(attempt)) {
      return _voltageProbeAccepted;
    }
    final sent = await _writeNonEssentialCommand([
      0x22,
      0x00,
      0x00,
      0x00,
      0x00,
    ], timeout: _profileProbeTimeout);
    if (!_isCurrentProfileAttempt(attempt) || !sent) {
      _log.info('Decent scale: HDS voltage probe: no response');
      return _voltageProbeAccepted;
    }
    try {
      await evidence.future.timeout(_profileProbeTimeout);
      _log.info('Decent scale: HDS voltage probe accepted');
    } on TimeoutException {
      _log.info('Decent scale: HDS voltage probe: no response');
    }
    return _voltageProbeAccepted;
  }

  Future<bool> _confirmDataChannel(
    int attempt, {
    bool Function()? isCurrent,
  }) async {
    bool current() => attempt == _profileAttempt && (isCurrent?.call() ?? true);
    final firstNotification = Completer<void>();
    _initializationNotification = firstNotification;
    try {
      for (var retry = 0; retry < 2; retry++) {
        if (retry == 0) {
          await _registerNotifications(attempt);
        } else {
          await _device.resetSubscription(
            serviceIdentifier.long,
            dataCharacteristic.long,
            (data) => _parseNotification(data, attempt),
          );
        }
        if (!current()) return false;
        await _sendLedOnAndRequestStatus(isCurrent: current);
        if (!current()) return false;
        try {
          await firstNotification.future.timeout(_initializationProbeTimeout);
          return current();
        } on TimeoutException {
          if (!current()) return false;
          if (retry == 1) {
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

  @override
  Future<void> disconnectForHandoff() => _disconnect(powerOff: false);

  Future<void> _disconnect({required bool powerOff}) async {
    if (_isDisconnecting) {
      return;
    }
    _isDisconnecting = true;
    final uptimeSec = _maintenanceTicks * 4;
    _log.info(
      "disconnecting (notifications=$_totalNotifications, "
      "uptime=${uptimeSec}s, powerOff=$powerOff)",
    );
    final activeSubscription = subscription;
    subscription = null;
    activeSubscription?.cancel();
    _stopMaintenance();
    if (powerOff && _profile.capabilities.supportsPowerOff) {
      try {
        await _sendPowerOff().timeout(const Duration(seconds: 2));
      } catch (e) {
        _log.fine('power-off write skipped (device likely already off): $e');
      }
    } else if (powerOff) {
      _log.info('Decent scale: power-off withheld (capability not detected)');
    }
    try {
      await _device.disconnect();
      _connectionStateController.add(ConnectionState.disconnected);
    } finally {
      _isDisconnecting = false;
    }
  }

  @override
  Future<void> tare() async {
    await _writeRequiredCommand([0x0F, 0x00, 0x00, 0x00, 0x00]);
  }

  Future<bool> _sendLedOnAndRequestStatus({bool Function()? isCurrent}) async {
    if (isCurrent?.call() == false) return false;
    final sent = await _writeNonEssentialCommand([
      0x0A,
      0x01,
      0x01,
      0x00,
      0x00,
    ]);
    if (!sent &&
        await _device.getConnectionState() != ConnectionState.connected) {
      throw const DeviceNotConnectedException.scale();
    }
    return sent;
  }

  Future<void> _sendOledOff() async {
    await _writeNonEssentialCommand([0x0A, 0x04, 0x01, 0x00, 0x00]);
    await Future.delayed(const Duration(milliseconds: 100));
    await _writeNonEssentialCommand([0x0A, 0x00, 0x00, 0x00, 0x00]);
  }

  bool _isSleeping = false;

  @override
  Future<void> sleepDisplay() async {
    _desiredDisplaySleeping = true;
    _displayGeneration++;
    _profileAttempt++;
    _isSleeping = true;
    _notificationWatchdog?.cancel();
    if (_profile.capabilities.supportsSoftSleep) {
      _log.info('Putting Decent Scale display to sleep');
      await _sendOledOff();
      if (await _device.getConnectionState() != ConnectionState.connected) {
        await _disconnect(powerOff: false);
      }
      return;
    }
    _log.info('Decent scale: disconnecting for sleep (SoftSleep unavailable)');
    await _disconnect(powerOff: false);
  }

  Future<void> _sendPowerOff() async {
    _log.info("sending power off");
    await _writeNonEssentialCommand([
      0x0A,
      0x02,
      0x00,
      0x00,
      0x00,
    ], timeout: const Duration(seconds: 10));
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
        final attempt = _armProfileEvidence();
        _notificationWatchdog?.cancel();
        try {
          final confirmed = await _confirmDataChannel(
            attempt,
            isCurrent: () =>
                generation == _displayGeneration && !_desiredDisplaySleeping,
          );
          if (!confirmed) continue;
          unawaited(
            _negotiateProfile(attempt).catchError((
              Object error,
              StackTrace stackTrace,
            ) {
              _log.warning(
                'Decent scale: profile negotiation failed',
                error,
                stackTrace,
              );
            }),
          );
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

  Future<void> _registerNotifications(int attempt) async {
    await _waitForNotificationRecovery();
    if (attempt != _profileAttempt) return;
    await _subscribeNotifications(attempt);
  }

  Future<void> _waitForNotificationRecovery() async {
    final pending = _notificationRecovery;
    if (pending != null) {
      try {
        await pending;
      } catch (_) {}
    }
  }

  Future<void> _subscribeNotifications(int attempt) async {
    await _device.subscribe(
      serviceIdentifier.long,
      dataCharacteristic.long,
      (data) => _parseNotification(data, attempt),
    );
  }

  Future<void> _retryNotifications() async {
    if (_notificationRecovery != null || _isDisconnecting) return;
    final operation = _subscribeNotifications(_profileAttempt);
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

  void _parseNotification(List<int> data, int attempt) {
    if (attempt != _profileAttempt) return;
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
      _recordWeightFrame(data, attempt);
      _parseWeight(data);
    } else if (frameType == 'status') {
      _recordStatusFrame(data, attempt);
    } else {
      _recordVoltageFrame(data, attempt);
    }
  }

  static String? _originalFirmwareVersion(int marker) => switch (marker) {
    0xFE => '1.0',
    0x02 => '1.1',
    0x03 => '1.2',
    _ => null,
  };

  static String? _dataFrameType(List<int> data) {
    if (data.length < 2 || data[0] != 0x03) return null;
    final command = data[1];
    if ((command == 0xCE || command == 0xCA) &&
        _weightFrameLengths.contains(data.length)) {
      return 'weight';
    }
    if (command == 0x0A && data.length == 7) return 'status';
    if (command == 0x22 && data.length == 7) return 'voltage';
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

  void _recordWeightFrame(List<int> data, int attempt) {
    if (!_isCurrentProfileAttempt(attempt)) return;
    if (data.length == 10) {
      _sawTimestampedWeightFrame = true;
      _applyProfileEvidence();
    }
  }

  void _recordStatusFrame(List<int> data, int attempt) {
    if (!_isCurrentProfileAttempt(attempt)) return;
    final frame = parseDecentStatusFrame(data);
    if (frame == null) return;
    _statusResponseSeen = true;
    _statusFirmwareMarker = frame.originalFirmwareMarker;
    _hdsFirmwareVersion = frame.hdsFirmwareVersion;
    _batteryLevel = min(frame.batteryLevel, 100);
    _applyProfileEvidence();
    final marker = frame.originalFirmwareMarker
        .toRadixString(16)
        .padLeft(2, '0');
    final originalVersion = _originalFirmwareVersion(
      frame.originalFirmwareMarker,
    );
    final evidence = originalVersion == null
        ? 'original-fw=0x$marker'
        : 'original-fw=0x$marker fw=$originalVersion';
    final hdsVersion = frame.hdsFirmwareVersion;
    _log.info(
      'status response: $evidence'
      '${hdsVersion == null ? '' : ' hds-fw=$hdsVersion'}',
    );
    if (!(_statusEvidence?.isCompleted ?? true)) {
      _statusEvidence!.complete();
    }
  }

  void _recordVoltageFrame(List<int> data, int attempt) {
    if (!_isCurrentProfileAttempt(attempt)) return;
    final frame = parseDecentVoltageFrame(data);
    if (frame == null) return;
    _voltageProbeAccepted = true;
    _applyProfileEvidence();
    _log.fine('voltage response: ${frame.voltage}');
    if (!(_voltageEvidence?.isCompleted ?? true)) {
      _voltageEvidence!.complete();
    }
  }
}
