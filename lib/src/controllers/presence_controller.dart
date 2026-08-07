import 'dart:async';

import 'package:logging/logging.dart';
import 'package:reaprime/src/controllers/de1_controller.dart';
import 'package:reaprime/src/models/device/de1_interface.dart';
import 'package:reaprime/src/models/device/device_implementation.dart';
import 'package:reaprime/src/models/device/machine.dart';
import 'package:reaprime/src/models/keep_awake_occurrence.dart';
import 'package:reaprime/src/models/wake_schedule.dart';
import 'package:reaprime/src/settings/settings_controller.dart';

/// Manages user presence detection, auto-sleep timeout, and scheduled wake.
///
/// Three concerns:
/// 1. **Heartbeat** — event-driven user presence signal, forwarded to DE1 with
///    5-second throttling. Calls during sleep are deferred and flushed
///    immediately on wake transition, ensuring the DE1 sees a fresh
///    `userPresent` before the refill-kit decision is made.
/// 2. **Sleep timeout** — auto-sleep after configurable timeout with no
///    heartbeat.
/// 3. **Scheduled wake** — periodically checks schedules and wakes sleeping
///    machine at matching times.
class PresenceController {
  final De1Controller _de1Controller;
  final SettingsController _settingsController;
  final Logger _log = Logger('PresenceController');

  /// Optional clock function for testing. Returns the current time.
  DateTime Function() _clock;

  /// Allows tests to change the clock after construction.
  set clockOverride(DateTime Function() clock) => _clock = clock;

  De1Interface? _de1;
  MachineState? _currentMachineState;
  StreamSubscription<De1Interface?>? _de1Subscription;
  StreamSubscription<MachineSnapshot>? _snapshotSubscription;

  /// Throttle: minimum interval between sendUserPresent() calls.
  /// Reduced from 30s to 5s to avoid a cold `userPresent` write blocking
  /// the wake-time signal. Further safety: calls during sleep are deferred
  /// and flushed on wake (see [_pendingUserPresent]).
  static const Duration _presenceThrottle = Duration(seconds: 5);
  DateTime? _lastPresenceSent;

  /// True when a heartbeat arrived while the machine was asleep, meaning a
  /// `sendUserPresent()` was skipped. Flushed on the next wake transition.
  /// Cleared after 60s of no wake to avoid a stale flag triggering a write
  /// on a much-later wake that doesn't need it.
  bool _pendingUserPresent = false;
  Timer? _pendingUserPresentTimer;

  /// Sleep timeout timer.
  Timer? _sleepTimer;

  /// Schedule checker periodic timer.
  Timer? _scheduleTimer;

  /// Tracks which schedule IDs have fired in the current minute to prevent
  /// re-triggering.
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

  /// Subscribe to DE1 connection stream, start schedule checker timer,
  /// listen to settings changes.
  void initialize() {
    _de1Subscription = _de1Controller.de1.listen(_onDe1Changed);
    _settingsController.addListener(_onSettingsChanged);
    _startScheduleChecker();
  }

  /// Clean up all subscriptions and timers.
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

  /// Called by REST API and NavigatorObserver to signal user presence.
  ///
  /// Returns the number of seconds remaining on the sleep timeout, or -1 if
  /// presence is not enabled or no DE1 is connected.
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
      _de1!.requestState(MachineState.sleeping).catchError((Object e) {
        _log.warning('Failed to request sleep', e);
      });
    }
  }

  static const int _kSleepOnRefillMinFwBuild = 1357;

  /// Returns true for machine states where we should NOT auto-sleep.
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
          _de1!.requestState(MachineState.schedIdle).catchError((Object e) {
            _log.warning('Failed to request schedIdle', e);
          });
          break;
        }
      }
    } catch (e) {
      _log.warning('Failed to parse wake schedules', e);
    }
  }
}
