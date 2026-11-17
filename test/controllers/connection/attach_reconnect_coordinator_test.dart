import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/connection/attach_reconnect_coordinator.dart';
import 'package:reaprime/src/models/device/device_attach_notifier.dart';

void main() {
  const settleDelay = Duration(milliseconds: 500);

  test('one attach attempts once after the settle interval', () {
    fakeAsync((async) {
      final events = StreamController<DeviceAttachedEvent>.broadcast(
        sync: true,
      );
      var attempts = 0;
      final coordinator = AttachReconnectCoordinator(
        attachEvents: events.stream,
        settleDelay: settleDelay,
        shouldAttempt: () => true,
        attempt: (_) async {
          attempts++;
          return true;
        },
        recover: () {},
      );

      events.add(const DeviceAttachedEvent());
      async.elapse(settleDelay - const Duration(milliseconds: 1));
      expect(attempts, 0);

      async.elapse(const Duration(milliseconds: 1));
      async.flushMicrotasks();
      expect(attempts, 1);

      coordinator.dispose();
      events.close();
    });
  });

  test('attach burst during settling coalesces into one attempt', () {
    fakeAsync((async) {
      final events = StreamController<DeviceAttachedEvent>.broadcast(
        sync: true,
      );
      var attempts = 0;
      final coordinator = AttachReconnectCoordinator(
        attachEvents: events.stream,
        settleDelay: settleDelay,
        shouldAttempt: () => true,
        attempt: (_) async {
          attempts++;
          return true;
        },
        recover: () {},
      );

      events
        ..add(const DeviceAttachedEvent())
        ..add(const DeviceAttachedEvent())
        ..add(const DeviceAttachedEvent());
      async.elapse(settleDelay);
      async.flushMicrotasks();

      expect(attempts, 1);
      coordinator.dispose();
      events.close();
    });
  });

  test('attach during an in-flight attempt is ignored', () {
    fakeAsync((async) {
      final events = StreamController<DeviceAttachedEvent>.broadcast(
        sync: true,
      );
      final attemptCompletion = Completer<bool>();
      var attempts = 0;
      final coordinator = AttachReconnectCoordinator(
        attachEvents: events.stream,
        settleDelay: settleDelay,
        shouldAttempt: () => true,
        attempt: (_) {
          attempts++;
          return attemptCompletion.future;
        },
        recover: () {},
      );

      events.add(const DeviceAttachedEvent());
      async.elapse(settleDelay);
      events.add(const DeviceAttachedEvent());
      async.elapse(settleDelay);
      expect(attempts, 1);

      attemptCompletion.complete(true);
      async.flushMicrotasks();
      expect(attempts, 1);

      coordinator.dispose();
      events.close();
    });
  });

  test('attach while a machine is connected does nothing', () {
    fakeAsync((async) {
      final events = StreamController<DeviceAttachedEvent>.broadcast(
        sync: true,
      );
      var attempts = 0;
      final coordinator = AttachReconnectCoordinator(
        attachEvents: events.stream,
        settleDelay: settleDelay,
        shouldAttempt: () => false,
        attempt: (_) async {
          attempts++;
          return true;
        },
        recover: () {},
      );

      events.add(const DeviceAttachedEvent());
      async.elapse(settleDelay);
      expect(attempts, 0);

      coordinator.dispose();
      events.close();
    });
  });

  test('unsuccessful attempt invokes recovery fallback', () {
    fakeAsync((async) {
      final events = StreamController<DeviceAttachedEvent>.broadcast(
        sync: true,
      );
      var recoveries = 0;
      final coordinator = AttachReconnectCoordinator(
        attachEvents: events.stream,
        settleDelay: settleDelay,
        shouldAttempt: () => true,
        attempt: (_) async => false,
        recover: () => recoveries++,
      );

      events.add(const DeviceAttachedEvent());
      async.elapse(settleDelay);
      async.flushMicrotasks();
      expect(recoveries, 1);

      coordinator.dispose();
      events.close();
    });
  });

  test('dispose waits for an in-flight attempt without recovering', () async {
    final events = StreamController<DeviceAttachedEvent>.broadcast(sync: true);
    final attemptStarted = Completer<void>();
    final attemptCompletion = Completer<bool>();
    var recoveries = 0;
    final coordinator = AttachReconnectCoordinator(
      attachEvents: events.stream,
      settleDelay: Duration.zero,
      shouldAttempt: () => true,
      attempt: (_) {
        attemptStarted.complete();
        return attemptCompletion.future;
      },
      recover: () => recoveries++,
    );

    events.add(const DeviceAttachedEvent());
    await attemptStarted.future;

    var disposeCompleted = false;
    final disposal = coordinator.dispose().then((_) => disposeCompleted = true);
    await Future<void>.delayed(Duration.zero);
    expect(disposeCompleted, isFalse);

    attemptCompletion.complete(false);
    await disposal;
    expect(recoveries, 0);

    await events.close();
  });

  test('disposing with a pending settle timer prevents the attempt', () {
    fakeAsync((async) {
      final events = StreamController<DeviceAttachedEvent>.broadcast(
        sync: true,
      );
      var attempts = 0;
      final coordinator = AttachReconnectCoordinator(
        attachEvents: events.stream,
        settleDelay: settleDelay,
        shouldAttempt: () => true,
        attempt: (_) async {
          attempts++;
          return true;
        },
        recover: () {},
      );

      events.add(const DeviceAttachedEvent());
      coordinator.dispose();
      async.elapse(settleDelay);
      expect(attempts, 0);

      events.close();
    });
  });

  test(
    'onLatched fires once when the settle timer arms, not per burst event',
    () {
      fakeAsync((async) {
        final events = StreamController<DeviceAttachedEvent>.broadcast(
          sync: true,
        );
        var latches = 0;
        final coordinator = AttachReconnectCoordinator(
          attachEvents: events.stream,
          settleDelay: settleDelay,
          shouldAttempt: () => true,
          attempt: (_) async => true,
          recover: () {},
          onLatched: () => latches++,
        );

        events
          ..add(const DeviceAttachedEvent())
          ..add(const DeviceAttachedEvent())
          ..add(const DeviceAttachedEvent());
        async.elapse(settleDelay);
        async.flushMicrotasks();

        expect(latches, 1);
        coordinator.dispose();
        events.close();
      });
    },
  );

  test('onLatched does not fire when a machine is already connected', () {
    fakeAsync((async) {
      final events = StreamController<DeviceAttachedEvent>.broadcast(
        sync: true,
      );
      var latches = 0;
      final coordinator = AttachReconnectCoordinator(
        attachEvents: events.stream,
        settleDelay: settleDelay,
        shouldAttempt: () => false,
        attempt: (_) async => true,
        recover: () {},
        onLatched: () => latches++,
      );

      events.add(const DeviceAttachedEvent());
      async.elapse(settleDelay);

      expect(latches, 0);
      coordinator.dispose();
      events.close();
    });
  });

  test('onSettled fires when settle expiry skips the attempt', () {
    fakeAsync((async) {
      final events = StreamController<DeviceAttachedEvent>.broadcast(
        sync: true,
      );
      var settled = 0;
      var attempts = 0;
      var shouldAttempt = true;
      final coordinator = AttachReconnectCoordinator(
        attachEvents: events.stream,
        settleDelay: settleDelay,
        shouldAttempt: () => shouldAttempt,
        attempt: (_) async {
          attempts++;
          return true;
        },
        recover: () {},
        onSettled: () => settled++,
      );

      events.add(const DeviceAttachedEvent());
      shouldAttempt = false;
      async.elapse(settleDelay);
      async.flushMicrotasks();

      expect(attempts, 0);
      expect(settled, 1);
      coordinator.dispose();
      events.close();
    });
  });

  test('attempt receives the latest event of a coalesced burst', () {
    fakeAsync((async) {
      final events = StreamController<DeviceAttachedEvent>.broadcast(
        sync: true,
      );
      DeviceAttachedEvent? attemptedEvent;
      final coordinator = AttachReconnectCoordinator(
        attachEvents: events.stream,
        settleDelay: settleDelay,
        shouldAttempt: () => true,
        attempt: (event) async {
          attemptedEvent = event;
          return true;
        },
        recover: () {},
      );

      events.add(const DeviceAttachedEvent(deviceId: 'first'));
      events.add(const DeviceAttachedEvent(deviceId: 'second'));
      events.add(const DeviceAttachedEvent(deviceId: 'third'));
      async.elapse(settleDelay);
      async.flushMicrotasks();

      expect(attemptedEvent?.deviceId, 'third');
      coordinator.dispose();
      events.close();
    });
  });
}
