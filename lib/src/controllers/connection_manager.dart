import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:collection/collection.dart';
import 'package:logging/logging.dart';
import 'package:reaprime/src/controllers/connection/attach_reconnect_coordinator.dart';
import 'package:reaprime/src/controllers/connection/connection_attempt_policy.dart';
import 'package:reaprime/src/controllers/connection/connection_selection_session.dart';
import 'package:reaprime/src/controllers/connection/disconnect_expectations.dart';
import 'package:reaprime/src/controllers/connection/disconnect_supervisor.dart';
import 'package:reaprime/src/controllers/connection/policy_resolver.dart';
import 'package:reaprime/src/controllers/connection/scale_watch.dart';
import 'package:reaprime/src/controllers/connection/scan_orchestrator.dart';
import 'package:reaprime/src/controllers/connection/scan_report_builder.dart';
import 'package:reaprime/src/controllers/connection/status_publisher.dart';
import 'package:reaprime/src/controllers/connection_error.dart';
import 'package:reaprime/src/controllers/de1_controller.dart';
import 'package:reaprime/src/controllers/remembered_devices_controller.dart';
import 'package:reaprime/src/controllers/scale_controller.dart';
import 'package:reaprime/src/models/device/bengle_interface.dart';
import 'package:reaprime/src/models/device/de1_interface.dart';
import 'package:reaprime/src/models/device/transport/ble_connect_exception.dart';
import 'package:reaprime/src/models/device/impl/bengle/bengle_virtual_scale.dart';
import 'package:reaprime/src/models/device/machine.dart';
import 'package:reaprime/src/models/adapter_state.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/device_attach_notifier.dart';
import 'package:reaprime/src/models/device/device_scanner.dart';
import 'package:reaprime/src/models/device/transport/data_transport.dart';
import 'package:reaprime/src/models/device/scale.dart';
import 'package:reaprime/src/models/device/scan_filter.dart';
import 'package:reaprime/src/models/device/simulated_device.dart';
import 'package:reaprime/src/models/device/usb_attach_probe.dart';
import 'package:reaprime/src/models/scan_report.dart';
import 'package:reaprime/src/settings/scale_power_mode.dart';
import 'package:reaprime/src/settings/settings_controller.dart';
import 'package:rxdart/rxdart.dart';

enum ConnectionPhase {
  idle,
  scanning,
  connectingMachine,
  connectingScale,
  ready,
}

enum AmbiguityReason { machinePicker, scalePicker }

enum ConnectionIntent {
  automatic,
  explicitDiscovery,
  adapterRecovery,
  scaleRecovery,
}

class TransportCondition {
  final TransportType transportType;
  final Set<DeviceType> affectedDeviceTypes;
  final ConnectionError connectionError;

  const TransportCondition({
    required this.transportType,
    required this.affectedDeviceTypes,
    required this.connectionError,
  });
}

class ConnectionStatus {
  final ConnectionPhase phase;
  final List<De1Interface> foundMachines;
  final List<Scale> foundScales;
  final AmbiguityReason? pendingAmbiguity;
  final ConnectionError? error;
  final ConnectionIntent intent;
  final TransportType? activeTargetTransport;
  final List<TransportCondition> conditions;

  const ConnectionStatus({
    this.phase = ConnectionPhase.idle,
    this.foundMachines = const [],
    this.foundScales = const [],
    this.pendingAmbiguity,
    this.error,
    this.intent = ConnectionIntent.automatic,
    this.activeTargetTransport,
    this.conditions = const [],
  });

  ConnectionStatus copyWith({
    ConnectionPhase? phase,
    List<De1Interface>? foundMachines,
    List<Scale>? foundScales,
    AmbiguityReason? Function()? pendingAmbiguity,
    ConnectionError? Function()? error,
    ConnectionIntent? intent,
    TransportType? Function()? activeTargetTransport,
    List<TransportCondition>? conditions,
  }) {
    return ConnectionStatus(
      phase: phase ?? this.phase,
      foundMachines: foundMachines ?? this.foundMachines,
      foundScales: foundScales ?? this.foundScales,
      pendingAmbiguity: pendingAmbiguity != null
          ? pendingAmbiguity()
          : this.pendingAmbiguity,
      error: error != null ? error() : this.error,
      intent: intent ?? this.intent,
      activeTargetTransport: activeTargetTransport != null
          ? activeTargetTransport()
          : this.activeTargetTransport,
      conditions: conditions ?? this.conditions,
    );
  }
}

class ConnectionManager {
  final DeviceScanner deviceScanner;
  final De1Controller de1Controller;
  final ScaleController scaleController;
  final SettingsController settingsController;

  final RememberedDevicesController? rememberedDevices;

  final _log = Logger('ConnectionManager');

  final StatusPublisher _statusPublisher = StatusPublisher();

  final BehaviorSubject<ScanReport> _scanReportSubject = BehaviorSubject();

  Stream<ConnectionStatus> get status => _statusPublisher.stream;
  ConnectionStatus get currentStatus => _statusPublisher.current;

  ScanReport? get lastScanReport => _scanReportSubject.valueOrNull;

  Stream<ScanReport> get scanReportStream => _scanReportSubject.stream;

  bool _isConnecting = false;
  bool _isConnectingMachine = false;
  bool _isConnectingScale = false;
  bool _activeScaleOnlyScan = false;
  bool _shuttingDown = false;
  Future<void>? _shutdownFuture;
  int _activeConnectionWork = 0;
  Completer<void>? _connectionWorkDone;
  ConnectionSelectionSession? _selectionSession;

  int _explicitScanGeneration = 0;

  final Duration _connectTimeout;

  bool get _machineConnected => _disconnectSupervisor.isMachineConnected;
  bool get _scaleConnected => _disconnectSupervisor.isScaleConnected;
  bool get _scaleReconnectBlockedByPowerMode =>
      settingsController.scalePowerMode == ScalePowerMode.disconnect &&
      _latestMachineState == MachineState.sleeping;

  late final DisconnectSupervisor _disconnectSupervisor;
  late final ScanOrchestrator _scanOrchestrator;
  late final ScaleWatch _scaleWatch;

  StreamSubscription<AdapterState>? _adapterSub;
  AttachReconnectCoordinator? _attachReconnectCoordinator;

  bool _usbAttachLatched = false;
  bool _automaticMachineAttemptSuperseded = false;
  bool _resumeAutomaticAfterUsbAttach = false;

  bool get _activeAutomaticMachineAttempt =>
      _isConnecting &&
      !_activeScaleOnlyScan &&
      !_attachProbeInFlight &&
      (currentStatus.intent == ConnectionIntent.automatic ||
          currentStatus.intent == ConnectionIntent.adapterRecovery);

  final DisconnectExpectations _disconnectExpectations =
      DisconnectExpectations();

  Completer<void>? _queuedScaleOnly;

  Completer<void>? _queuedExplicitScan;
  bool _adapterRecoveryQueued = false;
  bool _adapterRecoveryNeeded = false;
  int _adapterRecoveryEpoch = 0;
  AdapterState? _lastAdapterState;
  Timer? _adapterRecoveryTimer;

  @visibleForTesting
  Duration adapterRecoveryDebounce = const Duration(seconds: 1);

  Timer? _deferredScaleScan;

  Timer? _preferredScaleReconnect;

  int _scaleReconnectFailures = 0;

  Duration get _scaleReconnectBackoff {
    final multiplier = (1 << _scaleReconnectFailures).clamp(1, 12);
    final delay = scaleReconnectBaseDelay * multiplier;
    const cap = Duration(seconds: 60);
    return delay > cap ? cap : delay;
  }

  @visibleForTesting
  Duration scaleReconnectBaseDelay = const Duration(seconds: 5);

  bool _machineRecoveryActive = false;
  Timer? _machineReconnect;
  int _machineReconnectFailures = 0;

  @visibleForTesting
  Duration machineReconnectBaseDelay = const Duration(seconds: 5);

  Duration get _machineReconnectBackoff {
    final multiplier = (1 << _machineReconnectFailures).clamp(1, 12);
    final delay = machineReconnectBaseDelay * multiplier;
    const cap = Duration(seconds: 60);
    return delay > cap ? cap : delay;
  }

  MachineState? _latestMachineState;
  StreamSubscription<MachineSnapshot>? _machineSnapshotSub;

  @visibleForTesting
  Duration snapshotStalenessTimeout = const Duration(seconds: 10);

  Timer? _stateWatchdog;
  int _watchdogGeneration = 0;

