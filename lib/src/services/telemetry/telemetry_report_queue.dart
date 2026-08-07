import 'dart:async';
import 'dart:developer' as developer;

/// Report entry for the queue
class _ReportEntry {
  final Object error;
  final StackTrace? stackTrace;
  final bool fatal;

  _ReportEntry(this.error, this.stackTrace, {required this.fatal});
}

/// Bounded async queue for telemetry error reports
///
/// Provides FIFO eviction when capacity is reached and async processing
/// to prevent blocking the UI thread during platform channel calls.
/// Queue capacity is 10 reports, with oldest reports evicted when full.
class TelemetryReportQueue {
  /// Maximum number of pending reports
  static const int maxCapacity = 10;

  /// Callback to send a report
  final Future<void> Function(
    Object error,
    StackTrace? stackTrace, {
    bool fatal,
  })
  _sendCallback;

  /// Internal queue of pending reports
  final List<_ReportEntry> _queue = [];

  /// Flag to prevent concurrent drain loops
  bool _isDraining = false;

  /// Create a new telemetry report queue
  ///
  /// [sendCallback] - Async function to actually send a report
  TelemetryReportQueue(this._sendCallback);

  /// Enqueue a report for async processing
  ///
  /// If the queue is full, the oldest report is evicted (FIFO).
  /// If a drain loop is not already running, one is started.
  void enqueue(Object error, StackTrace? stackTrace, {bool fatal = false}) {
    if (_queue.length >= maxCapacity) {
      _queue.removeAt(0);
    }

    _queue.add(_ReportEntry(error, stackTrace, fatal: fatal));

    // Start drain loop if not already running
    if (!_isDraining) {
      _startDrainLoop();
    }
  }

  /// Start the async drain loop
  ///
  /// Processes reports one at a time until the queue is empty.
  /// Errors from the send callback are caught and logged to prevent
  /// queue crashes.
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
          // Log send failures but don't crash the queue
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

  /// Get the current queue length (for testing/debugging)
  int get length => _queue.length;
}
