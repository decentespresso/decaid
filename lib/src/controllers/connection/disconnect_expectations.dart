import 'dart:async';

class DisconnectExpectations {
  static const ttl = Duration(seconds: 10);

  final Set<String> _expecting = <String>{};
  final Map<String, Timer> _timers = <String, Timer>{};

  void mark(String deviceId) {
    _expecting.add(deviceId);
    _timers[deviceId]?.cancel();
    _timers[deviceId] = Timer(ttl, () {
      _expecting.remove(deviceId);
      _timers.remove(deviceId);
    });
  }

  bool consume(String deviceId) {
    final wasExpecting = _expecting.remove(deviceId);
    if (wasExpecting) {
      _timers.remove(deviceId)?.cancel();
    }
    return wasExpecting;
  }

  void dispose() {
    for (final t in _timers.values) {
      t.cancel();
    }
    _timers.clear();
    _expecting.clear();
  }
}