  @visibleForTesting
  int snapshotStalenessReconnects = 0;

  bool _earlyStopFired = false;

  @visibleForTesting
  Duration deferredScaleScanDelay = const Duration(seconds: 3);

  bool get supportsBackgroundScaleWatch =>
      deviceScanner.supportsBackgroundWatch;

  ConnectionManager({
    required this.deviceScanner,
    required this.de1Controller,
    required this.scaleController,
    required this.settingsController,
    this.rememberedDevices,
    Duration deviceAttachSettleDelay = const Duration(milliseconds: 500),
    Duration? connectTimeout,
  }) : _connectTimeout =
           connectTimeout ??
           (Platform.isLinux
               ? const Duration(seconds: 60)
               : const Duration(seconds: 30)) {
    _disconnectSupervisor = DisconnectSupervisor(
      machineStream: de1Controller.de1,
      scaleStream: scaleController.connectionState,
      statusPublisher: _statusPublisher,
      expectations: _disconnectExpectations,
      isConnectingMachine: () => _isConnectingMachine,
      isConnectingScale: () => _isConnectingScale,
      scaleLastConnectedId: () => scaleController.lastConnectedDeviceId,
      preferredScaleId: () => settingsController.preferredScaleId,
      onMachineConnected: _handleMachineConnected,
      onMachineDisconnected: _handleMachineDisconnected,
      onUnexpectedMachineDisconnect: _startMachineRecovery,
      onScaleConnected: _cancelScaleReacquisition,
      onScaleDisconnected: _handleScaleDisconnected,
    );
    _scaleWatch = ScaleWatch(
      scanner: deviceScanner,
      shouldWatch: () =>
          _shouldRetryPreferredScale() &&
          _disconnectSupervisor.latestMachine is! BengleInterface,
      preferredScaleId: () => settingsController.preferredScaleId,
      connectScale: _connectScaleFromWatch,
      onWatchUnavailable: _maybeSchedulePreferredScaleReconnect,
    );
    _scanOrchestrator = ScanOrchestrator(
      scanner: deviceScanner,
      statusPublisher: _statusPublisher,
      connectMachineTracked: _connectMachineTracked,
      connectScaleTracked: _connectScaleTrackedGated,
      isMachineConnected: () => _machineConnected,
      isScaleConnected: () => _scaleConnected,
    );
    _listenForAdapter();
    final attachNotifier = deviceScanner is DeviceAttachNotifier
        ? deviceScanner as DeviceAttachNotifier
        : null;
    _attachReconnectCoordinator = attachNotifier == null
        ? null
        : AttachReconnectCoordinator(
            attachEvents: attachNotifier.deviceAttached,
            settleDelay: deviceAttachSettleDelay,
            shouldAttempt: _shouldAttemptAttachReconnect,
            attempt: _attemptAttachReconnect,
            recover: _ensureMachineRecoveryArmed,
            onLatched: _onUsbAttachLatched,
            onSettled: _onUsbAttachSettled,
          );
  }

  bool _shouldAttemptAttachReconnect() {
    if (_shuttingDown) return false;
    if (_machineConnected && !_automaticMachineAttemptSuperseded) return false;
    if (_attachProbe != null) return true;
    final preferredMachineId = settingsController.preferredMachineId;
    return preferredMachineId != null && preferredMachineId.isNotEmpty;
  }

  UsbAttachProbe? get _attachProbe =>
      deviceScanner is UsbAttachProbe ? deviceScanner as UsbAttachProbe : null;

  bool _pendingAttachAttempt = false;
  DeviceAttachedEvent? _pendingAttachEvent;
  bool _attachProbeInFlight = false;

  void _onUsbAttachLatched() {
    _usbAttachLatched = true;
    // Preserve an already-recorded replay obligation: a second attach may
    // latch while the first attach's probe is in flight, when the ambient
    // automatic state is false, and must not clear the interrupted
    // automatic attempt's right to resume.
    _resumeAutomaticAfterUsbAttach =
        _resumeAutomaticAfterUsbAttach ||
        _machineRecoveryActive ||
        _machineReconnect != null ||
        _activeAutomaticMachineAttempt;
    if (_machineReconnect != null) {
      _machineReconnect?.cancel();
      _machineReconnect = null;
      if (_machineReconnectFailures > 0) {
        // A pending timer already counted its backoff tier; no attempt ran,
        // so undo the tier so the rescheduled attempt keeps the same delay.
        _machineReconnectFailures--;
      }
    }
    if (_activeAutomaticMachineAttempt) {
      _automaticMachineAttemptSuperseded = true;
      _explicitScanGeneration++;
      deviceScanner.stopScan();
    }
  }

  void _onUsbAttachSettled() {
    unawaited(_completeUsbAttachLifecycle());
  }

  Future<void> _completeUsbAttachLifecycle() async {
    if (_pendingAttachAttempt) return;
    _usbAttachLatched = false;
    _automaticMachineAttemptSuperseded = false;
    if (_machineConnected) {
      _resumeAutomaticAfterUsbAttach = false;
      return;
    }
    if (_machineRecoveryActive) {
      // Recovery may have been armed during the probe (e.g. a failed attach
      // machine) while scheduling was gated by the latch, or suspended at
      // latch time; either way the timer must be (re)armed now that the
      // latch gate is gone.
      _resumeAutomaticAfterUsbAttach = false;
      _maybeScheduleMachineReconnect();
      return;
    }
    if (!_resumeAutomaticAfterUsbAttach) return;
    _resumeAutomaticAfterUsbAttach = false;
    _log.info(
      'USB attach resolved without adoption; resuming automatic '
      'machine selection',
    );
    await _attemptAutomaticConnect();
  }

  Future<bool> _releaseSupersededAutomaticMachine() async {
    if (!_automaticMachineAttemptSuperseded) return false;
    _automaticMachineAttemptSuperseded = false;
    if (!_machineConnected) return false;
    _log.info(
      'USB attach superseded automatic machine connect; releasing '
      '${_disconnectSupervisor.latestMachine?.deviceId}',
    );
    await disconnectMachine();
    return true;
  }

  Future<bool> _attemptAttachReconnect(DeviceAttachedEvent event) async {
    if (_shuttingDown) return true;
    if (_machineConnected && !_automaticMachineAttemptSuperseded) return true;
    if (_attachProbe == null) {
      _completeUsbAttachLifecycle();
      return _attemptAutomaticConnect();
    }
    if (_isConnecting) {
      _pendingAttachEvent = event;
      _pendingAttachAttempt = true;
      final intent = currentStatus.intent;
      if (intent == ConnectionIntent.automatic ||
          intent == ConnectionIntent.adapterRecovery) {
        _explicitScanGeneration++;
        deviceScanner.stopScan();
      }
      return true;
    }
    final handled = await _runConnect(
      scaleOnly: false,
      policy: ConnectionAttemptPolicy.automatic,
      attachEvent: event,
    );
    if (!handled && settingsController.preferredMachineId != null) {
      _resumeAutomaticAfterUsbAttach = false;
      unawaited(_completeUsbAttachLifecycle());
      return _attemptAutomaticConnect();
    }
    // Do not await the resume replay here: the coordinator releases its
    // in-flight guard when this attempt returns, so a second USB attach
    // during the resumed scan must be able to latch again.
    unawaited(_completeUsbAttachLifecycle());
    return true;
  }

  Future<bool> _attemptAutomaticConnect() async {
    _machineReconnect?.cancel();
    _machineReconnect = null;
    _machineReconnectFailures = 0;
    try {
      await connect();
    } catch (e, st) {
      _log.fine('Attach-triggered connect failed', e, st);
    }
    return _machineConnected;
  }

