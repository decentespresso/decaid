import 'dart:async';

String normalizeBleDeviceId(String deviceId) => deviceId.toLowerCase();

class BleLifecycleGate {
  final Map<String, Future<void>> _pending = {};
  final Map<String, int> _connectionCancellationEpochs = {};

  int connectionCancellationEpoch(String deviceId) =>
      _connectionCancellationEpochs[normalizeBleDeviceId(deviceId)] ?? 0;

  void cancelConnectionAttempts(String deviceId) {
    final key = normalizeBleDeviceId(deviceId);
    _connectionCancellationEpochs[key] = connectionCancellationEpoch(key) + 1;
  }

  void checkConnectionAttempt(String deviceId, int cancellationEpoch) {
    if (connectionCancellationEpoch(deviceId) != cancellationEpoch) {
      throw BleConnectionAttemptCancelled(deviceId);
    }
  }

  Future<T> runConnection<T>(
    String deviceId,
    Future<T> Function(int cancellationEpoch) operation,
  ) {
    final cancellationEpoch = connectionCancellationEpoch(deviceId);
    return run(deviceId, () {
      checkConnectionAttempt(deviceId, cancellationEpoch);
      return operation(cancellationEpoch);
    });
  }

  Future<T> run<T>(String deviceId, Future<T> Function() operation) async {
    final key = normalizeBleDeviceId(deviceId);
    final previous = _pending[key] ?? Future<void>.value();
    final done = Completer<void>();
    _pending[key] = done.future;
    await previous;
    try {
      return await operation();
    } finally {
      done.complete();
      if (identical(_pending[key], done.future)) _pending.remove(key);
    }
  }
}

class BleConnectionAttemptCancelled implements Exception {
  const BleConnectionAttemptCancelled(this.deviceId);

  final String deviceId;

  @override
  String toString() => 'BLE connection attempt cancelled for $deviceId';
}
