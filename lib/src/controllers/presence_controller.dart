import 'dart:async';

import 'package:logging/logging.dart';
import 'package:reaprime/src/controllers/de1_controller.dart';
import 'package:reaprime/src/models/device/bengle_interface.dart';
import 'package:reaprime/src/models/device/de1_interface.dart';
import 'package:reaprime/src/models/device/device_implementation.dart';
import 'package:reaprime/src/models/device/machine.dart';
import 'package:reaprime/src/models/firmware_wake_window.dart';
import 'package:reaprime/src/models/keep_awake_occurrence.dart';
import 'package:reaprime/src/models/wake_schedule.dart';
import 'package:reaprime/src/settings/settings_controller.dart';

class PresenceController {
  final De1Controller _de1Controller;
  final SettingsController _settingsController;
  final Logger _log = Logger('PresenceController');

  DateTime Function() _clock;

  set clockOverride(DateTime Function() clock) => _clock = clock;

  De1Interface? _de1;
  MachineState? _currentMachineState;
  StreamSubscription<De1Interface?>? _de1Subscription;
  StreamSubscription<MachineSnapshot>? _snapshotSubscription;

  static const Duration _presenceThrottle = Duration(seconds: 5);
  DateTime? _lastPresenceSent;

  bool _pendingUserPresent = false;
  Timer? _pendingUserPresentTimer;

  Timer? _sleepTimer;

  Timer? _scheduleTimer;

  final Set<String> _firedScheduleIds = {};
  int? _lastCheckedMinute;

  String? _cachedSchedulesJson;
  List<WakeSchedule> _cachedSchedules = const [];
  final Set<KeepAwakeOccurrence> _cancelledOccurrences = {};

  List<WakeSchedule> get _wakeSchedules {
    final json = _settingsController.wakeSchedules;
    if (json != _cachedSchedulesJson) {
      _cachedSchedulesJson = json;
      _cachedSchedules = keepAwakeSchedulesFromJson(json);
      _pruneRemovedCancelledOccurrences();
    }
    return _cachedSchedules;
  }

  KeepAwakeOccurrence? get _activeKeepAwakeOccurrence {
    if (_de1 == null) return null;
    final schedules = _wakeSchedules;
    final occurrence = activeKeepAwakeOccurrence(schedules, _clock());
    _pruneCancelledOccurrences(occurrence);
    if (occurrence == null || _cancelledOccurrences.contains(occurrence)) {
      return null;
    }
    return occurrence;
  }

  DateTime? get keepAwakeUntil => _activeKeepAwakeOccurrence?.end;

  PresenceController({
    required De1Controller de1Controller,
    required SettingsController settingsController,
    DateTime Function()? clock,
  }) : _de1Controller = de1Controller,
       _settingsController = settingsController,
       _clock = clock ?? (() => DateTime.now());

  void initialize() {
    _de1Subscription = _de1Controller.de1.listen(_onDe1Changed);
    _settingsController.addListener(_onSettingsChanged);
    _startScheduleChecker();
  }

  void dispose() {
    _de1Subscription?.cancel();
    _de1Subscription = null;
    _snapshotSubscription?.cancel();
    _snapshotSubscription = null;
    _sleepTimer?.cancel();
    _sleepTimer = null;
    _scheduleTimer?.cancel();
    _scheduleTimer = null;
    _pendingUserPresent = false;
    _pendingUserPresentTimer?.cancel();
    _pendingUserPresentTimer = null;
    _cancelledOccurrences.clear();
    _settingsController.removeListener(_onSettingsChanged);
  }

  int heartbeat() {
    if (!_settingsController.userPresenceEnabled || _de1 == null) {
      return -1;
    }

    _sendPresenceThrottled();

    _resetSleepTimer();

    return _secondsRemaining();
  }

  void _onDe1Changed(De1Interface? de1) {
    if (de1 == _de1) return;

    _snapshotSubscription?.cancel();
    _snapshotSubscription = null;
    _sleepTimer?.cancel();
    _sleepTimer = null;
    _currentMachineState = null;
    _lastPresenceSent = null;

    _pendingUserPresent = false;
    _pendingUserPresentTimer?.cancel();
    _pendingUserPresentTimer = null;
    _de1 = de1;

    if (de1 != null) {
      _log.fine('DE1 connected, subscribing to snapshots');
      _snapshotSubscription = de1.currentSnapshot.listen(_onSnapshot);
      _lastPushedSleepTimeout = null;
      _lastPushedSchedulesJson = null;
      _lastPushedMasterEnabled = null;
      _lastPushedDevice = null;
      _syncFirmwareScheduleAndTimeout();
    } else {
      _log.fine('DE1 disconnected, cancelling sleep timer');
    }
  }

