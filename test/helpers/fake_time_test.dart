import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rxdart/rxdart.dart';

import 'fake_time.dart';

void main() {
  test(
    'virtual timers retain live stream seeds, cancellation and feedback',
    () async {
      final time = FakeTime();
      final subject = time.run(() => BehaviorSubject<int>.seeded(0));
      final start = time.run(() => clock.now());
      final values = <int>[];
      final subscription = time.run(() => subject.listen(values.add));
      Timer? timer;
      final feedback = time.run(
        () => subject.listen((value) {
          if (value == 3) timer?.cancel();
        }),
      );
      timer = time.run(
        () => Timer.periodic(const Duration(milliseconds: 100), (tick) {
          subject.add(tick.tick);
        }),
      );

      expect(await time.run(() => subject.first), 0);
      await time.elapse(const Duration(seconds: 8));

      expect(values, [0, 1, 2, 3]);
      expect(
        time.run(() => clock.now()).difference(start),
        const Duration(seconds: 8),
      );
      expect(time.pendingTimers, isEmpty);
      await time.run(subscription.cancel);
      await time.run(feedback.cancel);
      await time.run(subject.close);
      expect(subject.isClosed, isTrue);
    },
  );

  test(
    'advances partial timer intervals and rejects negative durations',
    () async {
      final time = FakeTime();
      var completed = false;
      final pending = time.run(() async {
        await Future<void>.value();
        await Future<void>.delayed(const Duration(milliseconds: 15));
        completed = true;
      });

      await time.elapse(const Duration(milliseconds: 14));
      expect(completed, isFalse);
      await time.elapse(const Duration(milliseconds: 1));
      expect(completed, isTrue);
      await pending;
      await time.elapse(Duration.zero);
      expect(time.pendingTimers, isEmpty);
      await expectLater(
        time.elapse(const Duration(milliseconds: -1)),
        throwsArgumentError,
      );
    },
  );
}
