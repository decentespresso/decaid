import 'dart:io';
import 'dart:async';
import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:logging/logging.dart';
import 'package:reaprime/src/controllers/connection_manager.dart';
import 'package:reaprime/src/controllers/de1_controller.dart';
import 'package:reaprime/src/controllers/persistence_controller.dart';
import 'package:reaprime/src/controllers/scale_controller.dart';
import 'package:reaprime/src/controllers/shot_sequencer.dart';
import 'package:reaprime/src/controllers/workflow_controller.dart';
import 'package:reaprime/src/models/data/profile.dart';
import 'package:reaprime/src/models/data/shot_annotations.dart';
import 'package:reaprime/src/models/data/shot_record.dart';
import 'package:reaprime/src/models/data/shot_snapshot.dart';
import 'package:reaprime/src/models/data/shot_state_event.dart';
import 'package:reaprime/src/models/data/workflow.dart';
import 'package:reaprime/src/models/device/bengle_interface.dart';
import 'package:reaprime/src/models/device/device.dart' as device;
import 'package:reaprime/src/models/device/machine.dart';
import 'package:reaprime/src/realtime_shot_feature/realtime_shot_feature.dart';
import 'package:reaprime/src/realtime_steam_feature/realtime_steam_feature.dart';
import 'package:reaprime/src/launcher/launcher_view.dart';
import 'package:reaprime/src/services/account/decent_account_service.dart';
import 'package:reaprime/src/settings/feature_flags.dart';
import 'package:reaprime/src/settings/gateway_mode.dart';
import 'package:reaprime/src/settings/scale_power_mode.dart';
import 'package:reaprime/src/settings/settings_controller.dart';
import 'package:uuid/uuid.dart';

/// Manages DE1 state changes and handles navigation or shot tracking
/// based on the current gateway mode.
///
/// This class separates the concern of handling DE1 state changes from
/// the main app widget, providing better memory management and cleaner code.
///
class De1StateManager with WidgetsBindingObserver {
  final Logger _logger = Logger('De1StateManager');

  final De1Controller _de1Controller;
  final ScaleController _scaleController;
  final WorkflowController _workflowController;
  final PersistenceController _persistenceController;
  final SettingsController _settingsController;
  final ConnectionManager _connectionManager;
  final DecentAccountService? _accountService;
  final GlobalKey<NavigatorState> _navigatorKey;

  StreamSubscription<Machine?>? _de1Subscription;
  final _emailedSerials = <String>{};
  StreamSubscription<MachineSnapshot>? _snapshotSubscription;
  ShotSequencer? _currentShotSequencer;
  StreamSubscription<ShotState>? _shotStateSubscription;
  StreamSubscription<ShotSnapshot>? _shotSnapshotsSubscription;
  StreamSubscription<ShotDecision>? _shotDecisionSubscription;

  /// Stable id for the tracked shot, minted when the sequencer is created so
  /// the live `/ws/v1/machine/shotState` frames and the eventually persisted
  /// ShotRecord.id match — clients can correlate the stream to the saved shot.
  String? _currentShotId;

  /// Latest machine snapshot, kept so shotState frames carry machine context.
  MachineSnapshot? _latestSnapshot;

  bool _isRealtimeFeatureActive = false;
  final List<ShotSnapshot> _currentShotSnapshots = [];

  MachineState? _previousMachineState;

  /// Cancellable timer for deferred scale reconnect after machine wake.
  /// Prevents BLE radio starvation that causes LINK_SUPERVISION_TIMEOUT
  /// on the DE1 when scale service discovery monopolizes the shared radio.
  Timer? _deferredScaleScan;

  /// Delay before the post-wake scale reconnect fires. Overridable in
  /// tests to avoid a real 3s wait.
  @visibleForTesting
  Duration deferredScaleScanDelay = const Duration(seconds: 3);

  final Set<AppLifecycleState> _backgroundStates;

  AppLifecycleState _currentAppState = AppLifecycleState.resumed;

  bool _appIsInForeground = true;
  bool _navigationContextReady = false;

  De1StateManager({
    required De1Controller de1Controller,
    required ScaleController scaleController,
    required WorkflowController workflowController,
    required PersistenceController persistenceController,
    required SettingsController settingsController,
    required ConnectionManager connectionManager,
    DecentAccountService? accountService,
    required GlobalKey<NavigatorState> navigatorKey,
  }) : _de1Controller = de1Controller,
       _scaleController = scaleController,
       _workflowController = workflowController,
       _persistenceController = persistenceController,
       _settingsController = settingsController,
       _connectionManager = connectionManager,
       _accountService = accountService,
       _navigatorKey = navigatorKey,
       _backgroundStates = _getPlatformBackgroundStates() {
    _initialize();
  }