  Future<bool> _executeAttachProbe(DeviceAttachedEvent event) async {
    if (_machineConnected) return true;
    _isConnecting = true;
    _attachProbeInFlight = true;
    try {
      final probe = _attachProbe;
      if (probe == null) return false;
      final AttachProbeResult result;
      try {
        result = await probe.connectAttachedMachine(event);
      } catch (e, st) {
        // An exceptional probe must not leave the latch set forever: treat
        // it as unavailable so the fallback path completes the lifecycle
        // and recovery/replay scheduling stays ungated.
        _log.warning('Attach probe raised an exception', e, st);
        return false;
      }
      switch (result) {
        case AttachProbeConnected(machine: final machine):
          _log.info(
            'Attach probe: machine ${machine.name} (${machine.deviceId}) '
            'connected, adopting',
          );
          try {
            await _adoptAttachedMachine(machine);
          } catch (e, st) {
            // A failed adoption (e.g. preference persistence) must not
            // leave the latch set forever; fall back like an unavailable
            // probe so the lifecycle completes.
            _log.warning('Adopting the attached machine failed', e, st);
            return false;
          }
          return true;
        case AttachProbeUnsupported():
          _log.fine(
            'Attach probe: no supported machine on the attached device',
          );
          return true;
        case AttachProbeUnavailable():
          return false;
        case AttachProbeFailed(deviceId: final id, deviceName: final name):
          if (settingsController.preferredMachineId != null) {
            _log.info(
              'Attach probe: attached machine ${name ?? id} failed to '
              'connect; returning to preferred-machine recovery',
            );
            _ensureMachineRecoveryArmed();
            return true;
          }
          _log.info(
            'Attach probe: attached machine ${name ?? id} failed to connect',
          );
          _emit(
            ConnectionError(
              kind: ConnectionErrorKind.machineConnectFailed,
              severity: ConnectionErrorSeverity.error,
              timestamp: DateTime.now().toUtc(),
              deviceId: id,
              deviceName: name,
              message:
                  'Attached machine ${name ?? id ?? 'device'} failed to '
                  'connect.',
              suggestion:
                  'Make sure the machine is powered on and the USB '
                  'cable is seated, then try again.',
            ),
          );
          return true;
      }
    } finally {
      _attachProbeInFlight = false;
      _isConnecting = false;
    }
  }

  Future<void> _adoptAttachedMachine(De1Interface machine) async {
    _publishStatus(
      currentStatus.copyWith(
        phase: ConnectionPhase.connectingMachine,
        activeTargetTransport: () => machine.transportType,
      ),
    );
    de1Controller.adoptDevice(machine);
    await de1Controller.de1.firstWhere(
      (connected) => connected == machine,
      orElse: () => machine,
    );
    await settingsController.setPreferredMachineId(machine.deviceId);
    _log.info('Attach probe: machine adopted (${machine.deviceId})');
    if (machine is BengleInterface) {
      await _attachBengleVirtualScale(machine);
    } else if (!_scaleConnected) {
      if (settingsController.preferredScaleId != null) {
        _ensureScaleReacquisition();
      } else {
        _armPostQuickConnectScaleScan();
      }
    }
    _publishStatus(currentStatus.copyWith(phase: ConnectionPhase.ready));
  }

  void _ensureMachineRecoveryArmed() {
    if (_shuttingDown) return;
    if (!_shouldAttemptAttachReconnect()) return;
    if (!_machineRecoveryActive) {
      _machineRecoveryActive = true;
    }
    _maybeScheduleMachineReconnect();
  }

  void _listenForAdapter() {
    _adapterSub = deviceScanner.adapterStateStream.listen((state) {
      if (_shuttingDown) return;
      if (state == _lastAdapterState) return;
      final previous = _lastAdapterState;
      _lastAdapterState = state;
      if (state == AdapterState.poweredOn) {
        if (_adapterRecoveryNeeded) {
          final epoch = _adapterRecoveryEpoch;
          _adapterRecoveryTimer?.cancel();
          _adapterRecoveryTimer = Timer(adapterRecoveryDebounce, () {
            if (epoch != _adapterRecoveryEpoch ||
                !_adapterRecoveryNeeded ||
                _lastAdapterState != AdapterState.poweredOn) {
              return;
            }
            _adapterRecoveryNeeded = false;
            _queueAdapterRecovery();
          });
        }
      } else {
        _adapterRecoveryEpoch++;
        _adapterRecoveryNeeded = true;
        _adapterRecoveryTimer?.cancel();
        _adapterRecoveryTimer = null;
        if (previous == AdapterState.poweredOn) {
          deviceScanner.stopScan();
        }
      }
      if (state == AdapterState.poweredOff) {
        final error = ConnectionError(
          kind: ConnectionErrorKind.adapterOff,
          severity: ConnectionErrorSeverity.error,
          timestamp: DateTime.now().toUtc(),
          message: 'Bluetooth is turned off.',
          suggestion: 'Turn Bluetooth on to scan for Bluetooth devices.',
        );
        _setTransportCondition(error);
        _emit(error);
      } else if (state == AdapterState.unauthorized) {
        final error = ConnectionError(
          kind: ConnectionErrorKind.bluetoothPermissionDenied,
          severity: ConnectionErrorSeverity.error,
          timestamp: DateTime.now().toUtc(),
          message: 'Bluetooth permission was denied.',
          suggestion:
              'Go to Settings > Privacy & Security > Bluetooth and enable '
              'permission for Decaid.',
        );
        _setTransportCondition(error);
        _emit(error);
      } else if (state == AdapterState.poweredOn) {
        _clearTransportCondition(TransportType.ble);

        if (currentStatus.error?.kind == ConnectionErrorKind.adapterOff ||
            currentStatus.error?.kind ==
                ConnectionErrorKind.bluetoothPermissionDenied) {
          _clearError();
        }
      }
    });
  }

  void _setTransportCondition(ConnectionError error) {
    final condition = TransportCondition(
      transportType: TransportType.ble,
      affectedDeviceTypes: const {DeviceType.machine, DeviceType.scale},
      connectionError: error,
    );
    _publishStatus(
      currentStatus.copyWith(
        conditions: [
          ...currentStatus.conditions.where(
            (existing) => existing.transportType != TransportType.ble,
          ),
          condition,
        ],
      ),
    );
  }

  void _clearTransportCondition(TransportType transportType) {
    _publishStatus(
      currentStatus.copyWith(
        conditions: currentStatus.conditions
            .where((condition) => condition.transportType != transportType)
            .toList(),
      ),
    );
  }

  void _emit(ConnectionError err) => _statusPublisher.emitError(err);

  void reportError(ConnectionError err) => _emit(err);

  void clearErrorOfKind(String kind) {
    if (currentStatus.error?.kind == kind) {
      _clearError();
    }
  }

  ConnectionError _buildConnectError({
    required String kind,
    required String deviceId,
    required String deviceName,
    required String message,
    String? suggestion,
    required Object exception,
  }) {
    Map<String, dynamic>? details;
    if (exception is BleConnectException) {
      final map = <String, dynamic>{
        if (exception.code != null) 'ble_code': exception.code,
        if (exception.description != null)
          'ble_description': exception.description,
        if (exception.function != null) 'ble_function': exception.function,
      };
      details = map.isEmpty ? null : map;
    } else {
      details = {'exception': exception.toString()};
    }
    return ConnectionError(
      kind: kind,
      severity: ConnectionErrorSeverity.error,
      timestamp: DateTime.now().toUtc(),
      deviceId: deviceId,
      deviceName: deviceName,
      message: message,
      suggestion: suggestion,
      details: details,
    );
  }

  void _clearError() => _statusPublisher.clearError();

  void _publishStatus(ConnectionStatus next) => _statusPublisher.publish(next);

  @visibleForTesting
  void debugEmitError({
    required String kind,
    required String severity,
    required String message,
    String? deviceId,
    String? deviceName,
    String? suggestion,
    Map<String, dynamic>? details,
    DateTime? timestamp,
  }) {
    _emit(
      ConnectionError(
        kind: kind,
        severity: severity,
        timestamp: (timestamp ?? DateTime.now()).toUtc(),
        message: message,
        deviceId: deviceId,
        deviceName: deviceName,
        suggestion: suggestion,
        details: details,
      ),
    );
  }

  @visibleForTesting
  void debugSetPhase(ConnectionPhase phase) {
    _statusPublisher.publish(currentStatus.copyWith(phase: phase));
  }

  void markExpectingDisconnect(String deviceId) {
    _disconnectExpectations.mark(deviceId);
  }

  @visibleForTesting
  void debugNotifyScaleDisconnected(String deviceId) =>
      _disconnectSupervisor.notifyScaleDisconnected(deviceId);

  @visibleForTesting
  void debugNotifyMachineDisconnected(String deviceId) =>
      _disconnectSupervisor.notifyMachineDisconnected(deviceId);

  Future<void> connect({bool scaleOnly = false}) => _runConnect(
    scaleOnly: scaleOnly,
    policy: scaleOnly
        ? ConnectionAttemptPolicy.scaleRecovery
        : ConnectionAttemptPolicy.automatic,
  );

  Future<void> scanAndConnect() async {
    if (_shuttingDown) return;
    if (_queuedExplicitScan != null) {
      return _queuedExplicitScan!.future;
    }
    if (_isConnecting) {
      _explicitScanGeneration++;
      deviceScanner.stopScan();
      _queuedExplicitScan = Completer<void>();
      return _queuedExplicitScan!.future;
    }
    _explicitScanGeneration++;
    await _runConnect(
      scaleOnly: false,
      policy: ConnectionAttemptPolicy.explicitScan,
    );
  }

