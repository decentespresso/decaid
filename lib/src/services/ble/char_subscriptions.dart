import 'dart:async';

class CharSubscriptions {
  final Map<String, StreamSubscription> _subs = {};

  Future<void> add(String characteristicUUID, StreamSubscription sub) async {
    await _subs.remove(characteristicUUID)?.cancel();
    _subs[characteristicUUID] = sub;
  }

  Future<void> cancelAll() async {
    final pending = _subs.values.toList();
    _subs.clear();
    for (final sub in pending) {
      await sub.cancel();
    }
  }
}