  /// Returns the set of AppLifecycleState values that should be considered
  /// "background" states for the current platform.
  static Set<AppLifecycleState> _getPlatformBackgroundStates() {
    if (Platform.isAndroid || Platform.isIOS) {
      return {
        AppLifecycleState.paused,
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.detached,
      };
    } else if (Platform.isMacOS || Platform.isWindows || Platform.isLinux) {
      return {AppLifecycleState.detached};
    } else {
      return {AppLifecycleState.paused, AppLifecycleState.detached};
    }
  }

  /// Initializes the state manager and starts listening to DE1 state changes.
  void _initialize() {
    WidgetsBinding.instance.addObserver(this);

    _checkNavigationContext();

    _de1Subscription = _de1Controller.de1.listen(_handleDe1Change);

    Future.delayed(const Duration(milliseconds: 500), () {
      _checkNavigationContext();
    });
  }

  /// Checks if navigation context is available and ready
  void _checkNavigationContext() {
    final context = _navigatorKey.currentContext;
    _navigationContextReady = context != null && context.mounted;
    _logger.fine('Navigation context ready: $_navigationContextReady');
  }

  /// Returns true if the launcher is the current top-level route.
  bool get _isLauncherActive {
    final context = _navigatorKey.currentContext;
    if (context == null || !context.mounted) return false;
    final navigator = Navigator.of(context);
    Route<dynamic>? result;
    navigator.popUntil((route) {
      result = route;
      return true;
    });
    final route = result;

    return route?.settings.name == LauncherView.routeName && route!.isCurrent;
  }

  /// Returns true if the current app state is considered "background" for the platform.
  bool get _isAppInBackground => _backgroundStates.contains(_currentAppState);

  /// Returns true if the current app state is considered "foreground" for the platform.
  bool get _isAppInForeground => !_isAppInBackground;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _logger.fine(
      'App lifecycle state changed: $state (platform: ${Platform.operatingSystem})',
    );

    _currentAppState = state;

    final bool wasInForeground = _appIsInForeground;
    _appIsInForeground = _isAppInForeground;

    if (wasInForeground != _appIsInForeground) {
      _logger.info('App foreground state changed: $_appIsInForeground');
    }

