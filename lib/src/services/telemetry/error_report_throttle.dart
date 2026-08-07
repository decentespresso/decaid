class ErrorReportThrottle {
  static const _reportIntervalSeconds = 60;
  static const _cleanupThreshold = 100;
  static const _entryTtlMinutes = 5;

  final Map<String, DateTime> _lastReported = {};

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

  void cleanup() {
    final now = DateTime.now();
    final cutoff = now.subtract(Duration(minutes: _entryTtlMinutes));

    _lastReported.removeWhere(
      (message, timestamp) => timestamp.isBefore(cutoff),
    );
  }
}
