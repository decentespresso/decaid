import 'dart:async';
import 'dart:math';

import 'package:logging/logging.dart';
import 'package:reaprime/src/controllers/connection_error.dart';
import 'package:reaprime/src/controllers/de1_controller.dart';
import 'package:reaprime/src/controllers/workflow_controller.dart';
import 'package:reaprime/src/models/data/profile.dart';
import 'package:reaprime/src/models/device/de1_interface.dart';
import 'package:reaprime/src/models/errors.dart';

class WorkflowDeviceSync {
  WorkflowDeviceSync({
    required WorkflowController workflowController,
    required De1Controller de1Controller,
    this.retryDelays = const [
      Duration(seconds: 3),
      Duration(seconds: 10),
      Duration(seconds: 30),
    ],
    this.onUploadError,
    this.onUploadErrorCleared,
  }) : _workflow = workflowController,
       _de1 = de1Controller {
    _workflow.addListener(_onChange);
    _de1Sub = _de1.de1.listen(_onDe1Change);
    _initSettledSub = _de1.initSettled.listen(_onInitSettled);
  }

  final WorkflowController _workflow;
  final De1Controller _de1;
  final Logger _log = Logger('WorkflowDeviceSync');

  final List<Duration> retryDelays;

  final void Function(ConnectionError error)? onUploadError;

  final void Function()? onUploadErrorCleared;

  Profile? _lastPushedProfile;
  Profile? _desiredProfile;

  /// The profile the connected machine PERMANENTLY refused — a
  /// [ProfileModeUnsupportedException] (missing capability, or not a Bengle).
  /// Unlike a transient BLE-write failure, retrying can never succeed for the
  /// current connection, so the drain parks on it (no retry timer) and skips
  /// re-attempting the same profile. Cleared when the workflow profile changes
  /// ([_onChange]), the machine reconnects ([_onInitSettled]) or disconnects
  /// ([_onDe1Change]) — any may resolve the refusal (a different profile, or a
  /// reconnect to firmware that now advertises the capability, which the
  /// reconnect push re-drives).
  Profile? _refusedProfile;

  bool _uploading = false;
  Timer? _retryTimer;
  int _attempt = 0;

  bool _errorSurfaced = false;
  bool _disposed = false;

  static const int _retryLogHeartbeat = 10;

  int _generation = 0;

  StreamSubscription<De1Interface?>? _de1Sub;
  StreamSubscription<int?>? _initSettledSub;

  void _onChange() {
    final next = _workflow.currentWorkflow.profile;
    if (next == _desiredProfile) {
      return;
    }
    _desiredProfile = next;
    _attempt = 0;
    // A genuine profile change clears any parked capability refusal so the new
    // profile gets a fresh attempt.
    _refusedProfile = null;
    _cancelRetry();
    unawaited(_drain());
  }

  void _onInitSettled(int? generation) {
    if (generation == null || generation != _generation) return;
    _lastPushedProfile = null;
    _desiredProfile = _workflow.currentWorkflow.profile;
    _attempt = 0;
    // A reconnect may be to firmware that now advertises the capability, so
    // clear any parked refusal and let the push re-drive.
    _refusedProfile = null;
    _cancelRetry();
    unawaited(_drain());
  }

  Future<void> _drain() async {
    if (_uploading) return;
    _uploading = true;
    final generation = _generation;
    try {
      while (generation == _generation) {
        final profile = _desiredProfile;
        if (profile == null || profile == _lastPushedProfile) {
          _desiredProfile = null;
          return;
        }
        // Parked on a permanent capability refusal. Do not re-attempt — only a
        // workflow-profile change or a reconnect (both clear _refusedProfile
        // and re-drive) can resolve it.
        if (profile == _refusedProfile) {
          return;
        }
        try {
          await _de1.runDeviceWrite((device) => device.setProfile(profile));
          if (generation != _generation) return;
          _lastPushedProfile = profile;
          _attempt = 0;
          if (_errorSurfaced) {
            _errorSurfaced = false;
            onUploadErrorCleared?.call();
          }
        } on ProfileModeUnsupportedException catch (e) {
          if (generation != _generation) return;
          // The machine's firmware cannot run the pump step types / transitions
          // in this profile. The refusal is permanent for the connection (the
          // gate throws before any BLE write, so nothing is wedged), so PARK —
          // no retry timer — and remember the profile so a spurious re-drive
          // doesn't re-attempt it. A workflow-profile change or a reconnect
          // clears _refusedProfile and re-drives.
          _refusedProfile = profile;
          _lastPushedProfile = null;
          _log.warning(
            'setProfile refused (unsupported pump step types): ${e.message}',
          );
          return;
        } on DeviceNotConnectedException {
          _log.fine('DE1 not connected; skipping profile push');
          return;
        } catch (e, st) {
          if (generation != _generation) return;
          _lastPushedProfile = null;
          final delay = _scheduleRetry(generation);
          final message =
              'setProfile failed (attempt $_attempt); retrying in '
              '${delay.inMilliseconds}ms';
          if (_attempt <= retryDelays.length ||
              _attempt % _retryLogHeartbeat == 0) {
            _log.warning(message, e, st);
          } else {
            _log.fine(message, e);
          }
          if (!_errorSurfaced) {
            _errorSurfaced = true;
            onUploadError?.call(
              ConnectionError(
                kind: ConnectionErrorKind.profileUploadFailed,
                severity: ConnectionErrorSeverity.warning,
                timestamp: DateTime.now().toUtc(),
                deviceId: _de1.connectedDe1OrNull?.deviceId,
                deviceName: _de1.connectedDe1OrNull?.name,
                message:
                    'Profile upload to the machine failed; '
                    'retrying automatically',
              ),
            );
          }
          return;
        }
      }
    } finally {
      _uploading = false;
      if (!_disposed && generation != _generation && _desiredProfile != null) {
        unawaited(_drain());
      }
    }
  }

  Duration _scheduleRetry(int generation) {
    final delay = retryDelays[min(_attempt, retryDelays.length - 1)];
    _attempt++;
    _retryTimer = Timer(delay, () {
      if (generation != _generation) return;
      unawaited(_drain());
    });
    return delay;
  }

  void _cancelRetry() {
    _retryTimer?.cancel();
    _retryTimer = null;
  }

  void _onDe1Change(De1Interface? device) {
    if (device == null) {
      _generation++;
      _cancelRetry();
      _desiredProfile = null;
      _lastPushedProfile = null;
      _refusedProfile = null;
      _attempt = 0;
      if (_errorSurfaced) {
        _errorSurfaced = false;
        onUploadErrorCleared?.call();
      }
      return;
    }
    _generation = _de1.connectionGeneration;
  }

  void dispose() {
    _workflow.removeListener(_onChange);
    _disposed = true;
    _generation++;
    _cancelRetry();
    _de1Sub?.cancel();
    _de1Sub = null;
    _initSettledSub?.cancel();
    _initSettledSub = null;
    if (_errorSurfaced) {
      _errorSurfaced = false;
      onUploadErrorCleared?.call();
    }
  }
}
