import 'package:clock/clock.dart';
import 'package:uuid/uuid.dart';

import 'plugin_device_contract.dart';

class PluginSampleProvenance {
  final void Function() onClockRollback;
  PluginSampleProvenance({required this.onClockRollback});
  static const capacity = 256;
  static const lifetime = Duration(seconds: 2);
  final Map<String, (int, DateTime)> _samples = {};
  int _sequence = 0;
  int _lastConsumed = 0;
  DateTime? _lastClock;

  int get count => _samples.length;

  DateTime _now() {
    final now = clock.now();
    if (_lastClock != null && now.isBefore(_lastClock!)) {
      clear();
      onClockRollback();
    }
    _lastClock = now;
    _samples.removeWhere((_, sample) => now.difference(sample.$2) >= lifetime);
    return now;
  }

  String capture() {
    final now = _now();
    if (_samples.length == capacity) _samples.remove(_samples.keys.first);
    final token = const Uuid().v4();
    _samples[token] = (++_sequence, now);
    return token;
  }

  DateTime consume(String token) {
    _now();
    final sample = _samples.remove(token);
    if (sample == null || sample.$1 <= _lastConsumed) {
      throw const PluginDeviceException(
        'Invalid or expired sample provenance',
        code: 'stale_sample',
      );
    }
    _lastConsumed = sample.$1;
    return sample.$2;
  }

  void clear() => _samples.clear();
}
