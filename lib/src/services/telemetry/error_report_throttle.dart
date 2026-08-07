/// Rate limiting for error reports to prevent flooding telemetry backend
///
/// Enforces maximum 1 report per 60 seconds per unique error message.
/// Automatically cleans up old entries to prevent unbounded memory growth.
class ErrorReportThrottle {
  static const _reportIntervalSeconds = 60;
  static const _cleanupThreshold = 100;
  static const _entryTtlMinutes = 5;

  final Map<String, DateTime> _lastReported = {};

  /// Check if an error should be reported based on rate limiting
  ///
  /// Returns true if:
  /// - No previous report exists for this message
  /// - More than 60 seconds have elapsed since the last report
  ///
  /// When returning true, updates the timestamp for the message.
  /// Triggers cleanup when map exceeds 100 entries.
  bool shouldReport(String message) {
    final now = DateTime.now();

    if (_lastReported.length > _cleanupThreshold) {
      cleanup();
    }

    final lastReport = _lastReported[message];

    if (lastReport == null) {
      _lastReported[message] = now;
      return true;
    }

    final elapsed = now.difference(lastReport).inSeconds;
    if (elapsed >= _reportIntervalSeconds) {
      _lastReported[message] = now;
      return true;
    }

    return false;
  }

  /// Remove entries older than 5 minutes to prevent unbounded map growth
  void cleanup() {
    final now = DateTime.now();
    final cutoff = now.subtract(Duration(minutes: _entryTtlMinutes));

    _lastReported.removeWhere(
      (message, timestamp) => timestamp.isBefore(cutoff),
    );
  }
}