  void _onSnapshot(MachineSnapshot snapshot) {
    final newState = snapshot.state.state;

    if (_currentMachineState == MachineState.sleeping &&
        (newState == MachineState.idle || newState == MachineState.schedIdle)) {
      if (_pendingUserPresent) {
        _pendingUserPresent = false;
        _pendingUserPresentTimer?.cancel();
        _pendingUserPresentTimer = null;
        _lastPresenceSent = null;
        _de1?.sendUserPresent().catchError((Object e) {
          _log.warning('Failed to send deferred user present on wake', e);
        });
        _lastPresenceSent = _clock();
      }
    }

    if (newState == MachineState.sleeping &&
        _currentMachineState != null &&
        _currentMachineState != MachineState.sleeping) {
      final occurrence = _activeKeepAwakeOccurrence;
      if (occurrence != null) {
        _cancelledOccurrences.add(occurrence);
        _log.info('Machine went to sleep during keep-awake occurrence');
      }
    }

    if (_settingsController.userPresenceEnabled &&
        _isActiveState(_currentMachineState) &&
        (newState == MachineState.idle || newState == MachineState.schedIdle)) {
      _log.info(
        'Activity ($_currentMachineState) ended, restarting sleep timer',
      );
      _resetSleepTimer();
    }

    _currentMachineState = newState;
  }

  void _onSettingsChanged() {
    _syncFirmwareScheduleAndTimeout();
    if (_de1 != null &&
        _settingsController.userPresenceEnabled &&
        _settingsController.sleepTimeoutMinutes > 0) {
      _resetSleepTimer();
    } else {
      _sleepTimer?.cancel();
      _sleepTimer = null;
    }
  }

  void _pruneRemovedCancelledOccurrences() {
    final scheduleIds = _cachedSchedules.map((schedule) => schedule.id).toSet();
    _cancelledOccurrences.removeWhere(
      (occurrence) => !scheduleIds.contains(occurrence.scheduleId),
    );
  }

  void _pruneCancelledOccurrences(KeepAwakeOccurrence? activeOccurrence) {
    final now = _clock();
    _cancelledOccurrences.removeWhere(
      (occurrence) =>
          occurrence != activeOccurrence && !now.isBefore(occurrence.end),
    );
    if (activeOccurrence != null &&
        _cancelledOccurrences.remove(activeOccurrence)) {
      _cancelledOccurrences.add(activeOccurrence);
    }
  }

  void _sendPresenceThrottled() {
    final now = _clock();
    if (_lastPresenceSent != null &&
        now.difference(_lastPresenceSent!) < _presenceThrottle) {
      _log.fine('Throttled sendUserPresent');
      return;
    }

    _lastPresenceSent = now;

    if (_currentMachineState == MachineState.sleeping) {
      _pendingUserPresent = true;
      _pendingUserPresentTimer?.cancel();
      _pendingUserPresentTimer = Timer(const Duration(seconds: 60), () {
        _pendingUserPresent = false;
        _log.fine('Stale deferred userPresent cleared (60s timeout)');
      });
      _log.fine('Deferred sendUserPresent (machine asleep)');
      return;
    }

    _de1?.sendUserPresent().catchError((Object e) {
      _log.warning('Failed to send user present', e);
    });
  }

  void _resetSleepTimer() {
    _sleepTimer?.cancel();
    _sleepTimer = null;

    final timeoutMinutes = _settingsController.sleepTimeoutMinutes;
    if (timeoutMinutes <= 0) {
      return;
    }

    _sleepTimer = Timer(Duration(minutes: timeoutMinutes), _onSleepTimeout);
  }

  void _onSleepTimeout() {
    if (_de1 == null) return;

    final occurrence = _activeKeepAwakeOccurrence;
    if (occurrence != null) {
      _log.info(
        'Sleep timeout suppressed by keep-awake (until ${occurrence.end})',
      );
      _resetSleepTimer();
      return;
    }

    if (_isActiveState(_currentMachineState)) {
      _log.info(
        'Sleep timeout fired but machine is in active state ($_currentMachineState), restarting timer',
      );
      _resetSleepTimer();
      return;
    }

    final state = _currentMachineState;
    if (state != null && _canSleepFromState(state)) {
      _log.info('Sleep timeout fired, putting machine to sleep');
      _de1Controller.requestMachineState(MachineState.sleeping).catchError((
        Object e,
      ) {
        _log.warning('Failed to request sleep', e);
      });
    }
  }

  int? _lastPushedSleepTimeout;
  String? _lastPushedSchedulesJson;
  bool? _lastPushedMasterEnabled;
  De1Interface? _lastPushedDevice;
  int _firmwareSyncGeneration = 0;
  Future<void>? _firmwareSyncInFlight;

  static const String _disabledSchedulesJson = '[]';

  void _syncFirmwareScheduleAndTimeout() {
    final de1 = _de1;
    if (de1 is! BengleInterface) {
      return;
    }
    _firmwareSyncGeneration++;
    _firmwareSyncInFlight ??= _drainFirmwareSync();
  }

  static const int _maxFirmwareSyncAttempts = 3;

  static const Duration _firmwareSyncRetryDelay = Duration(seconds: 2);