    if (state == AppLifecycleState.resumed) {
      _checkNavigationContext();
    }
    if (!Platform.isAndroid && !Platform.isIOS) {
      _logger.fine(
        'Desktop platform state change: ${state.name}, ensuring navigation context',
      );
      _checkNavigationContext();
    }
  }

  /// Handles changes to the connected DE1 machine.
  void _handleDe1Change(Machine? machine) {
    _snapshotSubscription?.cancel();
    _snapshotSubscription = null;

    if (machine != null) {
      _logger.info('DE1 connected, starting to listen for state changes');
      _snapshotSubscription = machine.currentSnapshot.listen(_handleSnapshot);

      final sn = machine.machineInfo.serialNumber;
      if (sn != '0' &&
          sn.isNotEmpty &&
          !['mock-bengle', 'mock-de1'].contains(sn)) {
        unawaited(_checkSerialOwnership(sn));
      }
    } else {
      _logger.info('DE1 disconnected');
      _cleanupShotSequencer();
    }
  }

  /// Verifies that [serial] belongs to the logged-in Decent account.
  /// If not, emails tech support - matching the
  /// de1app behavior in `fetch_decent_de1_serial_numbers_for_current_login`.
  Future<void> _checkSerialOwnership(String serial) async {
    if (!DecentAccountService.kEnableSerialVerification) return;
    final account = _accountService;
    if (account == null) return;

    try {
      final isLoggedIn = await account.isLoggedIn();
      if (!isLoggedIn) return;

      final owns = await account.verifyMachineSerial(serial);
      if (owns) return;

      _logger.warning(
        'Machine serial $serial not in account — emailing support',
      );
      if (_emailedSerials.contains(serial)) return;
      _emailedSerials.add(serial);
      try {
        await account.emailSerialMismatch(serial);
        _logger.info('Emailed support about unassociated serial $serial');
      } catch (e) {
        _emailedSerials.remove(serial);
        _logger.warning('Failed to email serial mismatch: $e');
      }
    } catch (e) {
      _logger.warning('Serial ownership check failed: $e');
    }
  }

  /// Handles machine snapshot updates and triggers appropriate actions
  /// based on the machine state and gateway mode.
  void _handleSnapshot(MachineSnapshot snapshot) {
    _latestSnapshot = snapshot;
    final gatewayMode = _settingsController.gatewayMode;
    final currentState = snapshot.state.state;
    final currentSubstate = snapshot.state.substate;

    if (_previousMachineState == currentState) {
      return;
    }

    _logger.fine(
      'Handling state: $currentState, substate: $currentSubstate in mode: ${gatewayMode.name} (app foreground: $_appIsInForeground, platform: ${Platform.operatingSystem})',
    );

    _handleScalePowerManagement(currentState);

    if (!_navigationContextReady) {
      _checkNavigationContext();
    }

    switch (currentState) {
      case MachineState.espresso:
        _handleEspressoState(snapshot, gatewayMode);
        break;
      case MachineState.steam:
        _handleSteamState(snapshot, gatewayMode);
        break;
      default:
        break;
    }

    _previousMachineState = currentState;
  }

  /// Handles scale power management and auto-reconnect based on machine
  /// state transitions.
  void _handleScalePowerManagement(MachineState currentState) {
    if (_previousMachineState == null) {
      return;
    }

    if (_previousMachineState == currentState) {
      return;
    }

    final scalePowerMode = _settingsController.scalePowerMode;

    if (scalePowerMode != ScalePowerMode.disabled &&
        _previousMachineState == MachineState.idle &&
        currentState == MachineState.sleeping) {
      _logger.info(
        'Machine going to sleep, managing scale power (mode: ${scalePowerMode.name})',
      );

      try {
        final scale = _scaleController.connectedScale();

        if (scalePowerMode == ScalePowerMode.displayOff) {
          scale.sleepDisplay().catchError((e) {
            _logger.warning('Failed to sleep scale display: $e');
          });
        } else if (scalePowerMode == ScalePowerMode.disconnect) {
          _connectionManager.markExpectingDisconnect(scale.deviceId);
          scale.disconnect().catchError((e) {
            _logger.warning('Failed to disconnect scale: $e');
          });
        }
      } catch (e) {
        _logger.finest('Scale not connected, skipping power management: $e');
      }
    }

    if (_previousMachineState == MachineState.sleeping &&
        currentState != MachineState.sleeping) {
      _logger.info('Machine waking up from sleep');

      bool scaleConnected = false;
      try {
        _scaleController.connectedScale();
        scaleConnected = true;
      } catch (e) {
        scaleConnected = false;
      }

      if (scaleConnected && scalePowerMode == ScalePowerMode.displayOff) {
        try {
          final scale = _scaleController.connectedScale();
          scale.wakeDisplay().catchError((e) {
            _logger.warning('Failed to wake scale display: $e');
          });
        } catch (e) {
          _logger.warning('Failed to get scale for wake: $e');
        }
      }

      if (!scaleConnected) {
        _logger.info(
          'Scale disconnected after sleep, deferring scan 3s '
          'to avoid BLE radio starvation',
        );
        _deferredScaleScan?.cancel();
        _deferredScaleScan = Timer(deferredScaleScanDelay, () {
          _deferredScaleScan = null;
          if (_connectionManager.supportsBackgroundScaleWatch &&
              _settingsController.preferredScaleId != null) {
            _logger.fine(
              'Background scale watch handles reacquisition; '
              'skipping wake burst',
            );
            return;
          }
          _triggerScaleScan();
        });
      }
    }
  }

  /// Triggers a scale-only scan via ConnectionManager.
  void _triggerScaleScan() {
    _logger.info('Delegating scale reconnect to ConnectionManager');
    _connectionManager.connect(scaleOnly: true);
  }

  /// Handles espresso state based on the current gateway mode.
  ///
  /// If the home screen is active and the app is in the foreground, navigates
  /// to the realtime shot feature regardless of gateway mode. Otherwise, falls
  /// back to gateway-mode-specific behavior.
  void _handleEspressoState(MachineSnapshot snapshot, GatewayMode gatewayMode) {
    if (_appIsInForeground && _isLauncherActive) {
      _handleDisabledModeForEspresso();
      return;
    }

    switch (gatewayMode) {
      case GatewayMode.full:
        return;
      case GatewayMode.tracking:
        _handleTrackingModeForEspresso();
        break;
      case GatewayMode.disabled:
        _handleDisabledModeForEspresso();
        break;
    }
  }

  /// Handles steam state based on the current gateway mode.
  ///
  /// If the launcher is active and the app is in the foreground, navigates
  /// to the realtime steam feature regardless of gateway mode. Otherwise, falls
  /// back to gateway-mode-specific behavior.
  void _handleSteamState(MachineSnapshot snapshot, GatewayMode gatewayMode) {
    if (_appIsInForeground && _isLauncherActive) {
      _handleDisabledModeForSteam();
      return;
    }

    switch (gatewayMode) {
      case GatewayMode.full:
      case GatewayMode.tracking:
        // In full or tracking mode, do nothing for steam
        return;
      case GatewayMode.disabled:
        _handleDisabledModeForSteam();
        break;
    }
  }

  /// Handles espresso state when in tracking mode.
  void _handleTrackingModeForEspresso() {
    if (_currentShotSequencer != null) {
      return;
    }

    _logger.info(
      'Starting shot tracking in tracking mode (app foreground: $_appIsInForeground)',
    );
    _startShotSequencer();
  }

  /// Handles espresso state when in disabled mode.
  void _handleDisabledModeForEspresso() {
    if (_isRealtimeFeatureActive) {
      return;
    }

    if (_currentShotSequencer != null) {
      return;
    }

    _startShotSequencer();

    bool canNavigate = _navigationContextReady;

    if (Platform.isAndroid || Platform.isIOS) {
      canNavigate = canNavigate && _appIsInForeground;
    }

    if (canNavigate) {
      final context = _navigatorKey.currentContext;
      if (context != null && context.mounted) {
        _logger.info(
          'Navigating to RealtimeShotFeature in disabled mode (platform: ${Platform.operatingSystem})',
        );
        _isRealtimeFeatureActive = true;

        Navigator.pushNamed(
              context,
              RealtimeShotFeature.routeName,
              arguments: _currentShotSequencer,
            )
            .then((_) {
              _isRealtimeFeatureActive = false;
            })
            .catchError((error) {
              _logger.warning('Navigation failed: $error');
              _isRealtimeFeatureActive = false;
            });
      } else {
        _logger.warning(
          'Navigation context not available, tracking shot in background',
        );
        _navigationContextReady = false;
      }
    } else {
      _logger.info(
        'Cannot navigate (foreground: $_appIsInForeground, context: $_navigationContextReady), tracking shot in background',
      );
    }
  }

  /// Handles steam state when in disabled mode.
  void _handleDisabledModeForSteam() {
    if (_isRealtimeFeatureActive) {
      return;
    }

    bool canNavigate = _navigationContextReady;

    if (Platform.isAndroid || Platform.isIOS) {
      canNavigate = canNavigate && _appIsInForeground;
    }

    if (!canNavigate) {
      _logger.fine(
        'Skipping steam feature - cannot navigate (platform: ${Platform.operatingSystem}, foreground: $_appIsInForeground, context: $_navigationContextReady)',
      );
      return;
    }

    final context = _navigatorKey.currentContext;
    if (context != null && context.mounted) {
      _logger.info('Navigating to RealtimeSteamFeature in disabled mode');
      _isRealtimeFeatureActive = true;

      try {
        _de1Controller.steamData.first
            .then((steamData) {
              if (!context.mounted) {
                _logger.warning('Context no longer mounted');
                _isRealtimeFeatureActive = false;
                return;
              }
              Navigator.pushNamed(
                context,
                RealtimeSteamFeature.routeName,
                arguments: {'controller': _de1Controller, 'data': steamData},
              ).then((_) {
                _isRealtimeFeatureActive = false;
              });
            })
            .catchError((error, stackTrace) {
              _logger.warning('Error getting steam data: $error');
              _isRealtimeFeatureActive = false;
            });
      } catch (e) {
        _logger.warning('Error in steam navigation: $e');
        _isRealtimeFeatureActive = false;
      }
    } else {
      _logger.warning('Navigation context is null or not mounted');
      _navigationContextReady = false;
    }
  }

  /// Starts a new ShotSequencer for tracking a shot in tracking mode.
  void _startShotSequencer() {
    _logger.fine('Creating new ShotSequencer for tracking');

    // Cleaning/calibration pulls have no yield to weigh, so the no-scale guard
    // must not abort them — same carve-out the persistence path already makes.
    final beverageType =
        _workflowController.currentWorkflow.profile.beverageType;
    final scalelessBeverage =
        beverageType == BeverageType.cleaning ||
        beverageType == BeverageType.calibrate;

    _currentShotSequencer = ShotSequencer(
      scaleController: _scaleController,
      de1controller: _de1Controller,
      persistenceController: _persistenceController,
      targetProfile: _workflowController.currentWorkflow.profile,
      targetYield:
          _workflowController.currentWorkflow.context?.targetYield ?? 0,
      bypassSAW: _settingsController.gatewayMode == GatewayMode.full,
      blockOnNoScale: _settingsController.blockOnNoScale && !scalelessBeverage,
      weightFlowMultiplier: _settingsController.weightFlowMultiplier,
      volumeFlowMultiplier: _settingsController.volumeFlowMultiplier,
      stepExitArbiterEnabled: _settingsController.isFeatureFlagEnabled(
        FeatureFlag.stepExitArbiter,
      ),
    );

    _currentShotSnapshots.clear();
    _currentShotId = Uuid().v4();

    _shotSnapshotsSubscription = _currentShotSequencer!.shotData.listen((
      snapshot,
    ) {
      _currentShotSnapshots.add(snapshot);
    });

    _shotStateSubscription = _currentShotSequencer!.state.listen((state) {
      if (state != ShotState.idle) {
        _publishShotStateFrame(state);
      }
      if (state == ShotState.finished) {
        _logger.fine('Shot finished, cleaning up ShotSequencer');
        _persistShotIfNeeded();
        _cleanupShotSequencer();
      }
    });

    _shotDecisionSubscription = _currentShotSequencer!.decisions.listen((
      decision,
    ) {
      _publishShotDecisionFrame(decision);
      if (decision.kind == ShotDecisionKind.abort) {
        _logger.info(
          'Shot aborted (${decision.reason.name}), cleaning up '
          'ShotSequencer without persisting',
        );
        _cleanupShotSequencer(emitTerminal: false);
      }
    });
  }

  bool get _isScaleConnected =>
      _scaleController.currentConnectionState ==
      device.ConnectionState.connected;

  /// Publishes a state frame for the tracked shot onto
  /// De1Controller.shotState.
  ///
  /// Frames are stamped with the triggering machine snapshot's timestamp (not
  /// publish time) so clients can align them with `/ws/v1/machine/snapshot`
  /// telemetry — the event describes that snapshot's moment, and publish time
  /// lags it by a variable processing delay.
  void _publishShotStateFrame(ShotState state) {
    final sequencer = _currentShotSequencer;
    _de1Controller.publishShotEvent(
      ShotStateEvent(
        event: 'state',
        timestamp: _latestSnapshot?.timestamp ?? clock.now(),
        shotId: _currentShotId,
        state: state,
        machineState: _latestSnapshot?.state.state,
        machineSubstate: _latestSnapshot?.state.substate,
        profileFrame: _latestSnapshot?.profileFrame,
        scaleConnected: _isScaleConnected,
        scaleLost: sequencer?.scaleLost ?? false,
        machineHasAutonomousSAW: sequencer?.machineHasAutonomousSAW ?? false,
      ),
    );
  }

  /// Publishes a decision (or terminal) frame for the tracked shot onto
  /// De1Controller.shotState. Stamped with the triggering snapshot's
  /// timestamp — see [_publishShotStateFrame].
  void _publishShotDecisionFrame(ShotDecision decision) {
    final sequencer = _currentShotSequencer;
    _de1Controller.publishShotEvent(
      ShotStateEvent(
        event: decision.kind == ShotDecisionKind.terminal
            ? 'terminal'
            : 'decision',
        timestamp: _latestSnapshot?.timestamp ?? clock.now(),
        shotId: _currentShotId,
        state: sequencer?.currentState ?? ShotState.idle,
        machineState: _latestSnapshot?.state.state,
        machineSubstate: _latestSnapshot?.state.substate,
        profileFrame: _latestSnapshot?.profileFrame,
        scaleConnected: _isScaleConnected,
        scaleLost: sequencer?.scaleLost ?? false,
        machineHasAutonomousSAW: sequencer?.machineHasAutonomousSAW ?? false,
        decision: decision,
      ),
    );
  }

  /// Persists the shot if it's not a cleaning or calibration shot.
  void _persistShotIfNeeded() {
    final beverageType =
        _workflowController.currentWorkflow.profile.beverageType;
    if (beverageType == BeverageType.cleaning ||
        beverageType == BeverageType.calibrate ||
        _currentShotSequencer == null) {
      return;
    }

    final measurements = List<ShotSnapshot>.from(_currentShotSnapshots);
    final baseWorkflow = _workflowController.currentWorkflow;
    final startTime = _currentShotSequencer!.shotStartTime;

    double? flowCalibration;
    try {
      flowCalibration = _de1Controller.connectedDe1().cachedFlowEstimation;
    } catch (e) {
      _logger.warning('Could not read flow calibration for shot: $e');
    }
    final workflow = flowCalibration != null
        ? baseWorkflow.copyWith(
            id: baseWorkflow.id,
            machine: WorkflowMachine(flowCalibration: flowCalibration),
          )
        : baseWorkflow;

    _persistenceController.persistShot(
      ShotRecord(
        id: _currentShotId ?? Uuid().v4(),
        timestamp: startTime,
        measurements: measurements,
        workflow: workflow,
        stopReason: _currentShotSequencer!.finalStopReason?.name,
        annotations: ShotAnnotations.deriveForFinishedShot(
          measurements: measurements,
          targetDoseWeight: baseWorkflow.context?.targetDoseWeight,
          preferredYield: _currentShotSequencer!.trustedFinalYield,
        ),
      ),
    );
  }

  /// Cleans up the current ShotSequencer and all associated subscriptions.
  ///
  /// Terminal-frame contract: when the sequencer is torn down mid-shot with no
  /// decision of its own (machine disconnect, manager dispose) and
  /// [emitTerminal] is true, a `terminal/disconnected` frame is published
  /// first — the sequencer's own streams close silently on dispose, and
  /// without this shotState clients would hang on a stale `pouring` frame.
  /// The abort path passes `emitTerminal: false` because the abort decision it
  /// already emitted is the terminal signal. The feed is re-seeded with an
  /// idle frame either way.
  void _cleanupShotSequencer({bool emitTerminal = true}) {
    _logger.fine('Cleaning up ShotSequencer');

    final sequencer = _currentShotSequencer;
    final midShot =
        emitTerminal &&
        sequencer != null &&
        sequencer.currentState != ShotState.idle &&
        sequencer.currentState != ShotState.finished;
    if (midShot) {
      _logger.warning(
        'ShotSequencer torn down mid-shot '
        '(${sequencer.currentState.name}) — publishing terminal frame',
      );
      _publishShotDecisionFrame(
        const ShotDecision(
          kind: ShotDecisionKind.terminal,
          reason: ShotDecisionReason.disconnected,
          details: 'Shot tracking torn down mid-shot',
        ),
      );
    }

    _shotStateSubscription?.cancel();
    _shotStateSubscription = null;

    _shotSnapshotsSubscription?.cancel();
    _shotSnapshotsSubscription = null;

    _shotDecisionSubscription?.cancel();
    _shotDecisionSubscription = null;

    _currentShotSequencer?.dispose();
    _currentShotSequencer = null;

    _currentShotSnapshots.clear();

    if (_currentShotId != null) {
      _currentShotId = null;
      _publishIdleFrame();
    }
  }

  /// Re-seeds the shotState feed with an idle (between-shots) frame carrying
  /// the real resting scale/machine context, so a client attaching between
  /// shots sees accurate `scaleConnected`/`machineHasAutonomousSAW` rather
  /// than the bare `ShotStateEvent.idle()` defaults.
  void _publishIdleFrame() {
    _de1Controller.publishShotEvent(
      ShotStateEvent(
        event: 'state',
        timestamp: clock.now(),
        state: ShotState.idle,
        machineState: _latestSnapshot?.state.state,
        machineSubstate: _latestSnapshot?.state.substate,
        scaleConnected: _isScaleConnected,
        machineHasAutonomousSAW: _machineHasAutonomousSAW,
      ),
    );
  }

  /// Whether the connected machine runs its own stop-at-weight (Bengle).
  /// Static capability, so it holds between shots too.
  bool get _machineHasAutonomousSAW {
    try {
      return _de1Controller.connectedDe1() is BengleInterface;
    } catch (_) {
      return false;
    }
  }

  /// Disposes all subscriptions and cleans up resources.
  void dispose() {
    _logger.fine('Disposing De1StateManager');

    WidgetsBinding.instance.removeObserver(this);

    _cleanupShotSequencer();

    _deferredScaleScan?.cancel();
    _deferredScaleScan = null;

    _snapshotSubscription?.cancel();
    _snapshotSubscription = null;

    _de1Subscription?.cancel();
    _de1Subscription = null;
  }
}
