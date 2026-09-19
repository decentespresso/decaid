class ConnectionAttemptOwner {
  final Map<String, ConnectionAttemptLease> _active = {};

  ConnectionAttemptLease? acquire(
    String deviceId, {
    ConnectionAttemptRole role = ConnectionAttemptRole.machine,
    bool automatic = false,
    bool scanOwned = false,
    bool controllerOwned = true,
    bool ble = false,
  }) {
    final key = _normalize(deviceId);
    if (_active.containsKey(key)) return null;

    final lease = ConnectionAttemptLease._(
      owner: this,
      deviceId: deviceId,
      key: key,
      role: role,
      automatic: automatic,
      scanOwned: scanOwned,
      controllerOwned: controllerOwned,
      ble: ble,
    );
    _active[key] = lease;
    return lease;
  }

  bool _isCurrent(ConnectionAttemptLease lease) =>
      identical(_active[lease._key], lease);

  Iterable<ConnectionAttemptLease> get active =>
      List.unmodifiable(_active.values);

  ConnectionAttemptLease? activeFor(String deviceId) =>
      _active[_normalize(deviceId)];

  bool owns(String deviceId, {ConnectionAttemptRole? role}) {
    final attempt = _active[_normalize(deviceId)];
    return attempt != null && (role == null || attempt.role == role);
  }

  bool _cancel(ConnectionAttemptLease lease) {
    if (!_isCurrent(lease) || lease._cancelled) return false;
    lease._cancelled = true;
    return true;
  }

  bool _settle(ConnectionAttemptLease lease) {
    if (!_isCurrent(lease)) return false;
    _active.remove(lease._key);
    return true;
  }

  static String _normalize(String deviceId) => deviceId.toLowerCase();
}

enum ConnectionAttemptRole { machine, scale }

class ConnectionAttemptLease {
  final ConnectionAttemptOwner _owner;
  final String deviceId;
  final String _key;
  final ConnectionAttemptRole role;
  final bool automatic;
  final bool scanOwned;
  final bool controllerOwned;
  final bool ble;

  bool _cancelled = false;
  bool _cleanupFailed = false;

  ConnectionAttemptLease._({
    required ConnectionAttemptOwner owner,
    required this.deviceId,
    required String key,
    required this.role,
    required this.automatic,
    required this.scanOwned,
    required this.controllerOwned,
    required this.ble,
  }) : _owner = owner,
       _key = key;

  bool get cancelled => _cancelled;

  bool get cleanupFailed => _cleanupFailed;

  bool get mayAdopt => !_cancelled && _owner._isCurrent(this);

  bool cancel() => _owner._cancel(this);

  void markCleanupFailed() => _cleanupFailed = true;

  bool settle() => _owner._settle(this);
}
