import 'dart:async';

import 'package:fake_async/fake_async.dart';

class FakeTime {
  final _time = FakeAsync();
  final _realZone = Zone.current;

  List<FakeTimer> get pendingTimers => _time.pendingTimers;

  T run<T>(T Function() body) => _time.run(
    (_) => runZoned(
      body,
      zoneSpecification: ZoneSpecification(
        scheduleMicrotask: (_, parent, zone, callback) {
          parent.scheduleMicrotask(zone, callback);
          _realZone.scheduleMicrotask(_time.flushMicrotasks);
        },
      ),
    ),
  );

  Future<void> elapse(Duration duration) async {
    if (duration.isNegative) {
      throw ArgumentError.value(duration, 'duration');
    }
    await _realZone.run(() => Future<void>.delayed(Duration.zero));
    var remaining = duration;
    do {
      final step = remaining < const Duration(milliseconds: 10)
          ? remaining
          : const Duration(milliseconds: 10);
      _time.elapse(step);
      await _realZone.run(() => Future<void>.delayed(Duration.zero));
      remaining -= step;
    } while (remaining > Duration.zero);
  }
}