  Future<bool> _runConnect({
    required bool scaleOnly,
    required ConnectionAttemptPolicy policy,
    bool adapterRecovery = false,
    DeviceAttachedEvent? attachEvent,
  }) {
    if (_shuttingDown) return Future.value(false);
    return _trackConnectionWork(
      () => _runConnectImpl(
        scaleOnly: scaleOnly,
        policy: policy,
        adapterRecovery: adapterRecovery,
        attachEvent: attachEvent,
      ),
    );
  }

  Future<T> _trackConnectionWork<T>(Future<T> Function() work) async {
    _activeConnectionWork++;
    final workDone = _connectionWorkDone ??= Completer<void>();
    try {
      return await work();
    } finally {
      _activeConnectionWork--;
      if (_activeConnectionWork == 0) {
        _connectionWorkDone = null;
        workDone.complete();
      }
    }
  }

  Future<bool> _runConnectImpl({
    required bool scaleOnly,
    required ConnectionAttemptPolicy policy,
    bool adapterRecovery = false,
    DeviceAttachedEvent? attachEvent,
  }) async {
    if (_isConnecting) {
      if (adapterRecovery) return true;
      if (scaleOnly) {
        final completer = _queuedScaleOnly ??= Completer<void>();
        return completer.future.then((_) => true);
      }
      return true;
    }

    try {
      if (adapterRecovery) {
        _adapterRecoveryQueued = false;
        await _executeAdapterRecovery();
      } else if (attachEvent != null) {
        return await _executeAttachProbe(attachEvent);
      } else {
        await _executeConnect(scaleOnly, policy: policy);
      }
    } finally {
      while (!_shuttingDown &&
          (_pendingAttachAttempt ||
              _queuedExplicitScan != null ||
              _adapterRecoveryQueued ||
              _queuedScaleOnly != null)) {
        if (_pendingAttachAttempt) {
          _pendingAttachAttempt = false;
          final event = _pendingAttachEvent;
          _pendingAttachEvent = null;
          if (event != null && !_machineConnected) {
            final handled = await _executeAttachProbe(event);
            if (!handled && settingsController.preferredMachineId != null) {
              _resumeAutomaticAfterUsbAttach = false;
              await _completeUsbAttachLifecycle();
              await _attemptAutomaticConnect();
            } else {
              await _completeUsbAttachLifecycle();
            }
          } else {
            await _completeUsbAttachLifecycle();
          }
          continue;
        }

        if (_queuedExplicitScan != null) {
          final drain = _queuedExplicitScan!;
          _queuedExplicitScan = null;
          try {
            await _executeConnect(
              false,
              policy: ConnectionAttemptPolicy.explicitScan,
            );
            drain.complete();
          } catch (e, st) {
            drain.completeError(e, st);
          }
          continue;
        }

        if (_adapterRecoveryQueued) {
          _adapterRecoveryQueued = false;
          await _executeAdapterRecovery();
          continue;
        }

        final drain = _queuedScaleOnly!;
        _queuedScaleOnly = null;
        try {
          await _executeConnect(
            true,
            policy: ConnectionAttemptPolicy.scaleRecovery,
          );
          drain.complete();
        } catch (e, st) {
          drain.completeError(e, st);
        }
      }
    }
    return true;
  }

  Future<void> _executeConnect(
    bool scaleOnly, {
    required ConnectionAttemptPolicy policy,
    ConnectionIntent? intent,
  }) async {
    final resolvedIntent =
        intent ??
        (identical(policy, ConnectionAttemptPolicy.explicitScan)
            ? ConnectionIntent.explicitDiscovery
            : identical(policy, ConnectionAttemptPolicy.scaleRecovery)
            ? ConnectionIntent.scaleRecovery
            : ConnectionIntent.automatic);
    final isAutomaticMachineAttempt =
        !scaleOnly &&
        (resolvedIntent == ConnectionIntent.automatic ||
            resolvedIntent == ConnectionIntent.adapterRecovery);
    if (isAutomaticMachineAttempt && _usbAttachLatched) {
      _resumeAutomaticAfterUsbAttach = true;
      _log.fine('USB attach latched; deferring automatic machine connect');
      return;
    }
    _isConnecting = true;
    _publishStatus(
      currentStatus.copyWith(
        intent: resolvedIntent,
        activeTargetTransport: () => null,
      ),
    );
    if (scaleOnly) {
      _activeScaleOnlyScan = true;
    }
    try {
      await _connectImpl(scaleOnly: scaleOnly, policy: policy);
    } finally {
      if (scaleOnly) {
        _activeScaleOnlyScan = false;
      }
      _isConnecting = false;
      if (_automaticMachineAttemptSuperseded && !_machineConnected) {
        _automaticMachineAttemptSuperseded = false;
      }
    }
  }

  void _queueAdapterRecovery() {
    if (_shuttingDown) return;
    if (_adapterRecoveryQueued) return;
    _adapterRecoveryQueued = true;
    if (_isConnecting) return;
    unawaited(
      _runConnect(
        scaleOnly: false,
        policy: ConnectionAttemptPolicy.automatic,
        adapterRecovery: true,
      ),
    );
  }

  Future<void> _executeAdapterRecovery() async {
    final preferredMachine = settingsController.preferredMachineId;
    final preferredScale = settingsController.preferredScaleId;
    if (preferredMachine != null &&
        preferredMachine.isNotEmpty &&
        !_machineConnected) {
      await _executeConnect(
        false,
        policy: ConnectionAttemptPolicy.automatic,
        intent: ConnectionIntent.adapterRecovery,
      );
      return;
    }
    if (_machineConnected &&
        preferredScale != null &&
        preferredScale.isNotEmpty &&
        !_scaleConnected) {
      await _executeConnect(
        true,
        policy: ConnectionAttemptPolicy.scaleRecovery,
        intent: ConnectionIntent.adapterRecovery,
      );
    }
  }

  Future<De1Interface?> _tryQuickConnectMachine() async {
    final registry = rememberedDevices;
    if (registry == null) return null;
    final machineId = settingsController.preferredMachineId;
    if (machineId == null || machineId.isEmpty) return null;
    final remembered = registry.remembered.firstWhereOrNull(
      (d) => d.id == machineId,
    );
    if (remembered == null) return null;
    try {
      final device = await deviceScanner.tryQuickConnect(remembered);
      if (device is De1Interface) {
        de1Controller.adoptDevice(device);
        _log.info('Quick-connect: machine adopted (${device.deviceId})');
        return device;
      }
    } catch (e, st) {
      _log.warning('Quick-connect: machine attempt failed', e, st);
    }
    return null;
  }

