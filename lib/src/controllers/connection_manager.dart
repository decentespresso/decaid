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
import 'package:reaprime/src/models/device/usb_attach_probe.dart';
import 'package:reaprime/src/models/scan_report.dart';
import 'package:reaprime/src/settings/scale_power_mode.dart';
import 'package:reaprime/src/settings/settings_controller.dart';
import 'package:rxdart/rxdart.dart';

/// High-level phase of the [ConnectionManager] state machine.
///
/// Transitions are documented in `doc/DeviceManagement.md` →
/// "Phase transitions" (comms-harden #30). All writes route through
/// `StatusPublisher.publish`.
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

  /// Remembered-device registry for quick-connect. Nullable so existing
  /// tests and wiring without a registry still work — null disables
  /// quick-connect and falls through to the scan path.
  final RememberedDevicesController? rememberedDevices;

  final _log = Logger('ConnectionManager');

  final StatusPublisher _statusPublisher = StatusPublisher();

  final BehaviorSubject<ScanReport> _scanReportSubject = BehaviorSubject();

  Stream<ConnectionStatus> get status => _statusPublisher.stream;
  ConnectionStatus get currentStatus => _statusPublisher.current;

  /// The most recent scan report, or null if no scan has completed yet.
  ScanReport? get lastScanReport => _scanReportSubject.valueOrNull;

  /// Emits a [ScanReport] after each scan + connection cycle completes.
  Stream<ScanReport> get scanReportStream => _scanReportSubject.stream;

  // Re-entry guards for the respective async methods. These prevent
  // concurrent calls from racing each other; they do NOT duplicate
  // device-connection state.
  bool _isConnecting = false;
  bool _isConnectingMachine = false;
  bool _isConnectingScale = false;
  bool _activeScaleOnlyScan = false;
  ConnectionSelectionSession? _selectionSession;

  /// Generation counter bumped on each new explicit [scanAndConnect] or
  /// [cancelActiveScan] call. [_connectImpl] checks it after [runScan]
  /// returns; if it changed the in-flight scan was cancelled and policy
  /// must not run.
  int _explicitScanGeneration = 0;

  /// End-to-end timeout for a single `connectMachine` / `connectScale`
  /// call. Phase 1 bounded the MMR-read hang at 2s; this is the
  /// belt-and-braces that keeps any other transport-level hang from
  /// wedging `_isConnecting` (comms-harden #31). Real-hardware
  /// connect currently observes 3–10s on tablet; 30s leaves ~3x
  /// headroom for slow adapters without feeling sluggish.
  Duration get _connectTimeout => Platform.isLinux
      ? const Duration(seconds: 60)
      : const Duration(seconds: 30);

  // Device-connection state + unexpected-disconnect emission live on
  // DisconnectSupervisor — it owns the two stream subscribers and
  // exposes `isMachineConnected` / `isScaleConnected` as live views
  // of the source streams (no parallel flags).
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

  final DisconnectExpectations _disconnectExpectations =
      DisconnectExpectations();

  /// Completer shared by all `connect(scaleOnly: true)` callers that
  /// arrive while another connect is already running. Drained in the
  /// outer connect()'s finally block (comms-harden #9).
  Completer<void>? _queuedScaleOnly;

  /// Completer shared by all `scanAndConnect()` callers that arrive while
  /// another connect is already running. Drained BEFORE
  /// [_queuedScaleOnly] so explicit user-requested discovery is not
  /// delayed behind background scale reacquisition.
  Completer<void>? _queuedExplicitScan;
  bool _adapterRecoveryQueued = false;
  bool _adapterRecoveryNeeded = false;
  int _adapterRecoveryEpoch = 0;
  AdapterState? _lastAdapterState;
  Timer? _adapterRecoveryTimer;

  @visibleForTesting
  Duration adapterRecoveryDebounce = const Duration(seconds: 1);

  /// Deferred scale-only rescan armed when the preferred machine
  /// connects but no preferred scale is configured. The initial scan
  /// stops the instant the machine connects (see [_checkEarlyStop]), so
  /// a scale that advertises a beat later is missed; this recovers it.
  Timer? _deferredScaleScan;

  /// Preferred-scale reconnect retry while a machine is connected but the
  /// configured scale is missing. BLE advertisements are only observed during
  /// scans, so this gives a powered-on scale a chance to appear without user
  /// interaction.
  Timer? _preferredScaleReconnect;

  /// Consecutive scale-reconnect failures for exponential backoff.
  /// Reset on successful scale connect or machine disconnect.
  int _scaleReconnectFailures = 0;

  /// Compute exponential backoff delay: 5s → 10s → 20s → 40s → 60s cap.
  Duration get _scaleReconnectBackoff {
    final base = 5;
    final seconds = base * (1 << _scaleReconnectFailures).clamp(1, 12);
    return Duration(seconds: seconds.clamp(5, 60));
  }

  /// Machine auto-reconnect (recovery mode). Armed by an *unexpected*
  /// machine disconnect when a preferred machine is configured; retries
  /// full `connect()` scans with the same 5s→60s backoff the scale loop
  /// uses, and reschedules itself after every attempt that ends without
  /// a machine. Cleared on machine connect, deliberate disconnect, and
  /// dispose. Motivated by a power-outage incident where the app sat
  /// "disconnected" for six hours because nothing ever rescanned — see
  /// doc/plans/machine-connection-recovery.md.
  bool _machineRecoveryActive = false;
  Timer? _machineReconnect;
  int _machineReconnectFailures = 0;

  /// Base delay for the machine-reconnect backoff. Overridable in tests.
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

  /// Snapshot-staleness watchdog: if a connected machine stops pushing
  /// snapshot frames for this long, the push channel is presumed dead
  /// (live-link + dead-push — the field incident of 2026-07-07). A clean
  /// forced reconnect re-establishes notifications. See Fix #1.
  /// Overridable in tests so the watchdog can be driven without a real
  /// 10s wait.
  @visibleForTesting
  Duration snapshotStalenessTimeout = const Duration(seconds: 10);

  Timer? _stateWatchdog;
  int _watchdogGeneration = 0;

  /// Number of times the staleness watchdog forced a machine reconnect.
  /// Incremented once per force action — tests assert on this instead of
  /// driving the full disconnect+connect cycle through fake_async.
  @visibleForTesting
  int snapshotStalenessReconnects = 0;

  /// Set true by [_checkEarlyStop] when it actually cut the scan short on
  /// machine-connect with no preferred scale. Distinguishes that case
  /// from a full scan that simply completed without a scale — only the
  /// former warrants a deferred rescan. Reset at the start of each full
  /// connect.
  bool _earlyStopFired = false;

  /// Delay before the deferred scale rescan fires. Mirrors the post-wake
  /// reconnect in `De1StateManager`: starting another scan immediately
  /// after the DE1 connect starves the shared Android BLE radio and
  /// risks LINK_SUPERVISION_TIMEOUT on the DE1, so we let the link
  /// stabilise first. Overridable in tests to avoid a real wait.
  @visibleForTesting
  Duration deferredScaleScanDelay = const Duration(seconds: 3);

  /// Whether the scanner supports the persistent background scale watch
  /// (Android). De1StateManager consults this to skip its wake-time
  /// scale-only burst scan when the watch already covers reacquisition.
  bool get supportsBackgroundScaleWatch =>
      deviceScanner.supportsBackgroundWatch;

  ConnectionManager({
    required this.deviceScanner,
    required this.de1Controller,
    required this.scaleController,
    required this.settingsController,
    this.rememberedDevices,
    Duration deviceAttachSettleDelay = const Duration(milliseconds: 500),
  }) {
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
      // The Bengle clause covers arm time AND the post-connect
      // continuation: a Bengle's integrated scale owns the scale slot
      // (the rule _runScalePhase enforces on the burst path), so a
      // refused external-scale sighting must end the watch cycle, not
      // restart the scan indefinitely.
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
          );
  }

  bool _shouldAttemptAttachReconnect() {
    if (_machineConnected) return false;
    if (_attachProbe != null) return true;
    final preferredMachineId = settingsController.preferredMachineId;
    return preferredMachineId != null && preferredMachineId.isNotEmpty;
  }

  UsbAttachProbe? get _attachProbe =>
      deviceScanner is UsbAttachProbe ? deviceScanner as UsbAttachProbe : null;

  bool _pendingAttachAttempt = false;
  DeviceAttachedEvent? _pendingAttachEvent;

  Future<bool> _attemptAttachReconnect(DeviceAttachedEvent event) async {
    if (_machineConnected) return true;
    if (_attachProbe == null) return _attemptAutomaticConnect();
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
      return _attemptAutomaticConnect();
    }
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
    try {
      final probe = _attachProbe;
      if (probe == null) return false;
      final result = await probe.connectAttachedMachine(event);
      switch (result) {
        case AttachProbeConnected(machine: final machine):
          _log.info(
            'Attach probe: machine ${machine.name} (${machine.deviceId}) '
            'connected, adopting',
          );
          await _adoptAttachedMachine(machine);
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
    if (!_shouldAttemptAttachReconnect()) return;
    if (!_machineRecoveryActive) {
      _machineRecoveryActive = true;
    }
    _maybeScheduleMachineReconnect();
  }

  void _listenForAdapter() {
    _adapterSub = deviceScanner.adapterStateStream.listen((state) {
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

  /// Emit a [ConnectionError] onto the status stream without changing
  /// the current phase. Thin proxy over [StatusPublisher.emitError] so
  /// every outbound update goes through the same gatekeeper
  /// (comms-harden #8).
  void _emit(ConnectionError err) => _statusPublisher.emitError(err);

  /// Surface an out-of-band [ConnectionError] on the status stream —
  /// for collaborators outside the connect flow (`WorkflowDeviceSync`'s
  /// profile-upload failure). Routes through the same
  /// [StatusPublisher] gatekeeper as internal emits.
  void reportError(ConnectionError err) => _emit(err);

  /// Clear the current status error iff it is of [kind]. Lets an
  /// out-of-band reporter retract its own error on recovery without
  /// stomping an unrelated one that has since replaced it.
  void clearErrorOfKind(String kind) {
    if (currentStatus.error?.kind == kind) {
      _clearError();
    }
  }

  /// Build a [ConnectionError] for a failed connect attempt. Pulls out
  /// `ble_code` / `ble_description` when the caught exception is a
  /// [BleConnectException] (the domain type transports map their native
  /// BLE error into); otherwise stashes the stringified exception under
  /// `details.exception`.
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

  /// Clears the current error. Proxy over [StatusPublisher.clearError]
  /// — called by environmental recovery handlers (adapter on,
  /// permission granted).
  void _clearError() => _statusPublisher.clearError();

  /// Publish a new [ConnectionStatus] with sticky/transient error
  /// gating. Proxy over [StatusPublisher.publish].
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

  /// Call immediately before an app-initiated disconnect. The next
  /// `disconnected` event for `deviceId` will be treated as expected and
  /// will not emit an error. A 10-second TTL safety timer clears the
  /// expectation if the disconnect event never arrives.
  void markExpectingDisconnect(String deviceId) {
    _disconnectExpectations.mark(deviceId);
  }

  @visibleForTesting
  void debugNotifyScaleDisconnected(String deviceId) =>
      _disconnectSupervisor.notifyScaleDisconnected(deviceId);

  @visibleForTesting
  void debugNotifyMachineDisconnected(String deviceId) =>
      _disconnectSupervisor.notifyMachineDisconnected(deviceId);

  /// Quick-connect or scan for devices using automatic recovery policy.
  ///
  /// When [scaleOnly] is false (default):
  /// 1. Scans for all devices
  /// 2. Applies machine preference policy (auto-connect, picker, or idle)
  /// 3. On successful machine connection, applies scale preference policy
  ///
  /// When [scaleOnly] is true:
  /// Skips machine policy entirely — use when the machine is already
  /// connected and only a scale reconnect is needed (e.g., after wake).
  ///
  /// Early-stop: if a preferred machine is set, the scan stops early once
  /// the machine connects (when no preferred scale is configured) or once
  /// both preferred devices connect (when a preferred scale is set). With
  /// no preferred machine, the full scan runs to discover all devices.
  /// When the scan stops on machine-connect with no preferred scale, a
  /// deferred (fire-and-forget) scale-only rescan is armed to pick up a
  /// scale that advertised after the early stop — see
  /// [_maybeArmDeferredScaleScan].
  ///
  /// Concurrency: a `scaleOnly` call that arrives while another `connect`
  /// is already running is queued and replayed after the in-flight call
  /// completes. Multiple queued `scaleOnly` calls coalesce into one
  /// replay and share the same returned Future. Non-`scaleOnly` calls
  /// during an in-flight connect are still dropped silently
  /// (comms-harden #9).
  Future<void> connect({bool scaleOnly = false}) => _runConnect(
    scaleOnly: scaleOnly,
    policy: scaleOnly
        ? ConnectionAttemptPolicy.scaleRecovery
        : ConnectionAttemptPolicy.automatic,
  );

  /// Complete an explicit scan before connecting missing device slots.
  ///
  /// When a connection cycle is already in progress, the active scan is
  /// superseded: its generation is invalidated, the scanner is stopped,
  /// and exactly one replacement explicit scan is queued. Multiple
  /// concurrent callers share the queued future. The superseded scan
  /// emits one cancelled report; the replacement emits its normal report.
  Future<void> scanAndConnect() async {
    // Multiple concurrent explicit requests coalesce into one replacement.
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
      // Single priority-aware drain loop: explicit always evaluated
      // first at each scheduling boundary. An explicit request arriving
      // during a queued scale-only drain is picked up immediately. A
      // queued attach probe runs first.
      while (_pendingAttachAttempt ||
          _queuedExplicitScan != null ||
          _adapterRecoveryQueued ||
          _queuedScaleOnly != null) {
        if (_pendingAttachAttempt) {
          _pendingAttachAttempt = false;
          final event = _pendingAttachEvent;
          _pendingAttachEvent = null;
          if (event != null && !_machineConnected) {
            final handled = await _executeAttachProbe(event);
            if (!handled && settingsController.preferredMachineId != null) {
              await _attemptAutomaticConnect();
            }
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
    _isConnecting = true;
    _publishStatus(
      currentStatus.copyWith(
        intent:
            intent ??
            (identical(policy, ConnectionAttemptPolicy.explicitScan)
                ? ConnectionIntent.explicitDiscovery
                : identical(policy, ConnectionAttemptPolicy.scaleRecovery)
                ? ConnectionIntent.scaleRecovery
                : ConnectionIntent.automatic),
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
    }
  }

  void _queueAdapterRecovery() {
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

  /// Attempt to quick-connect the preferred machine from remembered
  /// metadata. Returns the adopted [De1Interface], or null on failure.
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
        // Phase (connectingMachine) was already published by _connectImpl
        // before calling this method — no need to re-publish here.
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
    // Also disarms the watch: during a full scan EarlyConnectWatcher
    // observes the same deviceStream and owns preferred-scale connects —
    // a live watch would race it. Re-armed at the end-of-connect sites.
    _cancelScaleReacquisition();
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

    // Quick-connect: try direct connection to the preferred machine from
    // remembered metadata. Scales are excluded — the machine-only critical
    // path publishes ready immediately after adoption, then kicks off
    // background scale discovery.
    if (policy.directRememberedMachine &&
        !scaleOnly &&
        !_machineConnected &&
        rememberedDevices != null) {
      _publishStatus(
        currentStatus.copyWith(phase: ConnectionPhase.connectingMachine),
      );
      final qcMachine = await _tryQuickConnectMachine();
      if (qcMachine != null) {
        _log.info('Quick-connect: machine connected, proceeding to ready');
        if (qcMachine is BengleInterface) {
          await _attachBengleVirtualScale(qcMachine);
        } else if (!_scaleConnected) {
          if (settingsController.preferredScaleId != null) {
            // Route through the reacquisition selector: on watch-capable
            // platforms the background scale watch (also armed by the
            // machine-connected handler) owns this — scheduling the
            // legacy backoff here would run radio-starving bursts
            // alongside it.
            _ensureScaleReacquisition();
          } else {
            _armPostQuickConnectScaleScan();
          }
        }
        _publishStatus(currentStatus.copyWith(phase: ConnectionPhase.ready));
        return;
      }
    }

    final preferredMachineId = scaleOnly
        ? null
        : settingsController.preferredMachineId;
    final preferredScaleId = settingsController.preferredScaleId;
    // Early stop is enabled for any full (non-scaleOnly) connect.
    // Previously gated on preferredMachineId != null, which meant
    // auto-discovered machines never stopped the scan early even
    // with both devices found and connected.
    final earlyStopEnabled = !scaleOnly && policy.stopScanAfterPreferredConnect;

    final scanStartTime = DateTime.now();

    // Build a filtered scan for Android scaleOnly path to bypass
    // background throttling. Full connect stays unfiltered.
    final scaleFilter = scaleOnly && Platform.isAndroid
        ? ScanFilter(
            preferredDeviceId: preferredScaleId,
            deviceTypes: {DeviceType.scale},
          )
        : null;

    // Capture the generation at scan start so the post-scan check detects
    // cancellation that happened while the scan was in-flight.
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
      // Scan failed catastrophically; orchestrator already emitted
      // the sticky error + phase=idle.
      return;
    }

    // Explicit scan was cancelled while the scan was in-flight — emit a
    // cancelled report and bail without applying policy.
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
      // runScan published `scanning`. `connectScale` resolves the phase
      // to `ready` when a scale connects; when the scale phase was a
      // no-op (no scale found) settle it from machine state so the UI
      // doesn't stay stuck on `scanning`.
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
        await _connectMachineTracked(m, scanReport);
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

  /// Stop scan early when all preferred devices are connected.
  ///
  /// Three branches ordered from most-specific to least:
  /// 1. Preferred machine + preferred scale → both must be connected.
  /// 2. Preferred machine only → stop on machine connect.
  /// 3. No preferences → stop when at least one machine + one scale
  ///    are connected (the common auto-discovered case).
  void _checkEarlyStop(bool earlyStopEnabled) {
    if (!earlyStopEnabled) return;
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

  /// Arm a deferred scale-only scan after machine quick-connect when the
  /// user has no preferred scale configured. Unlike
  /// [_maybeArmDeferredScaleScan], this path is independent of
  /// [_earlyStopFired] — quick-connect skips the scan entirely, so there
  /// is no early-stop flag to gate on.
  void _armPostQuickConnectScaleScan() {
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

  /// Compensate for [_checkEarlyStop] cutting the scan short. When a
  /// preferred machine is configured but no preferred scale is, the scan
  /// stops the instant the machine connects — a scale that advertises a
  /// beat later would never reach the scale phase. If we land here with
  /// the machine connected but no scale, arm a deferred scale-only rescan
  /// to pick it up. Fire-and-forget, mirroring the post-wake reconnect in
  /// `De1StateManager` — the machine is already `ready` and usable; the
  /// scale connects in the background if one shows up.
  ///
  /// Gated on [_earlyStopFired] — the scan was *actually* cut short on
  /// machine-connect. A full scan that ran to completion already saw
  /// every scale that advertised, so it never arms a (pointless) rescan,
  /// even when a preferred machine is set but resolved post-scan.
  void _maybeArmDeferredScaleScan() {
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

  /// Route scale reacquisition to the persistent background watch when
  /// the scanner supports it (Android), else to the legacy backoff-burst
  /// loop. Every former `_maybeSchedulePreferredScaleReconnect` call
  /// site goes through here; the legacy loop also remains the fallback
  /// when the watch fails to start (see `onWatchUnavailable`).
  void _ensureScaleReacquisition() {
    if (deviceScanner.supportsBackgroundWatch) {
      // The watch's shouldWatch gate covers the full arming policy,
      // including the Bengle integrated-scale rule.
      unawaited(_scaleWatch.arm());
    } else {
      _maybeSchedulePreferredScaleReconnect();
    }
  }

  void _cancelScaleReacquisition() {
    unawaited(_scaleWatch.disarm());
    _cancelPreferredScaleReconnect();
  }

  /// Watch-driven connects bypass `_runScalePhase`, so the Bengle rule
  /// is re-applied here for sightings that land after the watch armed
  /// but once a Bengle has become the machine.
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
    return _machineConnected &&
        !_scaleConnected &&
        currentStatus.pendingAmbiguity != AmbiguityReason.scalePicker &&
        settingsController.preferredScaleId != null &&
        !_scaleReconnectBlockedByPowerMode;
  }

  void _cancelPreferredScaleReconnect() {
    _preferredScaleReconnect?.cancel();
    _preferredScaleReconnect = null;
    _scaleReconnectFailures = 0;
  }

  void _handleScaleDisconnected() {
    _cancelSelectionSession(emitReport: true);
    _ensureScaleReacquisition();
  }

  void _handleMachineConnected() {
    _stopMachineRecovery();
    _watchConnectedMachineState();
    _ensureScaleReacquisition();
  }

  void _handleMachineDisconnected() {
    _cancelSelectionSession(emitReport: true);
    // Deliberate disconnects route only through here (disconnectMachine
    // pre-nulls the supervisor view), so recovery stays off for them.
    // For unexpected drops the supervisor fires
    // [_startMachineRecovery] right after this cleanup.
    _stopMachineRecovery();
    _stopWatchingConnectedMachineState();
    _deferredScaleScan?.cancel();
    _deferredScaleScan = null;
    _cancelScaleReacquisition();
    if (_activeScaleOnlyScan) {
      deviceScanner.stopScan();
    }
  }

  /// Enter machine recovery mode after an unexpected disconnect and arm
  /// the first retry. No-op without a `preferredMachineId` — a
  /// background retry must never surface a machine-picker ambiguity.
  void _startMachineRecovery() {
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

  /// Whether the machine auto-reconnect recovery loop is currently armed.
  /// Test hook for asserting the staleness watchdog's strand safety-net.
  @visibleForTesting
  bool get machineRecoveryActive => _machineRecoveryActive;

  bool _shouldRetryMachine() {
    return _machineRecoveryActive &&
        !_machineConnected &&
        settingsController.preferredMachineId != null;
  }

  void _maybeScheduleMachineReconnect() {
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
      // Reschedule regardless of how the attempt ended — including
      // attempts silently dropped by the concurrent-connect guard.
      // No-op once the machine is back or recovery was stopped.
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
    // Arm the initial-grace watchdog before the first frame lands —
    // covers the Android GATT-busy first-notify-loss race (sb-060/061/062):
    // if the first push is lost, the watchdog fires and forces a clean
    // reconnect that re-establishes notifications.
    _armStateWatchdog(machine.deviceId);
    _machineSnapshotSub = snapshots.listen(
      (snapshot) {
        // Every frame — including a deduped duplicate of the current state —
        // proves the push channel is alive. Re-arm BEFORE the dedupe check
        // so a steady non-transitioning state doesn't false-trigger.
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
      _forceMachineReconnect();
    });
  }

  /// Force a deliberate, immediate machine reconnect (no backoff). Bumps
  /// the generation token first so any in-flight or stale watchdog Timer
  /// bails; `disconnectMachine` also tears down the watcher (bumps gen
  /// again, cancels the Timer) and marks the disconnect expected so no
  /// error banner surfaces.
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
      // Safety net against stranding the machine. `disconnectMachine`
      // marked the drop expected, so the unexpected-disconnect path never
      // armed machine recovery; and the `connect()` above can be silently
      // dropped by the concurrent-connect guard (e.g. a scale-only rescan
      // already in flight) or return without finding the machine. If
      // we're still machineless, hand off to the recovery loop: it
      // retries with backoff and cancels itself the moment the machine
      // reconnects (no-op without a preferredMachineId).
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

  /// Gate the scale phase on machine type. When the connected machine
  /// is a [BengleInterface], its integrated scale (exposed as a
  /// [BengleVirtualScale]) takes the slot and external-scale discovery
  /// is skipped entirely — even if `preferredScaleId` is set. Multi-scale
  /// support is a roadmap follow-up; for now Bengle's integrated scale
  /// always wins. For DE1 (and any non-Bengle machine), the existing
  /// external-scale discovery flow runs unchanged.
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

  /// Wrap the machine's integrated scale in a [BengleVirtualScale] and
  /// attach it via [ScaleController]. Failures are logged but do not
  /// propagate — the machine remains connected and usable.
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

  /// Apply the scale-phase policy, tracking attempts on [scanReport].
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

  Future<ConnectionResult> connectMachine(De1Interface machine) async {
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

    // Do not explicitly clear `error` — the gatekeeper handles it.
    _publishStatus(
      currentStatus.copyWith(
        phase: ConnectionPhase.connectingMachine,
        activeTargetTransport: () => machine.transportType,
        pendingAmbiguity: () => null,
      ),
    );

    try {
      await de1Controller.connectToDe1(machine).timeout(_connectTimeout);
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

  /// Returns the attempt outcome so tracked callers can report it —
  /// failures are handled here (status emit) and NOT rethrown.
  Future<ConnectionResult> connectScale(Scale scale) async {
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

    // Do not explicitly clear `error` — the gatekeeper handles it.
    _publishStatus(
      currentStatus.copyWith(
        phase: ConnectionPhase.connectingScale,
        activeTargetTransport: () => scale.transportType,
        pendingAmbiguity: () => null,
      ),
    );

    try {
      await scaleController.connectToScale(scale).timeout(_connectTimeout);
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
      // DO NOT REORDER — `ready` is a clearing phase and `scaleConnectFailed`
      // is transient, so emitting first and then publishing `ready` would
      // run the error through the gatekeeper's strip rule. Publishing the
      // phase first (no error present) then calling `_emit` (bypasses the
      // gatekeeper) is the only order that keeps the error visible.
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
    // Capture the machine error before connectScale publishes a clearing
    // phase (connectingScale) and the gatekeeper strips it.
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

  /// Connect a machine and record the attempt outcome on the scan
  /// report builder.
  Future<void> _connectMachineTracked(
    De1Interface machine,
    ScanReportBuilder scanReport,
  ) async {
    scanReport.markAttempted(machine.deviceId);
    final result = await connectMachine(machine);
    scanReport.recordResult(machine.deviceId, result);
  }

  /// Wrap [_connectScaleTracked] with the early-connect deferral gate.
  /// See [_shouldDeferEarlyScaleConnect] for the full policy.
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
    if (_shouldDeferEarlyScaleConnect()) {
      _log.fine(
        'Deferring external scale early-connect until machine resolves',
      );
      return;
    }
    await _connectScaleTracked(scale, scanReport);
  }

  /// Returns true when the external scale's early-connect path should
  /// be skipped during the scan, leaving the post-scan
  /// [_runScalePhase] to decide per resolved machine type.
  ///
  /// Two conditions trigger a defer:
  ///
  /// 1. A Bengle is already (or about to be) the connected machine —
  ///    [_isBengleAboutToBeMachine]. The integrated scale will take
  ///    the slot in the post-scan policy stage.
  ///
  /// 2. Conservative skip (added 2026-05-05): a `preferredMachineId`
  ///    is configured but no machine has resolved yet on the de1
  ///    stream. Without this, an external scale appearing in scan
  ///    results before the (preferred) Bengle would race past the
  ///    Bengle-inference check (Bengle not yet visible to scanner /
  ///    `latestMachine` still null), early-connect, and then the
  ///    post-scan virtual-attach path would short-circuit because the
  ///    scale slot is already taken.
  ///
  ///    Cost: DE1+scale users lose parallel early-connect (~1s
  ///    latency in the worst case). Acceptable trade for an
  ///    unbreakable "integrated-always-wins on Bengle" invariant.
  ///    Multi-scale support (TODO P2) will revisit.
  bool _shouldDeferEarlyScaleConnect() {
    if (_isBengleAboutToBeMachine()) return true;
    final preferredMachineId = settingsController.preferredMachineId;
    final machineResolved = _disconnectSupervisor.latestMachine != null;
    if (preferredMachineId != null && !machineResolved) return true;
    return false;
  }

  /// True if the connected machine is already a Bengle, or if the
  /// preferred-machine id matches a `BengleInterface` device currently
  /// visible to the scanner. Lets us short-circuit external-scale
  /// connects before the Bengle's `connectToDe1` finishes.
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

  /// Connect a scale and record the attempt outcome on the scan
  /// report builder.
  Future<ConnectionResult> _connectScaleTracked(
    Scale scale,
    ScanReportBuilder scanReport,
  ) async {
    scanReport.markAttempted(scale.deviceId);
    // connectScale handles its own failures (status emit) and reports the
    // outcome instead of throwing — record what actually happened rather
    // than assuming success (a swallowed failure used to log "— connected").
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

  /// Cancels the active explicit scan, including any in-flight discovery.
  ///
  /// Bumps the generation token so the in-flight [_connectImpl] either
  /// bails before runScan (not yet started) or detects the mismatch after
  /// the scan completes and skips policy. Also stops the scanner and
  /// cancels any existing selection session.
  ///
  /// Safe to call when no scan is active — it is a no-op in that case.
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

  /// Cancels the active selection session, finalising the scan report
  /// as cancelled and clearing [pendingAmbiguity]. Safe to call when no
  /// session is active — it is a no-op in that case.
  ///
  /// After cancellation the phase settles from actual connected state
  /// and scale reacquisition is re-armed so the background watch can
  /// pick up the preferred scale again.
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
    // Pre-null the supervisor's tracked de1 view so its stream listener's
    // `hadMachine` check sees "no machine was connected" by the time
    // it fires on the upcoming null emission — otherwise the supervisor
    // would emit a redundant phase=idle on top of the one below.
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
    } catch (_) {
      // No scale connected — nothing to disconnect
    }
    // No explicit reset of `_latestScaleState` — the scale
    // connectionState listener will observe the upcoming disconnected
    // emission and update it.
  }

  Future<void> dispose() async {
    _cancelSelectionSession(emitReport: false);
    _stopMachineRecovery();
    _deferredScaleScan?.cancel();
    _adapterRecoveryTimer?.cancel();
    _adapterRecoveryTimer = null;
    _adapterRecoveryQueued = false;
    _cancelPreferredScaleReconnect();
    await _attachReconnectCoordinator?.dispose();
    _queuedExplicitScan?.complete();
    _queuedExplicitScan = null;
    // Awaited (not via _cancelScaleReacquisition) so the watch is
    // deterministically stopped before the controllers it feeds are
    // disposed.
    await _scaleWatch.dispose();
    _stopWatchingConnectedMachineState();
    await de1Controller.dispose();
    scaleController.dispose();
    _disconnectSupervisor.dispose();
    _adapterSub?.cancel();
    _disconnectExpectations.dispose();
    _statusPublisher.dispose();
    _scanReportSubject.close();
  }
}
