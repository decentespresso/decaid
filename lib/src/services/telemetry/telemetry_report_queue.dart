import 'dart:async';
import 'dart:developer' as developer;

class _ReportEntry {
  final Object error;
  final StackTrace? stackTrace;
  final bool fatal;

  _ReportEntry(this.error, this.stackTrace, {required this.fatal});
}

class TelemetryReportQueue {
  static const int maxCapacity = 10;

  final Future<void> Function(
    Object error,
    StackTrace? stackTrace, {
    bool fatal,
  })
  _sendCallback;

  final List<_ReportEntry> _queue = [];

  bool _isDraining = false;

  TelemetryReportQueue(this._sendCallback);

  void enqueue(Object error, StackTrace? stackTrace, {bool fatal = false}) {
    if (_queue.length >= maxCapacity) {
      _queue.removeAt(0);
    }

    _queue.add(_ReportEntry(error, stackTrace, fatal: fatal));

    if (!_isDraining) {
      _startDrainLoop();
    }
  }

  void _startDrainLoop() {
    _isDraining = true;

    scheduleMicrotask(() async {
      while (_queue.isNotEmpty) {
        final report = _queue.removeAt(0);

        try {
          await _sendCallback(
            report.error,
            report.stackTrace,
            fatal: report.fatal,
          );
        } catch (e, st) {
          developer.log(
            'Failed to send telemetry report',
            error: e,
            stackTrace: st,
            name: 'TelemetryReportQueue',
          );
        }
      }

      _isDraining = false;
    });
  }

  int get length => _queue.length;
}