  Future<void> _connectImpl({
    required bool scaleOnly,
    required ConnectionAttemptPolicy policy,
  }) async {
    _cancelScaleReacquisition(resetFailures: !scaleOnly);
    if (scaleOnly && _scaleReconnectBlockedByPowerMode) {
      _log.fine(
        'Skipping scale-only scan while machine is sleeping and scale '
        'power mode is disconnect',
      );
      return;
    }
    if (scaleOnly &&
        _selectionSession?.isActive == true &&
        currentStatus.pendingAmbiguity != null) {
      _log.fine('Skipping scale recovery while device selection is pending');
      return;
    }
    if (!scaleOnly) {
      _deferredScaleScan?.cancel();
      _deferredScaleScan = null;
      _earlyStopFired = false;
      _cancelSelectionSession(emitReport: true);
    }

    if (policy.directRememberedMachine &&
        !scaleOnly &&
        !_machineConnected &&
        rememberedDevices != null) {
      _publishStatus(
        currentStatus.copyWith(phase: ConnectionPhase.connectingMachine),
      );
      final qcMachine = await _tryQuickConnectMachine();
      if (qcMachine != null) {
        if (await _releaseSupersededAutomaticMachine()) return;
        _log.info('Quick-connect: machine connected, proceeding to ready');
        if (qcMachine is BengleInterface) {
          await _attachBengleVirtualScale(qcMachine);
        } else if (!_scaleConnected) {
          if (settingsController.preferredScaleId != null) {
            _ensureScaleReacquisition();
          } else {
            _armPostQuickConnectScaleScan();
          }
        }
        _publishStatus(currentStatus.copyWith(phase: ConnectionPhase.ready));
        return;
      }
      // Quick-connect missed. If USB intent latched while it was pending,
      // defer the automatic scan to the latch lifecycle instead of
      // starting a fresh scan that the queued attach probe would wait
      // behind (the latch's stopScan already ran before this scan existed).
      if (_usbAttachLatched) {
        _resumeAutomaticAfterUsbAttach = true;
        _log.fine(
          'USB attach latched during quick-connect; deferring automatic '
          'scan',
        );
        return;
      }
    }

    final preferredMachineId = scaleOnly
        ? null
        : settingsController.preferredMachineId;
    final preferredScaleId = settingsController.preferredScaleId;
    final earlyStopEnabled = !scaleOnly && policy.stopScanAfterPreferredConnect;

    final scanStartTime = DateTime.now();

    final scaleFilter = scaleOnly && Platform.isAndroid
        ? ScanFilter(
            preferredDeviceId: preferredScaleId,
            deviceTypes: {DeviceType.scale},
          )
        : null;

    final scanGen = _explicitScanGeneration;

    final scanRun = await _scanOrchestrator.runScan(
      preferredMachineId: policy.connectPreferredDuringScan
          ? preferredMachineId
          : null,
      preferredScaleId: policy.connectPreferredDuringScan
          ? preferredScaleId
          : null,
      earlyStopEnabled: earlyStopEnabled,
      onEarlyAttemptComplete: () => _checkEarlyStop(earlyStopEnabled),
      scanStartTime: scanStartTime,
      scaleFilter: scaleFilter,
    );
    if (scanRun == null) {
      return;
    }

    if (_explicitScanGeneration != scanGen) {
      _scanReportSubject.add(
        scanRun.reportBuilder.build(
          preferredMachineId: preferredMachineId,
          preferredScaleId: preferredScaleId,
          terminationReason: ScanTerminationReason.cancelledByUser,
          adapterStateAtEnd: deviceScanner.currentAdapterState,
        ),
      );
      _publishStatus(
        currentStatus.copyWith(
          pendingAmbiguity: () => null,
          phase: _machineConnected
              ? ConnectionPhase.ready
              : ConnectionPhase.idle,
        ),
      );
      _ensureScaleReacquisition();
      return;
    }

    final machines = scanRun.machines;
    final scales = scanRun.scales;
    final scanReport = scanRun.reportBuilder;
    final selectionSession = ConnectionSelectionSession(
      machines: machines,
      scales: scales,
      preferredMachineId: preferredMachineId,
      preferredScaleId: preferredScaleId,
      scanReport: scanReport,
    );
    _selectionSession = selectionSession;

    if (scaleOnly) {
      _publishStatus(currentStatus.copyWith(foundScales: scales));
      await _runScalePhase(
        _disconnectSupervisor.latestMachine,
        scales,
        preferredScaleId,
        scanReport,
      );
      if (currentStatus.phase == ConnectionPhase.scanning) {
        _publishStatus(
          currentStatus.copyWith(
            phase: _machineConnected
                ? ConnectionPhase.ready
                : ConnectionPhase.idle,
          ),
        );
      }
      _completeSelectionSessionIfResolved(selectionSession);
      _ensureScaleReacquisition();
      return;
    }

    _publishStatus(
      currentStatus.copyWith(foundMachines: machines, foundScales: scales),
    );

    if (_machineConnected) {
      _log.fine('Machine connected, proceeding to scale phase');
      await _runScalePhase(
        _disconnectSupervisor.latestMachine,
        scales,
        preferredScaleId,
        scanReport,
      );
      _settleAfterScalePhase();
      _maybeArmDeferredScaleScan();
      _ensureScaleReacquisition();
      _completeSelectionSessionIfResolved(selectionSession);
      return;
    }

    final policyMachines =
        policy.connectPreferredDuringScan && preferredMachineId != null
        ? machines
              .where((machine) => machine.deviceId != preferredMachineId)
              .toList()
        : machines;
    final machineAction = resolveMachinePolicy(
      machines: policyMachines,
      preferredMachineId: preferredMachineId,
    );
    switch (machineAction) {
      case ConnectMachineAction(machine: final m):
        if (await _connectMachineTracked(m, scanReport)) return;
        final alternatives = machines.where((machine) => machine != m).toList();
        if (!_machineConnected && alternatives.isNotEmpty) {
          _publishStatus(
            currentStatus.copyWith(
              phase: ConnectionPhase.idle,
              pendingAmbiguity: () => AmbiguityReason.machinePicker,
            ),
          );
        } else {
          final machineError = !_machineConnected ? currentStatus.error : null;
          await _runScalePhase(
            _disconnectSupervisor.latestMachine,
            scales,
            preferredScaleId,
            scanReport,
          );
          _settleAfterScalePhase();
          _maybeArmDeferredScaleScan();
          _ensureScaleReacquisition();
          if (machineError != null) _emit(machineError);
        }
      case MachinePickerAction():
        _publishStatus(
          currentStatus.copyWith(
            phase: ConnectionPhase.idle,
            pendingAmbiguity: () => AmbiguityReason.machinePicker,
          ),
        );
      case NoMachineAction():
        await _runScalePhase(null, scales, preferredScaleId, scanReport);
        _settleAfterScalePhase();
        _ensureScaleReacquisition();
    }

    _completeSelectionSessionIfResolved(selectionSession);
  }

  void _checkEarlyStop(bool earlyStopEnabled) {
    if (!earlyStopEnabled) return;
    if (_earlyStopFired) return;
    final preferredMachineId = settingsController.preferredMachineId;
    final preferredScaleId = settingsController.preferredScaleId;
    if (preferredMachineId != null && preferredScaleId != null) {
      if (_machineConnected && _scaleConnected) {
        _log.fine('Both preferred devices connected, stopping scan early');
        _earlyStopFired = true;
        deviceScanner.stopScan();
      }
    } else if (preferredMachineId != null) {
      if (_machineConnected) {
        _log.fine(
          'Preferred machine connected (no preferred scale), '
          'stopping scan early',
        );
        _earlyStopFired = true;
        deviceScanner.stopScan();
      }
    } else if (preferredScaleId != null) {
      if (_machineConnected && _scaleConnected) {
        _log.fine(
          'Preferred scale connected (auto machine), stopping scan early',
        );
        _earlyStopFired = true;
        deviceScanner.stopScan();
      }
    } else {
      if (_machineConnected && _scaleConnected) {
        _log.fine(
          'Machine and scale connected (no preferences), stopping scan early',
        );
        _earlyStopFired = true;
        deviceScanner.stopScan();
      }
    }
  }

  void _armPostQuickConnectScaleScan() {
    if (_shuttingDown) return;
    if (_scaleConnected) return;
    if (_scaleReconnectBlockedByPowerMode) return;
    _log.fine(
      'Quick-connected machine without a scale; '
      'arming deferred scale scan in ${deferredScaleScanDelay.inSeconds}s',
    );
    _deferredScaleScan?.cancel();
    _deferredScaleScan = Timer(deferredScaleScanDelay, () {
      _deferredScaleScan = null;
      if (_scaleConnected) return;
      if (!_machineConnected || _scaleReconnectBlockedByPowerMode) return;
      connect(scaleOnly: true);
    });
  }

  void _maybeArmDeferredScaleScan() {
    if (_shuttingDown) return;
    if (!_earlyStopFired) return;
    if (!_machineConnected || _scaleConnected) return;
    if (_scaleReconnectBlockedByPowerMode) return;
    _log.fine(
      'Machine connected without a scale after an early stop; '
      'arming deferred scale rescan in ${deferredScaleScanDelay.inSeconds}s',
    );
    _deferredScaleScan?.cancel();
    _deferredScaleScan = Timer(deferredScaleScanDelay, () {
      _deferredScaleScan = null;
      if (_scaleConnected) return;
      if (!_machineConnected || _scaleReconnectBlockedByPowerMode) return;
      connect(scaleOnly: true);
    });
  }

  void _ensureScaleReacquisition() {
    if (_shuttingDown) return;
    if (deviceScanner.supportsBackgroundWatch) {
      unawaited(_scaleWatch.arm());
    } else {
      _maybeSchedulePreferredScaleReconnect();
    }
  }

  void _cancelScaleReacquisition({bool resetFailures = true}) {
    unawaited(_scaleWatch.disarm());
    _cancelPreferredScaleReconnect(resetFailures: resetFailures);
  }

  Future<void> _connectScaleFromWatch(Scale scale) async {
    if (_disconnectSupervisor.latestMachine is BengleInterface) {
      _log.fine(
        'Ignoring watch scale sighting ${scale.deviceId}: '
        'Bengle integrated scale owns the slot',
      );
      return;
    }
    await connectScale(scale);
  }

