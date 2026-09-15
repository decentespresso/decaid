class ConnectionAttemptOwner {
  final Map<String, ConnectionAttemptLease> _active = {};
  int _nextGeneration = 0;

  ConnectionAttemptLease? acquire(String deviceId, {bool automatic = false}) {
    final key = _normalize(deviceId);
    if (_active.containsKey(key)) return null;

    final lease = ConnectionAttemptLease._(
      owner: this,
      deviceId: deviceId,
      key: key,
      generation: ++_nextGeneration,
      automatic: automatic,
    );
    _active[key] = lease;
    return lease;
  }

  bool isCurrent(ConnectionAttemptLease lease) =>
      identical(_active[lease._key], lease) && !lease._settled;

  bool isBlocked(String deviceId) => _active.containsKey(_normalize(deviceId));

  ConnectionAttemptLease? activeFor(String deviceId) =>
      _active[_normalize(deviceId)];

  Map<String, Object?> diagnosticsFor(String deviceId) {
    final active = activeFor(deviceId);
    if (active == null) {
      return const {'active': false};
    }
    return {
      'active': true,
      'deviceId': active.deviceId,
      'generation': active.generation,
      'automatic': active.automatic,
      'cancelled': active.cancelled,
      'cancelReason': active.cancelReason,
      'settled': active.settled,
    };
  }

  bool _cancel(ConnectionAttemptLease lease, String? reason) {
    if (!isCurrent(lease) || lease._cancelled) return false;
    lease._cancelled = true;
    lease._cancelReason = reason;
    return true;
  }

  bool _settle(ConnectionAttemptLease lease) {
    if (!isCurrent(lease)) {
      lease._settled = true;
      return false;
    }
    lease._settled = true;
    _active.remove(lease._key);
    return true;
  }

  static String _normalize(String deviceId) => deviceId.toLowerCase();
}

class ConnectionAttemptLease {
  final ConnectionAttemptOwner _owner;
  final String deviceId;
  final String _key;
  final int generation;
  final bool automatic;

  bool _cancelled = false;
  bool _settled = false;
  String? _cancelReason;

  ConnectionAttemptLease._({
    required ConnectionAttemptOwner owner,
    required this.deviceId,
    required String key,
    required this.generation,
    required this.automatic,
  }) : _owner = owner,
       _key = key;

  bool get cancelled => _cancelled;
  bool get settled => _settled;
  String? get cancelReason => _cancelReason;

  bool get mayAdopt => !_cancelled && !_settled && _owner.isCurrent(this);

  bool cancel({String? reason}) => _owner._cancel(this, reason);

  bool settle() => _owner._settle(this);
}
