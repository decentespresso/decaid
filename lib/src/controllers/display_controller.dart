import 'dart:async';
import 'dart:io';

import 'package:logging/logging.dart';
import 'package:reaprime/src/controllers/charging_logic.dart';
import 'package:reaprime/src/controllers/de1_controller.dart';
import 'package:reaprime/src/models/device/de1_interface.dart';
import 'package:reaprime/src/models/device/machine.dart';
import 'package:reaprime/src/settings/settings_controller.dart';
import 'package:rxdart/subjects.dart';
import 'package:screen_brightness/screen_brightness.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

class DisplayPlatformSupport {
  final bool brightness;
  final bool wakeLock;

  const DisplayPlatformSupport({
    required this.brightness,
    required this.wakeLock,
  });

  Map<String, dynamic> toJson() => {
    'brightness': brightness,
    'wakeLock': wakeLock,
  };
}

class DisplayState {
  final bool wakeLockEnabled;
  final bool wakeLockOverride;
  final int brightness;
  final int requestedBrightness;
  final bool lowBatteryBrightnessActive;
  final DisplayPlatformSupport platformSupported;

  const DisplayState({
    required this.wakeLockEnabled,
    required this.wakeLockOverride,
    required this.brightness,
    required this.requestedBrightness,
    required this.lowBatteryBrightnessActive,
    required this.platformSupported,
  });

  DisplayState copyWith({
    bool? wakeLockEnabled,
    bool? wakeLockOverride,
    int? brightness,
    int? requestedBrightness,
    bool? lowBatteryBrightnessActive,
    DisplayPlatformSupport? platformSupported,
  }) => DisplayState(
    wakeLockEnabled: wakeLockEnabled ?? this.wakeLockEnabled,
    wakeLockOverride: wakeLockOverride ?? this.wakeLockOverride,
    brightness: brightness ?? this.brightness,
    requestedBrightness: requestedBrightness ?? this.requestedBrightness,
    lowBatteryBrightnessActive:
        lowBatteryBrightnessActive ?? this.lowBatteryBrightnessActive,
    platformSupported: platformSupported ?? this.platformSupported,
  );

  Map<String, dynamic> toJson() => {
    'wakeLockEnabled': wakeLockEnabled,
    'wakeLockOverride': wakeLockOverride,
    'brightness': brightness,
    'requestedBrightness': requestedBrightness,
    'lowBatteryBrightnessActive': lowBatteryBrightnessActive,
    'platformSupported': platformSupported.toJson(),
  };
}

/// Manages screen wake-lock and brightness.
///
/// Two concerns:
/// 1. **Wake-lock** — auto-managed based on machine state (enabled when
///    connected and not sleeping, released on sleep/disconnect). The
///    `keepAwake` setting forces the wake-lock on while the app runs. Skins
///    can override via [requestWakeLock] / [releaseWakeLock].
/// 2. **Brightness** — 0-100 integer range via [setBrightness]. Value 100
///    resets to OS-managed brightness. Battery-aware cap reduces brightness
///    when battery is low and the setting is enabled.
class DisplayController {
  final De1Controller _de1Controller;
  final SettingsController _settingsController;
  final Logger _log = Logger('DisplayController');

  static const int _lowBatteryThreshold = 30;
  static const int _lowBatteryBrightnessCap = 20;
  static final ScreenBrightness _defaultScreenBrightness = ScreenBrightness();

  final Future<void> Function(double) _setBrightness;
  final Future<void> Function() _resetBrightness;
  final Future<void> Function() _enableWakeLock;
  final Future<void> Function() _disableWakeLock;

  late final DisplayPlatformSupport _platformSupport;

  late final BehaviorSubject<DisplayState> _stateSubject;
  Stream<DisplayState> get state => _stateSubject.stream;
  DisplayState get currentState => _stateSubject.value;

  De1Interface? _de1;
  MachineState? _currentMachineState;
  StreamSubscription<De1Interface?>? _de1Subscription;
  StreamSubscription<MachineSnapshot>? _snapshotSubscription;
  bool _wakeLockOverride = false;

  int _requestedBrightness = 100;
  int _preSleepBrightness = 100;

  final Stream<ChargingState>? _batteryStateStream;
  StreamSubscription<ChargingState>? _batterySubscription;
  int? _lastBatteryPercent;

