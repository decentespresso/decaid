import 'dart:io';
import 'dart:async';
import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:logging/logging.dart';
import 'package:reaprime/src/account/account_page.dart';
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
import 'package:reaprime/src/models/device/impl/de1/de1.models.dart';
import 'package:reaprime/src/models/device/impl/de1/unified_de1/unified_de1.dart';
import 'package:reaprime/src/models/device/machine.dart';
import 'package:reaprime/src/realtime_shot_feature/realtime_shot_feature.dart';
import 'package:reaprime/src/realtime_steam_feature/realtime_steam_feature.dart';
import 'package:reaprime/src/launcher/launcher_view.dart';
import 'package:reaprime/src/services/account/decent_account_service.dart';
import 'package:reaprime/src/services/account/legacy_de1_identity_resolver.dart';
import 'package:reaprime/src/services/account/registered_decent_machine.dart';
import 'package:reaprime/src/settings/feature_flags.dart';
import 'package:reaprime/src/settings/gateway_mode.dart';
import 'package:reaprime/src/settings/scale_power_mode.dart';
import 'package:reaprime/src/settings/settings_controller.dart';
import 'package:uuid/uuid.dart';

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
  StreamSubscription<void>? _accountIdentitySubscription;
  final _emailedSerials = <String>{};
  final LegacyDe1IdentityResolver _identityResolver =
      const LegacyDe1IdentityResolver();
  final Set<UnifiedDe1> _identityPromptedMachines = {};
  int _identityRevision = 0;
  ({int connection, int identity})? _identityResolving;
  NavigatorState? _identityDialogNavigator;
  Route<dynamic>? _identityDialogRoute;
  bool _disposed = false;
  StreamSubscription<MachineSnapshot>? _snapshotSubscription;
  ShotSequencer? _currentShotSequencer;
  StreamSubscription<ShotState>? _shotStateSubscription;
  StreamSubscription<ShotSnapshot>? _shotSnapshotsSubscription;
  StreamSubscription<ShotDecision>? _shotDecisionSubscription;

  String? _currentShotId;
  WorkflowMachine? _currentShotMachine;

  MachineSnapshot? _latestSnapshot;

  bool _isRealtimeFeatureActive = false;
  final List<ShotSnapshot> _currentShotSnapshots = [];

  MachineState? _previousMachineState;

  Timer? _deferredScaleScan;

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

  void _initialize() {
    WidgetsBinding.instance.addObserver(this);

    _checkNavigationContext();

    _accountIdentitySubscription = _accountService?.identityAuthorityChanges
        .listen(_handleIdentityAuthorityChange);
    _de1Subscription = _de1Controller.de1.listen(_handleDe1Change);

    WidgetsBinding.instance.addPostFrameCallback(
      _retryIdentityWhenNavigationReady,
    );
  }

  void _retryIdentityWhenNavigationReady(Duration _) {
    if (_disposed) return;
    _checkNavigationContext();
    if (!_navigationContextReady) {
      WidgetsBinding.instance.addPostFrameCallback(
        _retryIdentityWhenNavigationReady,
      );
      return;
    }
    unawaited(_retryPendingIdentityResolution());
  }

  void _checkNavigationContext() {
    final context = _navigatorKey.currentContext;
    _navigationContextReady = context != null && context.mounted;
    _logger.fine('Navigation context ready: $_navigationContextReady');
  }

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

  bool get _isAppInBackground => _backgroundStates.contains(_currentAppState);

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
      unawaited(_retryPendingIdentityResolution());
    }
    if (!Platform.isAndroid && !Platform.isIOS) {
      _logger.fine(
        'Desktop platform state change: ${state.name}, ensuring navigation context',
      );
      _checkNavigationContext();
    }
  }

  void _handleDe1Change(Machine? machine) {
    _identityRevision++;
    if (machine == null) _dismissIdentityDialog();
    _snapshotSubscription?.cancel();
    _snapshotSubscription = null;
    _identityPromptedMachines.clear();

    if (machine != null) {
      _logger.info('DE1 connected, starting to listen for state changes');
      _snapshotSubscription = machine.currentSnapshot.listen(_handleSnapshot);

      final isLegacyDe1 =
          machine is UnifiedDe1 &&
          !isBengleModelValue(machine.rawModelValue ?? 0);
      if (isLegacyDe1 && _accountService != null) {
        unawaited(_resolveLegacyIdentity(machine));
      } else {
        _maybeCheckSerialOwnership(machine.machineInfo.serialNumber);
      }
    } else {
      _logger.info('DE1 disconnected');
      _cleanupShotSequencer();
    }
  }

  void _handleIdentityAuthorityChange(void _) {
    _identityRevision++;
    _dismissIdentityDialog();
    _identityPromptedMachines.clear();
    final machine = _de1Controller.connectedDe1OrNull;
    if (machine is! UnifiedDe1 ||
        isBengleModelValue(machine.rawModelValue ?? 0)) {
      return;
    }
    machine.clearEffectiveIdentity();
    if (_accountService?.hasLinkedCredentials == true) {
      unawaited(_resolveLegacyIdentity(machine));
    }
  }

  void _maybeCheckSerialOwnership(String serial) {
    if (serial != '0' &&
        serial.isNotEmpty &&
        !['mock-bengle', 'mock-de1'].contains(serial)) {
      unawaited(_checkSerialOwnership(serial));
    }
  }

  bool _stillCurrent(
    UnifiedDe1 machine, [
    ({int connection, int identity})? revision,
  ]) =>
      !_disposed &&
      (revision == null ||
          (revision.connection == _de1Controller.connectionGeneration &&
              revision.identity == _identityRevision)) &&
      identical(machine, _de1Controller.connectedDe1OrNull);

  Future<void> _retryPendingIdentityResolution() {
    if (_disposed) return Future.value();
    final machine = _de1Controller.connectedDe1OrNull;
    if (machine is! UnifiedDe1 || !_stillCurrent(machine)) {
      return Future.value();
    }
    if (_accountService == null) return Future.value();
    final rawInfo = machine.rawMachineInfo;
    final rawSerial = rawInfo.serialNumber;
    final rawModelValue = machine.rawModelValue ?? 0;
    final effective = machine.machineInfo;
    final needsIdentity =
        (rawSerial == '0' && effective.serialNumber == rawSerial) ||
        (rawModelValue == 0 && effective.model == rawInfo.model);
    if (!needsIdentity) return Future.value();
    return _resolveLegacyIdentity(machine);
  }

  Future<void> _resolveLegacyIdentity(
    UnifiedDe1 machine, {
    bool allowPrompts = true,
  }) async {
    final revision = (
      connection: _de1Controller.connectionGeneration,
      identity: _identityRevision,
    );
    if (!_stillCurrent(machine, revision)) return;
    if (isBengleModelValue(machine.rawModelValue ?? 0)) return;
    if (allowPrompts) {
      if (_identityResolving == revision) return;
      _identityResolving = revision;
    }
    try {
      final account = _accountService!;
      await account.accountReady;
      if (!_stillCurrent(machine, revision)) return;
      final rawInfo = machine.rawMachineInfo;
      final rawSerial = rawInfo.serialNumber;
      final rawModelValue = machine.rawModelValue ?? 0;

      RegisteredDecentMachine? mapped;
      if (rawSerial == '0' && !await account.isAuthKnownInvalid()) {
        mapped = await account.lookupMapping(
          transportType: machine.transportType.name,
          deviceId: machine.deviceId,
        );
      }
      if (!_stillCurrent(machine, revision)) return;

      final resolution = _identityResolver.resolve(
        rawSerial: rawSerial,
        rawModelValue: rawModelValue,
        registeredMachines: account.usableRegisteredMachines,
        mappedMachine: mapped,
      );

      switch (resolution) {
        case ResolvedLegacyDe1Identity():
          _logger.info('Legacy DE1 identity resolved from account records');
          await _applyResolvedIdentity(
            machine,
            resolution.machine,
            persistMapping: false,
            revision: revision,
          );
        case AmbiguousLegacyDe1Identity():
          if (!allowPrompts) break;
          final selected = await _promptMachineSelection(
            machine,
            resolution.candidates,
            revision,
          );
          if (selected != null && _stillCurrent(machine, revision)) {
            await _applyResolvedIdentity(
              machine,
              selected,
              persistMapping: true,
              revision: revision,
            );
          }
        case UnavailableLegacyDe1Identity():
          if (rawSerial.isNotEmpty && rawSerial != '0') {
            _maybeCheckSerialOwnership(rawSerial);
          }
          if (allowPrompts && (rawSerial == '0' || rawModelValue == 0)) {
            await _maybePromptLinkAccount(machine, revision);
          }
      }
    } catch (e, st) {
      _logger.warning('Legacy DE1 identity resolution failed', e, st);
    } finally {
      if (allowPrompts && _identityResolving == revision) {
        _identityResolving = null;
      }
    }
  }

  Future<void> _applyResolvedIdentity(
    UnifiedDe1 machine,
    RegisteredDecentMachine record, {
    required bool persistMapping,
    required ({int connection, int identity}) revision,
  }) async {
    if (!_stillCurrent(machine, revision)) return;
    final model = record.recognizedModel?.name ?? machine.rawMachineInfo.model;
    machine.applyEffectiveIdentity(serial: record.serial, model: model);
    _de1Controller.recordResolvedSerial(record.serial);
    if (persistMapping) {
      final account = _accountService;
      if (account != null) {
        try {
          await account.saveMapping(
            transportType: machine.transportType.name,
            deviceId: machine.deviceId,
            serial: record.serial,
          );
        } catch (e) {
          _logger.warning('Failed to persist identity mapping: $e');
        }
      }
    }
  }

  Future<RegisteredDecentMachine?> _promptMachineSelection(
    UnifiedDe1 machine,
    List<RegisteredDecentMachine> candidates,
    ({int connection, int identity}) revision,
  ) async {
    if (!_stillCurrent(machine, revision)) return null;
    if (_identityPromptedMachines.contains(machine)) return null;
    if (!_appIsInForeground) return null;
    final context = _navigatorKey.currentContext;
    if (context == null || !context.mounted) return null;
    _identityPromptedMachines.add(machine);
    return _showIdentityDialog<RegisteredDecentMachine>(
      context: context,
      builder: (dialogContext) {
        return SimpleDialog(
          title: const Text('Select your machine'),
          children: [
            for (final candidate in candidates)
              SimpleDialogOption(
                onPressed: () => Navigator.of(dialogContext).pop(candidate),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Text(
                    '${candidate.serial} · '
                    '${candidate.recognizedModel?.displayName ?? 'Unknown'}'
                    '${candidate.rawSku.isEmpty ? '' : ' · ${candidate.rawSku}'}',
                  ),
                ),
              ),
            SimpleDialogOption(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Cancel'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _maybePromptLinkAccount(
    UnifiedDe1 machine,
    ({int connection, int identity}) revision,
  ) async {
    final account = _accountService;
    if (account == null || !_stillCurrent(machine, revision)) return;
    final linked = await account.hasLinkedAccount();
    final authInvalid = await account.isAuthKnownInvalid();
    if (!_stillCurrent(machine, revision)) return;
    if (linked && !authInvalid) return;
    if (_identityPromptedMachines.contains(machine)) return;
    if (!_appIsInForeground) return;
    final context = _navigatorKey.currentContext;
    if (context == null || !context.mounted) return;
    _identityPromptedMachines.add(machine);
    final accepted = await _showIdentityDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('Link your Decent account'),
          content: const Text(
            'This machine does not report a serial number or machine model. '
            'Link your Decent account so Decaid can identify it.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Not now'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('Link account'),
            ),
          ],
        );
      },
    );
    if (accepted != true) return;
    if (!_stillCurrent(machine, revision)) return;
    final navigator = _navigatorKey.currentState;
    if (navigator == null) return;
    await navigator.pushNamed(AccountPage.routeName);
    if (!_stillCurrent(machine, revision)) return;
    final nowLinked = await account.hasLinkedAccount();
    final nowInvalid = await account.isAuthKnownInvalid();
    if (!_stillCurrent(machine, revision)) return;
    if (!nowLinked || nowInvalid) return;
    _identityPromptedMachines.remove(machine);
    _identityResolving = null;
    await _resolveLegacyIdentity(machine);
  }

  Future<T?> _showIdentityDialog<T>({
    required BuildContext context,
    required WidgetBuilder builder,
  }) async {
    final navigator = Navigator.of(context, rootNavigator: true);
    final route = DialogRoute<T>(
      context: context,
      builder: builder,
      themes: InheritedTheme.capture(from: context, to: navigator.context),
    );
    _identityDialogNavigator = navigator;
    _identityDialogRoute = route;
    try {
      return await navigator.push(route);
    } finally {
      if (identical(_identityDialogRoute, route)) {
        _identityDialogNavigator = null;
        _identityDialogRoute = null;
      }
    }
  }

  void _dismissIdentityDialog() {
    final navigator = _identityDialogNavigator;
    final route = _identityDialogRoute;
    _identityDialogNavigator = null;
    _identityDialogRoute = null;
    if (navigator != null && navigator.mounted && route?.isActive == true) {
      navigator.removeRoute(route!);
    }
  }

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

  void _triggerScaleScan() {
    _logger.info('Delegating scale reconnect to ConnectionManager');
    _connectionManager.connect(scaleOnly: true);
  }

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

  void _handleSteamState(MachineSnapshot snapshot, GatewayMode gatewayMode) {
    if (_appIsInForeground && _isLauncherActive) {
      _handleDisabledModeForSteam();
      return;
    }

    switch (gatewayMode) {
      case GatewayMode.full:
      case GatewayMode.tracking:
        return;
      case GatewayMode.disabled:
        _handleDisabledModeForSteam();
        break;
    }
  }

  void _handleTrackingModeForEspresso() {
    if (_currentShotSequencer != null) {
      return;
    }

    _logger.info(
      'Starting shot tracking in tracking mode (app foreground: $_appIsInForeground)',
    );
    _startShotSequencer();
  }

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

  void _startShotSequencer() {
    _logger.fine('Creating new ShotSequencer for tracking');

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
    _currentShotMachine = _captureMachineSnapshot();

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

    final workflow = baseWorkflow.copyWith(
      id: baseWorkflow.id,
      machine: _currentShotMachine,
      clearMachine: _currentShotMachine == null,
    );

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

  WorkflowMachine? _captureMachineSnapshot() {
    try {
      final de1 = _de1Controller.connectedDe1();
      final info = de1.machineInfo;
      return WorkflowMachine(
        provenanceStatus: WorkflowMachineProvenanceStatus.captured,
        flowCalibration: de1.cachedFlowEstimation,
        serialNumber: info.serialNumber,
        model: info.model,
        firmwareVersion: info.version,
      );
    } catch (e) {
      _logger.warning('Could not read machine snapshot for shot: $e');
      return const WorkflowMachine(
        provenanceStatus: WorkflowMachineProvenanceStatus.unavailable,
      );
    }
  }

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
    _currentShotMachine = null;

    if (_currentShotId != null) {
      _currentShotId = null;
      _publishIdleFrame();
    }
  }

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

  bool get _machineHasAutonomousSAW {
    try {
      return _de1Controller.connectedDe1() is BengleInterface;
    } catch (_) {
      return false;
    }
  }

  void dispose() {
    _disposed = true;
    _logger.fine('Disposing De1StateManager');

    _dismissIdentityDialog();

    WidgetsBinding.instance.removeObserver(this);

    _cleanupShotSequencer();

    _deferredScaleScan?.cancel();
    _deferredScaleScan = null;

    _snapshotSubscription?.cancel();
    _snapshotSubscription = null;

    _de1Subscription?.cancel();
    _de1Subscription = null;

    _accountIdentitySubscription?.cancel();
    _accountIdentitySubscription = null;
  }
}