  void _maybeSchedulePreferredScaleReconnect() {
    if (_preferredScaleReconnect != null) return;
    if (!_shouldRetryPreferredScale()) return;
    final delay = _scaleReconnectBackoff;
    _scaleReconnectFailures++;
    _log.fine(
      'Preferred scale is missing (failure #$_scaleReconnectFailures); '
      'retrying scale scan in ${delay.inSeconds}s',
    );
    _preferredScaleReconnect = Timer(delay, () {
      _preferredScaleReconnect = null;
      if (!_shouldRetryPreferredScale()) return;
      connect(scaleOnly: true);
    });
  }

  bool _shouldRetryPreferredScale() {
    return !_shuttingDown &&
        _machineConnected &&
        !_scaleConnected &&
        currentStatus.pendingAmbiguity != AmbiguityReason.scalePicker &&
        settingsController.preferredScaleId != null &&
        !_scaleReconnectBlockedByPowerMode;
  }

  void _cancelPreferredScaleReconnect({bool resetFailures = true}) {
    _preferredScaleReconnect?.cancel();
    _preferredScaleReconnect = null;
    if (resetFailures) _scaleReconnectFailures = 0;
  }

  void _handleScaleDisconnected() {
    _cancelSelectionSession(emitReport: true);
    _ensureScaleReacquisition();
  }

  void _handleMachineConnected() {
    if (_shuttingDown) return;
    _stopMachineRecovery();
    _watchConnectedMachineState();
    _ensureScaleReacquisition();
  }

  void _handleMachineDisconnected() {
    _cancelSelectionSession(emitReport: true);
    _stopMachineRecovery();
    _stopWatchingConnectedMachineState();
    _deferredScaleScan?.cancel();
    _deferredScaleScan = null;
    _cancelScaleReacquisition();
    if (_activeScaleOnlyScan) {
      deviceScanner.stopScan();
    }
  }

  void _startMachineRecovery() {
    if (_shuttingDown) return;
    if (settingsController.preferredMachineId == null) return;
    _machineRecoveryActive = true;
    _log.info(
      'Machine disconnected unexpectedly — starting auto-reconnect scans',
    );
    _maybeScheduleMachineReconnect();
  }

  void _stopMachineRecovery() {
    _machineRecoveryActive = false;
    _machineReconnect?.cancel();
    _machineReconnect = null;
    _machineReconnectFailures = 0;
  }

  @visibleForTesting
  bool get machineRecoveryActive => _machineRecoveryActive;

  @visibleForTesting
  int get machineReconnectFailures => _machineReconnectFailures;

  bool _shouldRetryMachine() {
    return !_shuttingDown &&
        _machineRecoveryActive &&
        !_machineConnected &&
        settingsController.preferredMachineId != null;
  }

  void _maybeScheduleMachineReconnect() {
    if (_usbAttachLatched) return;
    if (_machineReconnect != null) return;
    if (!_shouldRetryMachine()) return;
    final delay = _machineReconnectBackoff;
    _machineReconnectFailures++;
    _log.fine(
      'Machine is missing (attempt #$_machineReconnectFailures); '
      'retrying full scan in ${delay.inSeconds}s',
    );
    _machineReconnect = Timer(delay, () async {
      _machineReconnect = null;
      if (!_shouldRetryMachine()) return;
      try {
        await connect();
      } catch (e, st) {
        _log.fine('Machine reconnect attempt failed', e, st);
      }
      _maybeScheduleMachineReconnect();
    });
  }

  void _watchConnectedMachineState() {
    _stopWatchingConnectedMachineState();
    final machine = _disconnectSupervisor.latestMachine;
    if (machine == null) return;
    final Stream<MachineSnapshot> snapshots;
    try {
      snapshots = machine.currentSnapshot;
    } catch (e, st) {
      _log.fine('Machine snapshot stream unavailable', e, st);
      return;
    }
    _armStateWatchdog(machine.deviceId);
    _machineSnapshotSub = snapshots.listen(
      (snapshot) {
        _armStateWatchdog(machine.deviceId);
        final state = snapshot.state.state;
        if (_latestMachineState == state) return;
        _latestMachineState = state;
        if (_scaleReconnectBlockedByPowerMode) {
          _log.fine(
            'Machine is sleeping and scale power mode is disconnect; '
            'pausing preferred scale reconnect',
          );
          _pauseScaleReconnectForPowerMode();
        } else {
          _ensureScaleReacquisition();
        }
      },
      onError: (Object e, StackTrace st) {
        _log.fine('Machine snapshot stream error', e, st);
      },
    );
  }

  void _armStateWatchdog(String deviceId) {
    final gen = _watchdogGeneration;
    _stateWatchdog?.cancel();
    _stateWatchdog = Timer(snapshotStalenessTimeout, () {
      if (gen != _watchdogGeneration) return;
      if (!_machineConnected) return;
      final current = _disconnectSupervisor.latestMachine;
      if (current?.deviceId != deviceId) return;
      _log.warning(
        'Snapshot stream stale for $deviceId after '
        '${snapshotStalenessTimeout.inSeconds}s with link still '
        '"connected"; forcing a clean machine reconnect',
      );
      unawaited(_trackConnectionWork(_forceMachineReconnect));
    });
  }

  Future<void> _forceMachineReconnect() async {
    snapshotStalenessReconnects++;
    _watchdogGeneration++;
    _stateWatchdog?.cancel();
    _stateWatchdog = null;
    try {
      await disconnectMachine();
      await connect();
    } catch (e, st) {
      _log.fine('Forced machine reconnect failed', e, st);
    } finally {
      if (!_machineConnected) {
        _startMachineRecovery();
      }
    }
  }

  void _pauseScaleReconnectForPowerMode() {
    _deferredScaleScan?.cancel();
    _deferredScaleScan = null;
    _cancelScaleReacquisition();
    if (_activeScaleOnlyScan) {
      deviceScanner.stopScan();
    }
  }

  void _stopWatchingConnectedMachineState() {
    _watchdogGeneration++;
    _stateWatchdog?.cancel();
    _stateWatchdog = null;
    _machineSnapshotSub?.cancel();
    _machineSnapshotSub = null;
    _latestMachineState = null;
  }

  void _settleAfterScalePhase() {
    final phase = _machineConnected
        ? ConnectionPhase.ready
        : ConnectionPhase.idle;
    if (currentStatus.phase != phase) {
      _publishStatus(currentStatus.copyWith(phase: phase));
    }
  }

  Future<void> _runScalePhase(
    De1Interface? machine,
    List<Scale> scales,
    String? preferredScaleId,
    ScanReportBuilder scanReport,
  ) async {
    if (machine is BengleInterface) {
      await _attachBengleVirtualScale(machine);
      return;
    }
    await _applyScalePolicy(scales, preferredScaleId, scanReport);
  }

  Future<void> _attachBengleVirtualScale(BengleInterface machine) async {
    final virtual = BengleVirtualScale(machine);
    if (_scaleConnected &&
        scaleController.lastConnectedDeviceId == virtual.deviceId) {
      return;
    }
    try {
      await scaleController.connectToScale(virtual);
    } catch (e, st) {
      _log.warning('Failed to attach Bengle virtual scale', e, st);
    }
  }

  Future<void> _applyScalePolicy(
    List<Scale> scales,
    String? preferredScaleId,
    ScanReportBuilder scanReport,
  ) async {
    if (_scaleReconnectBlockedByPowerMode) {
      _log.fine(
        'Skipping scale phase while machine is sleeping and scale power '
        'mode is disconnect',
      );
      return;
    }
    if (_scaleConnected) {
      _log.fine('Scale already connected, skipping scale phase');
      return;
    }
    _log.fine(
      'Scale phase: ${scales.length} scales, preferredScaleId=$preferredScaleId',
    );
    final action = resolveScalePolicy(
      scales: scales,
      preferredScaleId: preferredScaleId,
    );
    switch (action) {
      case ConnectScaleAction(scale: final s):
        final result = await _connectScaleTracked(s, scanReport);
        final alternatives = scales.where((scale) => scale != s).toList();
        if (!result.success &&
            result.error != null &&
            alternatives.isNotEmpty) {
          _cancelScaleReacquisition();
          _publishStatus(
            currentStatus.copyWith(
              pendingAmbiguity: () => AmbiguityReason.scalePicker,
            ),
          );
        }
      case ScalePickerAction():
        _cancelScaleReacquisition();
        _publishStatus(
          currentStatus.copyWith(
            pendingAmbiguity: () => AmbiguityReason.scalePicker,
          ),
        );
      case NoScaleAction():
        break;
    }
  }

