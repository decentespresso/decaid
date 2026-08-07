import 'package:logging/logging.dart';
import 'package:reaprime/src/controllers/connection_error.dart';
import 'package:reaprime/src/controllers/connection_manager.dart'
    show ConnectionPhase, ConnectionStatus;
import 'package:rxdart/rxdart.dart';

class StatusPublisher {
  static final _log = Logger('StatusPublisher');

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

  void clearError() {
    if (current.error == null) return;
    _subject.add(current.copyWith(error: () => null));
  }

  void dispose() {
    if (!_subject.isClosed) {
      _subject.close();
    }
  }
}
