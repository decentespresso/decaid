import 'dart:async';

import 'package:clock/clock.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/device/impl/mock_scale/mock_scale.dart';
import 'package:reaprime/src/models/device/scale.dart';

void withMockScale(
  void Function(FakeAsync, MockScale, List<ScaleSnapshot>) verify,
) {
  fakeAsync((async) {
    final snapshots = <ScaleSnapshot>[];
    final scale = MockScale(timerStopwatch: clock.stopwatch());
    final subscription = scale.currentSnapshot.listen(snapshots.add);
    try {
      verify(async, scale, snapshots);
    } finally {
      scale.simulateDisconnect();
      unawaited(subscription.cancel());
    }
  });
}

void main() {
  group('MockScale timer', () {
    test('timer starts at null', () {
      withMockScale((async, scale, snapshots) {
        async.elapse(const Duration(milliseconds: 200));

        expect(snapshots.single.timerValue, isNull);
      });
    });

    test('startTimer begins tracking elapsed time', () {
      withMockScale((async, scale, snapshots) {
        unawaited(scale.startTimer());
        async.flushMicrotasks();
        async.elapse(const Duration(milliseconds: 200));

        expect(snapshots.single.timerValue, isNotNull);
        expect(snapshots.single.timerValue!.inMilliseconds, greaterThan(0));
      });
    });

    test('stopTimer freezes the elapsed time', () {
      withMockScale((async, scale, snapshots) {
        unawaited(scale.startTimer());
        async.flushMicrotasks();
        async.elapse(const Duration(milliseconds: 200));
        unawaited(scale.stopTimer());
        async.flushMicrotasks();
        final frozenValue = snapshots.last.timerValue;

        async.elapse(const Duration(milliseconds: 400));

        expect(frozenValue, isNotNull);
        expect(snapshots.last.timerValue, equals(frozenValue));
      });
    });

    test('resetTimer clears the elapsed time', () {
      withMockScale((async, scale, snapshots) {
        unawaited(scale.startTimer());
        async.flushMicrotasks();
        async.elapse(const Duration(milliseconds: 200));
        expect(snapshots.last.timerValue, isNotNull);

        unawaited(scale.resetTimer());
        async.flushMicrotasks();
        async.elapse(const Duration(milliseconds: 200));

        expect(snapshots.last.timerValue, isNull);
      });
    });
  });
}
