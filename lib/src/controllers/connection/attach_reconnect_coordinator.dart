import 'dart:async';

import 'package:reaprime/src/models/device/device_attach_notifier.dart';

class AttachReconnectCoordinator {
  final Duration settleDelay;
  final bool Function() shouldAttempt;
  final Future<bool> Function(DeviceAttachedEvent event) attempt;
  final FutureOr<void> Function() recover;
  final void Function()? onLatched;
  final void Function()? onSettled;

  late final StreamSubscription<DeviceAttachedEvent> _subscription;
  Timer? _settleTimer;
  Future<void>? _inFlightAttempt;
  bool _inFlight = false;
  bool _disposed = false;
  DeviceAttachedEvent? _pendingEvent;

  AttachReconnectCoordinator({
    required Stream<DeviceAttachedEvent> attachEvents,
    required this.settleDelay,
    required this.shouldAttempt,
    required this.attempt,
    required this.recover,
    this.onLatched,
    this.onSettled,
  }) {
    _subscription = attachEvents.listen(_onAttach);
  }

  void _onAttach(DeviceAttachedEvent event) {
    if (_disposed || _inFlight) return;
    _pendingEvent = event;
    if (_settleTimer != null) return;
    if (!shouldAttempt()) return;
    onLatched?.call();
    _settleTimer = Timer(settleDelay, () {
      _settleTimer = null;
      if (_disposed || _inFlight) return;
      if (!shouldAttempt()) {
        onSettled?.call();
        return;
      }
      final event = _pendingEvent;
      if (event == null) return;
      _inFlight = true;
      _inFlightAttempt = _startAttempt(event);
      unawaited(_inFlightAttempt);
    });
  }

  Future<void> _startAttempt(DeviceAttachedEvent event) async {
    try {
      await _runAttempt(event);
    } finally {
      _inFlightAttempt = null;
    }
  }

  Future<void> _runAttempt(DeviceAttachedEvent event) async {
    var succeeded = false;
    try {
      succeeded = await attempt(event);
    } catch (_) {
      succeeded = false;
    } finally {
      _inFlight = false;
    }
    if (!_disposed && !succeeded && shouldAttempt()) {
      await recover();
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _settleTimer?.cancel();
    _settleTimer = null;
    await _subscription.cancel();
    await _inFlightAttempt;
  }
}