  Future<ConnectionResult> selectMachine(De1Interface machine) async {
    final session = _selectionSession;
    if (session == null ||
        currentStatus.pendingAmbiguity != AmbiguityReason.machinePicker) {
      _log.fine('Ignoring stale machine selection ${machine.deviceId}');
      return const ConnectionResult.conflict();
    }
    final resolved = session.resolveMachine(machine.deviceId);
    if (resolved == null) {
      _log.fine('Ignoring stale machine selection ${machine.deviceId}');
      return const ConnectionResult.conflict();
    }
    return connectMachine(resolved);
  }

  Future<ConnectionResult> connectMachine(
    De1Interface machine, {
    bool automatic = false,
  }) {
    if (_shuttingDown) {
      return Future.value(const ConnectionResult.conflict());
    }
    return _trackConnectionWork(
      () => _connectMachine(machine, automatic: automatic),
    );
  }

  Future<ConnectionResult> _connectMachine(
    De1Interface machine, {
    required bool automatic,
  }) async {
    // Only the passive automatic attempt may be superseded by USB attach
    // intent. Explicit direct connects (REST/WS) are never superseded, even
    // when they overlap an in-flight automatic scan.
    if (automatic && _usbAttachLatched && _activeAutomaticMachineAttempt) {
      _log.fine(
        'connectMachine: superseded by USB attach intent, skipping '
        '${machine.deviceId}',
      );
      return const ConnectionResult.conflict();
    }
    if (_isConnectingMachine) {
      _log.fine('connectMachine: already connecting, skipping');
      return const ConnectionResult.conflict();
    }
    if (_machineConnected &&
        de1Controller.connectedDe1OrNull?.deviceId == machine.deviceId) {
      return const ConnectionResult.alreadyConnected();
    }
    _isConnectingMachine = true;
    final selectionSession =
        currentStatus.pendingAmbiguity == AmbiguityReason.machinePicker
        ? _selectionSession
        : null;
    selectionSession?.scanReport.markAttempted(machine.deviceId);
    _log.fine(
      'connectMachine: connecting to ${machine.name} (${machine.deviceId})',
    );

    _publishStatus(
      currentStatus.copyWith(
        phase: ConnectionPhase.connectingMachine,
        activeTargetTransport: () => machine.transportType,
        pendingAmbiguity: () => null,
      ),
    );

    try {
      await _trackConnectionWork(
        () => de1Controller.connectToDe1(machine),
      ).timeout(_connectTimeout);
      if (automatic && _automaticMachineAttemptSuperseded) {
        // This connect was in flight when USB intent latched; it may still
        // have completed its transport connect, but it must not persist its
        // own preference. The release path disconnects it afterwards. Flush
        // the registration so the release sees the machine as connected
        // (the de1 subject delivers asynchronously).
        _log.fine(
          'connectMachine: connected but superseded by USB attach intent, '
          'not persisting preference for ${machine.deviceId}',
        );
        await de1Controller.de1.firstWhere(
          (connected) => connected == machine,
          orElse: () => machine,
        );
        return const ConnectionResult.conflict();
      }
      await settingsController.setPreferredMachineId(machine.deviceId);
      selectionSession?.scanReport.recordResult(
        machine.deviceId,
        const ConnectionResult.succeeded(),
      );
      if (selectionSession != null && selectionSession.isActive) {
        await _runScalePhase(
          machine,
          selectionSession.scales,
          selectionSession.preferredScaleId,
          selectionSession.scanReport,
        );
        _settleAfterScalePhase();
        _ensureScaleReacquisition();
        _completeSelectionSessionIfResolved(selectionSession);
      } else if (!_isConnecting) {
        _publishStatus(currentStatus.copyWith(phase: ConnectionPhase.ready));
      }
      return const ConnectionResult.succeeded();
    } catch (e) {
      final result = e is TimeoutException
          ? ConnectionResult.timedOut(e.toString())
          : ConnectionResult.failed(e.toString());
      selectionSession?.scanReport.recordResult(machine.deviceId, result);
      final machineError = _buildConnectError(
        kind: ConnectionErrorKind.machineConnectFailed,
        deviceId: machine.deviceId,
        deviceName: machine.name,
        message: e is TimeoutException
            ? 'Machine ${machine.name} did not respond within '
                  '${_connectTimeout.inSeconds}s.'
            : 'Machine ${machine.name} failed to connect.',
        suggestion: e is TimeoutException
            ? 'Try again. If the problem persists, power-cycle the machine.'
            : 'Make sure the DE1 is powered on and in range, then retry.',
        exception: e,
      );

      if (selectionSession == null || !selectionSession.isActive) {
        _publishStatus(
          currentStatus.copyWith(
            phase: ConnectionPhase.idle,
            pendingAmbiguity: () => null,
          ),
        );
        _emit(machineError);
        return result;
      }

      final alternatives = selectionSession.machines
          .where((m) => m.deviceId != machine.deviceId)
          .toList();
      if (alternatives.isNotEmpty) {
        _publishStatus(
          currentStatus.copyWith(
            phase: ConnectionPhase.idle,
            pendingAmbiguity: () => AmbiguityReason.machinePicker,
          ),
        );
        _emit(machineError);
        return result;
      }

      _publishStatus(
        currentStatus.copyWith(
          phase: ConnectionPhase.idle,
          pendingAmbiguity: () => null,
        ),
      );
      _emit(machineError);
      await _runScalePhase(
        null,
        selectionSession.scales,
        selectionSession.preferredScaleId,
        selectionSession.scanReport,
      );
      _settleAfterScalePhase();
      _ensureScaleReacquisition();
      _emit(machineError);
      return result;
    } finally {
      _isConnectingMachine = false;
    }
  }

  Future<ConnectionResult> connectScale(Scale scale) {
    if (_shuttingDown) {
      return Future.value(const ConnectionResult.conflict());
    }
    return _trackConnectionWork(() => _connectScale(scale));
  }

  Future<ConnectionResult> _connectScale(Scale scale) async {
    if (_isConnectingScale) {
      _log.fine('connectScale: already connecting, skipping');
      return const ConnectionResult.conflict();
    }
    if (_scaleConnected &&
        scaleController.lastConnectedDeviceId == scale.deviceId) {
      return const ConnectionResult.alreadyConnected();
    }
    if (_scaleReconnectBlockedByPowerMode) {
      _log.fine(
        'connectScale: blocked while machine is sleeping and scale power '
        'mode is disconnect',
      );
      return const ConnectionResult.conflict();
    }
    _isConnectingScale = true;
    _log.fine('connectScale: connecting to ${scale.name} (${scale.deviceId})');

    _publishStatus(
      currentStatus.copyWith(
        phase: ConnectionPhase.connectingScale,
        activeTargetTransport: () => scale.transportType,
        pendingAmbiguity: () => null,
      ),
    );

    try {
      await _trackConnectionWork(
        () => scaleController.connectToScale(scale),
      ).timeout(_connectTimeout);
      if (_scaleReconnectBlockedByPowerMode) {
        markExpectingDisconnect(scale.deviceId);
        _publishStatus(
          currentStatus.copyWith(
            phase: _machineConnected
                ? ConnectionPhase.ready
                : ConnectionPhase.idle,
          ),
        );
        await scale.disconnect();
        return const ConnectionResult.conflict();
      }
      await settingsController.setPreferredScaleId(scale.deviceId);
      _publishStatus(
        currentStatus.copyWith(
          phase: _machineConnected
              ? ConnectionPhase.ready
              : ConnectionPhase.idle,
        ),
      );
      return const ConnectionResult.succeeded();
    } catch (e) {
      _publishStatus(
        currentStatus.copyWith(
          phase: _machineConnected
              ? ConnectionPhase.ready
              : ConnectionPhase.idle,
        ),
      );
      final timedOut = e is TimeoutException;
      _emit(
        _buildConnectError(
          kind: ConnectionErrorKind.scaleConnectFailed,
          deviceId: scale.deviceId,
          deviceName: scale.name,
          message: timedOut
              ? 'Scale ${scale.name} did not respond within '
                    '${_connectTimeout.inSeconds}s.'
              : 'Scale ${scale.name} failed to connect.',
          suggestion: timedOut
              ? 'Try again. If the problem persists, power-cycle the scale.'
              : 'Wake the scale and try again. If the problem persists, '
                    'toggle Bluetooth off and on.',
          exception: e,
        ),
      );
      return timedOut
          ? ConnectionResult.timedOut(e.toString())
          : ConnectionResult.failed(e.toString());
    } finally {
      _isConnectingScale = false;
    }
  }