  DisplayController({
    required De1Controller de1Controller,
    required SettingsController settingsController,
    Stream<ChargingState>? batteryStateStream,
    Future<void> Function(double)? setBrightness,
    Future<void> Function()? resetBrightness,
    Future<void> Function()? enableWakeLock,
    Future<void> Function()? disableWakeLock,
    DisplayPlatformSupport? platformSupport,
  }) : _de1Controller = de1Controller,
       _settingsController = settingsController,
       _batteryStateStream = batteryStateStream,
       _setBrightness =
           setBrightness ??
           _defaultScreenBrightness.setApplicationScreenBrightness,
       _resetBrightness =
           resetBrightness ??
           _defaultScreenBrightness.resetApplicationScreenBrightness,
       _enableWakeLock = enableWakeLock ?? WakelockPlus.enable,
       _disableWakeLock = disableWakeLock ?? WakelockPlus.disable {
    _platformSupport =
        platformSupport ??
        DisplayPlatformSupport(
          brightness:
              Platform.isAndroid ||
              Platform.isIOS ||
              Platform.isMacOS ||
              Platform.isWindows,
          wakeLock: true,
        );

    _stateSubject = BehaviorSubject.seeded(
      DisplayState(
        wakeLockEnabled: false,
        wakeLockOverride: false,
        brightness: 100,
        requestedBrightness: 100,
        lowBatteryBrightnessActive: false,
        platformSupported: _platformSupport,
      ),
    );
  }

  void initialize() {
    _de1Subscription = _de1Controller.de1.listen(_onDe1Changed);
    _batterySubscription = _batteryStateStream?.listen(_onBatteryChanged);
    _settingsController.addListener(_onSettingsChanged);
    unawaited(_evaluateWakeLock());
  }

  void dispose() {
    _de1Subscription?.cancel();
    _de1Subscription = null;
    _snapshotSubscription?.cancel();
    _snapshotSubscription = null;
    _batterySubscription?.cancel();
    _batterySubscription = null;
    _settingsController.removeListener(_onSettingsChanged);
    _stateSubject.close();
  }

  /// Set screen brightness to a value between 0 and 100.
  ///
  /// Value 100 resets to OS-managed brightness (respects auto-brightness).
  /// Values 0-99 set a specific brightness level.
  Future<void> setBrightness(int value) async {
    final clamped = value.clamp(0, 100);
    _requestedBrightness = clamped;
    await _applyBrightness();
  }

  /// Dim the screen to minimum brightness.
  ///
  /// Deprecated: Use [setBrightness] with a value of 5 instead.
  @Deprecated('Use setBrightness(5) instead')
  Future<void> dim() async {
    await setBrightness(5);
  }

  /// Restore screen brightness to system default.
  ///
  /// Deprecated: Use [setBrightness] with a value of 100 instead.
  @Deprecated('Use setBrightness(100) instead')
  Future<void> restore() async {
    await setBrightness(100);
  }

  /// Request wake-lock override (skin wants screen always on).
  Future<void> requestWakeLock() async {
    _wakeLockOverride = true;
    await _applyWakeLock(true);
    _updateState(wakeLockOverride: true);
    _log.fine('Wake-lock override requested');
  }

  /// Release wake-lock override (return to auto-managed).
  Future<void> releaseWakeLock() async {
    _wakeLockOverride = false;
    _updateState(wakeLockOverride: false);
    await _evaluateWakeLock();
    _log.fine('Wake-lock override released');
  }

  Future<void> _applyBrightness() async {
    if (!_platformSupport.brightness) return;

    final effective = _computeEffectiveBrightness();
    final capping = effective < _requestedBrightness;

    try {
      if (effective == 100) {
        await _resetBrightness();
      } else {
        await _setBrightness(effective / 100.0);
      }
      _updateState(
        brightness: effective,
        requestedBrightness: _requestedBrightness,
        lowBatteryBrightnessActive: capping,
      );
      _log.fine(
        'Brightness set to $effective (requested: $_requestedBrightness, capping: $capping)',
      );
    } catch (e) {
      _log.warning('Failed to set brightness: $e');
    }
  }

  int _computeEffectiveBrightness() {
    if (_batteryStateStream == null) return _requestedBrightness;

    // Setting must be enabled
    if (!_settingsController.lowBatteryBrightnessLimit) {
      return _requestedBrightness;
    }

    // Battery must be below threshold
    if (_lastBatteryPercent != null &&
        _lastBatteryPercent! < _lowBatteryThreshold) {
      return _requestedBrightness.clamp(0, _lowBatteryBrightnessCap);
    }

    return _requestedBrightness;
  }