  Future<void> _drainFirmwareSync() async {
    try {
      var attempts = 0;
      var generation = 0;
      while (true) {
        final currentGeneration = _firmwareSyncGeneration;
        if (currentGeneration != generation) {
          generation = currentGeneration;
          attempts = 0;
        }
        try {
          await _pushFirmwareDesiredState();
          attempts = 0;
        } catch (e) {
          attempts++;
          _log.warning(
            'Failed to push Bengle firmware state '
            '(attempt $attempts/$_maxFirmwareSyncAttempts): $e',
          );
          if (attempts >= _maxFirmwareSyncAttempts) break;
          await Future<void>.delayed(_firmwareSyncRetryDelay);
        }
        if (generation == _firmwareSyncGeneration && attempts == 0) break;
      }
    } finally {
      _firmwareSyncInFlight = null;
    }
  }

  Future<void> _pushFirmwareDesiredState() async {
    final de1 = _de1;
    if (de1 is! BengleInterface) {
      return;
    }
    final enabled = _settingsController.userPresenceEnabled;
    final timeout = enabled ? _settingsController.sleepTimeoutMinutes : 0;
    final schedulesJson = enabled
        ? _settingsController.wakeSchedules
        : _disabledSchedulesJson;
    if (de1 == _lastPushedDevice &&
        enabled == _lastPushedMasterEnabled &&
        timeout == _lastPushedSleepTimeout &&
        schedulesJson == _lastPushedSchedulesJson) {
      return;
    }

    final windows = enabled
        ? translateWakeSchedules(keepAwakeSchedulesFromJson(schedulesJson))
        : const <FirmwareWakeWindow>[];
    final secondsSinceSunday = localSecondsSinceSunday(_clock());
    await de1.setInactivitySleepTimeout(timeout);
    await de1.pushFirmwareWakeSchedule(
      secondsSinceSundayLocal: secondsSinceSunday,
      windows: windows,
    );
    if (_de1 == de1) {
      _lastPushedDevice = de1;
      _lastPushedMasterEnabled = enabled;
      _lastPushedSleepTimeout = timeout;
      _lastPushedSchedulesJson = schedulesJson;
      _log.fine(
        'Pushed Bengle firmware state: sleep timeout $timeout min, '
        '${windows.length} wake windows',
      );
    }
  }

  static const int _kSleepOnRefillMinFwBuild = 1357;

  bool _isActiveState(MachineState? state) {
    if (state == null) return false;
    switch (state) {
      case MachineState.espresso:
      case MachineState.steam:
      case MachineState.hotWater:
      case MachineState.flush:
      case MachineState.cleaning:
      case MachineState.descaling:
      case MachineState.fwUpgrade:
        return true;
      default:
        return false;
    }
  }

  bool _canSleepFromState(MachineState state) {
    if (state == MachineState.idle || state == MachineState.schedIdle) {
      return true;
    }
    if (state == MachineState.needsWater) {
      final de1 = _de1;
      if (de1 == null ||
          de1.implementation != DeviceImplementation.unifiedDe1) {
        return false;
      }
      final fwBuild = int.tryParse(de1.machineInfo.version) ?? 0;
      return fwBuild >= _kSleepOnRefillMinFwBuild;
    }
    return false;
  }

  int _secondsRemaining() {
    if (_sleepTimer == null || !_sleepTimer!.isActive) {
      return -1;
    }
    final timeoutMinutes = _settingsController.sleepTimeoutMinutes;
    if (timeoutMinutes <= 0) return -1;
    return timeoutMinutes * 60;
  }

  void _startScheduleChecker() {
    _scheduleTimer = Timer.periodic(
      const Duration(seconds: 30),
      (_) => _checkSchedules(),
    );
  }

  void _checkSchedules() {
    if (_de1 == null) return;
    if (_currentMachineState != MachineState.sleeping) return;

    final now = _clock();
    final currentMinute = now.hour * 60 + now.minute;

    if (_lastCheckedMinute != null && _lastCheckedMinute != currentMinute) {
      _firedScheduleIds.clear();
    }
    _lastCheckedMinute = currentMinute;

    final schedulesJson = _settingsController.wakeSchedules;
    if (schedulesJson.isEmpty || schedulesJson == '[]') return;

    try {
      final schedules = WakeSchedule.deserializeList(schedulesJson);
      for (final schedule in schedules) {
        if (!schedule.enabled) continue;
        if (_firedScheduleIds.contains(schedule.id)) continue;

        if (schedule.matchesTime(now)) {
          _log.info(
            'Schedule ${schedule.id} matched at ${now.hour}:${now.minute}, waking machine',
          );
          _firedScheduleIds.add(schedule.id);
          _de1Controller.requestMachineState(MachineState.schedIdle).catchError(
            (Object e) {
              _log.warning('Failed to request schedIdle', e);
            },
          );
          break;
        }
      }
    } catch (e) {
      _log.warning('Failed to parse wake schedules', e);
    }
  }
}
