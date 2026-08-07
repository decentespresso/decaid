import 'package:logging/logging.dart';
import 'package:reaprime/src/controllers/connection_error.dart';
import 'package:reaprime/src/controllers/connection_manager.dart'
    show ConnectionPhase, ConnectionStatus;
import 'package:rxdart/rxdart.dart';

/// Owns the `ConnectionStatus` stream for `ConnectionManager` and
/// enforces the error-gating rules that keep sticky errors alive
/// across phase transitions while stripping re-published transient
/// errors at clearing-phase boundaries.
///
/// All outbound status updates funnel through [publish] so the rules
/// live in exactly one place. [emitError] is a convenience that keeps
/// the current phase and sets `error` on it — same gatekeeper path.
///
/// Extracted from ConnectionManager as part of comms-harden Phase 4
/// (roadmap item 15 — god-class split).
class StatusPublisher {
  static final _log = Logger('StatusPublisher');

  /// Phases that start a new operation or reach a stable good state.
  /// Moving into one of these clears a *re-published* transient error
  /// (but not a new one the caller explicitly passed, and not a
  /// sticky error — adapter-off, permission-denied, scan-failed —
  /// which survive until the environment recovers).
  static const _clearingPhases = {
    ConnectionPhase.scanning,
    ConnectionPhase.connectingMachine,
    ConnectionPhase.connectingScale,
    ConnectionPhase.ready,
  };

  final BehaviorSubject<ConnectionStatus> _subject = BehaviorSubject.seeded(
    const ConnectionStatus(),
  );

  Stream<ConnectionStatus> get stream => _subject.stream;
  ConnectionStatus get current => _subject.value;

  /// Publish [next] onto the status stream, applying the sticky /
  /// transient / identity rules to the `error` field.
  void publish(ConnectionStatus next) {
    final prev = _subject.value;
    ConnectionError? effectiveError = next.error;
    final movingIntoClearingPhase =
        prev.phase != next.phase && _clearingPhases.contains(next.phase);

    if (effectiveError == null &&
        prev.error != null &&
        ConnectionErrorKind.sticky.contains(prev.error!.kind)) {
      effectiveError = prev.error;
    } else if (effectiveError != null &&
        movingIntoClearingPhase &&
        !ConnectionErrorKind.sticky.contains(effectiveError.kind) &&
        !ConnectionErrorKind.phasePersistent.contains(effectiveError.kind)) {
      effectiveError = null;
    } else if (prev.error != null &&
        identical(next.error, prev.error) &&
        movingIntoClearingPhase &&
        !ConnectionErrorKind.sticky.contains(prev.error!.kind) &&
        !ConnectionErrorKind.phasePersistent.contains(prev.error!.kind)) {
      effectiveError = null;
    }

    _subject.add(
      next.copyWith(
        error: () => effectiveError,
        activeTargetTransport: next.phase == ConnectionPhase.ready
            ? () => null
            : null,
      ),
    );
  }

  /// Emit [err] on the status stream without changing the current
  /// phase. Logs at severe/warning depending on severity, then routes
  /// through [publish] so the same gatekeeper applies.
  ///
  /// Sticky kinds (`adapterOff`, `bluetoothPermissionDenied`, `scanFailed`)
  /// describe environmental states that the user already sees in the UI
  /// `ConnectionErrorBanner`. They aren't crash signals, so they log at
  /// `info` instead of `severe`/`warning` — keeping them out of the
  /// Crashlytics forwarder while preserving them in the file log.
  void emitError(ConnectionError err) {
    final msg =
        'emit error: kind=${err.kind} message=${err.message} '
        'deviceId=${err.deviceId}';
    if (ConnectionErrorKind.sticky.contains(err.kind)) {
      _log.info(msg);
    } else if (err.severity == ConnectionErrorSeverity.error) {
      _log.severe(msg);
    } else {
      _log.warning(msg);
    }
    publish(current.copyWith(error: () => err));
  }

  /// Explicitly clear the current error. Used by environmental-recovery
  /// handlers (adapter-on, scan-started, etc) to drop a sticky error
  /// that [publish]'s rules would preserve.
  void clearError() {
    if (current.error == null) return;
    _subject.add(current.copyWith(error: () => null));
  }

  /// Close the underlying subject. Safe to call more than once.
  void dispose() {
    if (!_subject.isClosed) {
      _subject.close();
    }
  }
}