  void _onBatteryChanged(ChargingState state) {
    _lastBatteryPercent = state.batteryPercent;
    unawaited(_applyBrightness());
  }

  void _onSettingsChanged() {
    unawaited(_applyBrightness());
    // keepAwake toggle must take effect immediately, not on the next machine
    // state transition.
    unawaited(_evaluateWakeLock());
  }

  void _onDe1Changed(De1Interface? de1) {
    if (de1 == _de1) return;

    _snapshotSubscription?.cancel();
    _snapshotSubscription = null;
    _currentMachineState = null;

    _de1 = de1;

    if (de1 != null) {
      _log.fine('DE1 connected, subscribing to snapshots for display mgmt');
      _snapshotSubscription = de1.currentSnapshot.listen(_onSnapshot);
    } else {
      _log.fine('DE1 disconnected, releasing wake-lock');
      _evaluateWakeLock();
    }
  }

  void _onSnapshot(MachineSnapshot snapshot) {
    final previousState = _currentMachineState;
    _currentMachineState = snapshot.state.state;

    _syncBrightnessForMachineState();

    if (previousState != _currentMachineState) {
      unawaited(_evaluateWakeLock());
    }
  }

  /// Save the user's brightness before sleep; restore it whenever the machine
  /// is awake again.
  ///
  /// Keyed off the awake *condition*, not the precise sleeping->idle edge, and
  /// re-evaluated on *every* snapshot rather than only on a transition. Two
  /// things break an edge-triggered restore and leave the screen stuck at the
  /// sleep-dim (0):
  ///   * the edge is never observed — a BLE reconnect resets our last-seen
  ///     state to null, or we start up against an already-sleeping machine;
  ///   * a stray brightness-0 write lands *after* we've already processed the
  ///     wake transition — e.g. a skin's deferred sleep-dim arriving a beat
  ///     after the machine woke, or a buffered "sleeping" frame replayed on a
  ///     websocket reconnect — so there is no later edge to heal it.
  /// Re-checking each snapshot self-heals both. It is self-limiting: once
  /// restored, [_requestedBrightness] is non-zero so the branch stops firing.
  void _syncBrightnessForMachineState() {
    if (_currentMachineState == MachineState.sleeping) {
      // Never capture a dimmed value: a skin drives brightness to 0 for its
      // sleep screen, and remembering that would "restore" to black next wake.
      if (_requestedBrightness > 0) {
        _preSleepBrightness = _requestedBrightness;
      }
    } else if (_requestedBrightness == 0 && _preSleepBrightness > 0) {
      _log.info('Awake with screen still dimmed — restoring brightness');
      unawaited(setBrightness(_preSleepBrightness));
    }
  }

  /// Re-assert screen brightness after the app window resumes.
  ///
  /// A brightness write issued while the activity was paused — e.g. the wake
  /// restore firing right as the tablet screen was turning back on — can
  /// silently fail to take effect on Android, and nothing else re-applies it,
  /// so the screen stays dark even though our state believes it is restored.
  /// On resume the window is ready again: re-run the restore check and push the
  /// current value to the OS so a write that never stuck is reapplied.
  Future<void> onAppResumed() async {
    _syncBrightnessForMachineState();
    await _applyBrightness();
  }

  Future<void> _evaluateWakeLock() async {
    // keepAwake setting: screen always on while the app runs (full override).
    if (_settingsController.keepAwake) {
      await _applyWakeLock(true);
      return;
    }

    if (_wakeLockOverride) {
      await _applyWakeLock(true);
      return;
    }

    final shouldEnable =
        _de1 != null && _currentMachineState != MachineState.sleeping;
    await _applyWakeLock(shouldEnable);
  }

  Future<void> _applyWakeLock(bool enable) async {
    try {
      if (enable) {
        await _enableWakeLock();
      } else {
        await _disableWakeLock();
      }
      _updateState(wakeLockEnabled: enable);
    } catch (e) {
      _log.warning('Failed to ${enable ? "enable" : "disable"} wake-lock: $e');
    }
  }

  void _updateState({
    bool? wakeLockEnabled,
    bool? wakeLockOverride,
    int? brightness,
    int? requestedBrightness,
    bool? lowBatteryBrightnessActive,
  }) {
    _stateSubject.add(
      currentState.copyWith(
        wakeLockEnabled: wakeLockEnabled,
        wakeLockOverride: wakeLockOverride,
        brightness: brightness,
        requestedBrightness: requestedBrightness,
        lowBatteryBrightnessActive: lowBatteryBrightnessActive,
      ),
    );
  }
}