  Future<ConnectionResult> selectScale(Scale scale) async {
    final session = _selectionSession;
    if (session == null ||
        currentStatus.pendingAmbiguity != AmbiguityReason.scalePicker) {
      _log.fine('Ignoring stale scale selection ${scale.deviceId}');
      return const ConnectionResult.conflict();
    }
    final resolved = session.resolveScale(scale.deviceId);
    if (resolved == null) {
      _log.fine('Ignoring stale scale selection ${scale.deviceId}');
      return const ConnectionResult.conflict();
    }
    final machineError =
        !_machineConnected &&
            currentStatus.error?.kind ==
                ConnectionErrorKind.machineConnectFailed
        ? currentStatus.error
        : null;
    session.scanReport.markAttempted(resolved.deviceId);
    final result = await connectScale(resolved);
    session.scanReport.recordResult(resolved.deviceId, result);
    if (result.success) {
      _completeSelectionSessionIfResolved(session);
      if (machineError != null) _emit(machineError);
    } else {
      _cancelScaleReacquisition();
      _publishStatus(
        currentStatus.copyWith(
          pendingAmbiguity: () => AmbiguityReason.scalePicker,
        ),
      );
    }
    return result;
  }

  Future<bool> _connectMachineTracked(
    De1Interface machine,
    ScanReportBuilder scanReport,
  ) async {
    scanReport.markAttempted(machine.deviceId);
    final result = await connectMachine(machine, automatic: true);
    scanReport.recordResult(machine.deviceId, result);
    return _releaseSupersededAutomaticMachine();
  }

  Future<void> _connectScaleTrackedGated(
    Scale scale,
    ScanReportBuilder scanReport,
  ) async {
    if (_scaleReconnectBlockedByPowerMode) {
      _log.fine(
        'Skipping external scale early-connect while machine is sleeping '
        'and scale power mode is disconnect',
      );
      return;
    }
    if (_shouldDeferEarlyScaleConnect(scale)) {
      _log.fine(
        'Deferring external scale early-connect until machine resolves',
      );
      return;
    }
    await _connectScaleTracked(scale, scanReport);
  }

  bool _shouldDeferEarlyScaleConnect(Scale scale) {
    if (_isBengleAboutToBeMachine()) return true;
    if (scale is SimulatedDevice) return false;
    final preferredMachineId = settingsController.preferredMachineId;
    final machineResolved = _disconnectSupervisor.latestMachine != null;
    if (preferredMachineId != null && !machineResolved) return true;
    return false;
  }

  bool _isBengleAboutToBeMachine() {
    if (_disconnectSupervisor.latestMachine is BengleInterface) {
      return true;
    }
    final preferredMachineId = settingsController.preferredMachineId;
    if (preferredMachineId == null) return false;
    for (final d in deviceScanner.devices) {
      if (d is BengleInterface && d.deviceId == preferredMachineId) {
        return true;
      }
    }
    return false;
  }

  Future<ConnectionResult> _connectScaleTracked(
    Scale scale,
    ScanReportBuilder scanReport,
  ) async {
    scanReport.markAttempted(scale.deviceId);
    final result = await connectScale(scale);
    scanReport.recordResult(scale.deviceId, result);
    return result;
  }

  void _completeSelectionSessionIfResolved(ConnectionSelectionSession session) {
    if (currentStatus.pendingAmbiguity != null) return;
    _finishSelectionSession(session, ScanTerminationReason.completed);
  }

  void _finishSelectionSession(
    ConnectionSelectionSession session,
    ScanTerminationReason reason,
  ) {
    if (!identical(_selectionSession, session)) return;
    final report = session.finish(
      reason: reason,
      adapterStateAtEnd: deviceScanner.currentAdapterState,
    );
    if (report == null) return;
    _selectionSession = null;
    _scanReportSubject.add(report);
    _log.info(ScanReportBuilder.format(report));
  }

  void cancelActiveScan() {
    _explicitScanGeneration++;
    deviceScanner.stopScan();
    final queued = _queuedExplicitScan;
    _queuedExplicitScan = null;
    queued?.complete();
    final session = _selectionSession;
    if (session != null) {
      _publishStatus(currentStatus.copyWith(pendingAmbiguity: () => null));
      _finishSelectionSession(session, ScanTerminationReason.cancelledByUser);
    }
    _settleAfterScalePhase();
    _ensureScaleReacquisition();
  }

  void cancelSelectionSession() {
    final session = _selectionSession;
    if (session == null) return;
    _publishStatus(currentStatus.copyWith(pendingAmbiguity: () => null));
    _finishSelectionSession(session, ScanTerminationReason.cancelledByUser);
    _settleAfterScalePhase();
    _ensureScaleReacquisition();
  }

  void _cancelSelectionSession({required bool emitReport}) {
    final session = _selectionSession;
    if (session == null) return;
    if (emitReport) {
      _finishSelectionSession(session, ScanTerminationReason.cancelledByUser);
    } else {
      session.invalidate();
      _selectionSession = null;
    }
  }

  Future<void> disconnectMachine() async {
    _handleMachineDisconnected();
    _disconnectSupervisor.markMachineOffline();
    _publishStatus(currentStatus.copyWith(phase: ConnectionPhase.idle));
    final de1 = await de1Controller.de1.first;
    if (de1 != null) {
      markExpectingDisconnect(de1.deviceId);
      await de1.disconnect();
    }
  }

  Future<void> disconnectScale() async {
    _cancelSelectionSession(emitReport: true);
    _cancelScaleReacquisition();
    try {
      final scale = scaleController.connectedScale();
      markExpectingDisconnect(scale.deviceId);
      await scale.disconnect();
    } catch (_) {}
  }

  Future<void> shutdown() {
    final existing = _shutdownFuture;
    if (existing != null) return existing;

    _shuttingDown = true;
    final shutdown = _performShutdown();
    _shutdownFuture = shutdown;
    return shutdown;
  }

  Future<void> _performShutdown() async {
    _explicitScanGeneration++;
    _cancelSelectionSession(emitReport: false);
    _stopMachineRecovery();
    _stopWatchingConnectedMachineState();
    _deferredScaleScan?.cancel();
    _deferredScaleScan = null;
    _adapterRecoveryEpoch++;
    _adapterRecoveryNeeded = false;
    _adapterRecoveryTimer?.cancel();
    _adapterRecoveryTimer = null;
    _adapterRecoveryQueued = false;
    _pendingAttachAttempt = false;
    _pendingAttachEvent = null;
    _cancelPreferredScaleReconnect();

    final queuedExplicitScan = _queuedExplicitScan;
    _queuedExplicitScan = null;
    if (queuedExplicitScan != null && !queuedExplicitScan.isCompleted) {
      queuedExplicitScan.complete();
    }
    final queuedScaleOnly = _queuedScaleOnly;
    _queuedScaleOnly = null;
    if (queuedScaleOnly != null && !queuedScaleOnly.isCompleted) {
      queuedScaleOnly.complete();
    }

    try {
      deviceScanner.stopScan();
    } catch (error, stackTrace) {
      _log.warning('Scan stop during shutdown failed', error, stackTrace);
    }
    try {
      await _attachReconnectCoordinator?.dispose();
    } catch (error, stackTrace) {
      _log.warning('Attach recovery shutdown failed', error, stackTrace);
    }
    try {
      await _scaleWatch.dispose();
    } catch (error, stackTrace) {
      _log.warning('Scale watch shutdown failed', error, stackTrace);
    }
    try {
      await _adapterSub?.cancel();
    } catch (error, stackTrace) {
      _log.warning('Adapter subscription shutdown failed', error, stackTrace);
    }

    await _connectionWorkDone?.future;

    try {
      await disconnectMachine();
    } catch (error, stackTrace) {
      _log.warning('Machine disconnect failed', error, stackTrace);
    }
    try {
      await disconnectScale();
    } catch (error, stackTrace) {
      _log.warning('Scale disconnect failed', error, stackTrace);
    }
  }

  Future<void> dispose() async {
    await shutdown();
    await de1Controller.dispose();
    scaleController.dispose();
    _disconnectSupervisor.dispose();
    _disconnectExpectations.dispose();
    _statusPublisher.dispose();
    _scanReportSubject.close();
  }
}
