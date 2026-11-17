import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/services/telemetry/telemetry_report_queue.dart';

void main() {
  test(
    'queue is bounded and drops oldest pending reports during a slow send',
    () async {
      final releaseFirstSend = Completer<void>();
      final sent = <Object>[];
      final queue = TelemetryReportQueue((
        error,
        stack, {
        bool fatal = false,
      }) async {
        sent.add(error);
        if (error == 'in flight') await releaseFirstSend.future;
      });

      queue.enqueue('in flight', null);
      await pumpEventQueue();
      for (var i = 0; i < TelemetryReportQueue.maxCapacity + 3; i++) {
        queue.enqueue(i, null);
        expect(
          queue.length,
          lessThanOrEqualTo(TelemetryReportQueue.maxCapacity),
        );
      }
      expect(queue.length, TelemetryReportQueue.maxCapacity);
      expect(sent, ['in flight']);

      releaseFirstSend.complete();
      await pumpEventQueue();
      expect(sent, [
        'in flight',
        ...List.generate(TelemetryReportQueue.maxCapacity, (i) => i + 3),
      ]);
      expect(queue.length, 0);
    },
  );

  test(
    'send failure does not retry, recurse, or block later reports',
    () async {
      final attempted = <Object>[];
      final queue = TelemetryReportQueue((
        error,
        stack, {
        bool fatal = false,
      }) async {
        attempted.add(error);
        if (error == 'fails') throw StateError('send unavailable');
      });

      queue.enqueue('fails', null);
      queue.enqueue('next', null);
      await pumpEventQueue();
      expect(attempted, ['fails', 'next']);
      expect(queue.length, 0);

      queue.enqueue('after drain', null);
      await pumpEventQueue();
      expect(attempted, ['fails', 'next', 'after drain']);
      expect(queue.length, 0);
    },
  );

  test('queue preserves exception, original stack, and fatal flag', () async {
    final error = StateError('originating failure');
    final stack = StackTrace.current;
    Object? sentError;
    StackTrace? sentStack;
    bool? sentFatal;
    final queue = TelemetryReportQueue((
      error,
      stack, {
      bool fatal = false,
    }) async {
      sentError = error;
      sentStack = stack;
      sentFatal = fatal;
    });

    queue.enqueue(error, stack, fatal: true);
    await pumpEventQueue();

    expect(sentError, same(error));
    expect(sentStack, same(stack));
    expect(sentFatal, isTrue);
    expect(queue.length, 0);
  });
}
