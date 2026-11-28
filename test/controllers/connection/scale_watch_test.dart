import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/connection/scale_watch.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/device_scanner.dart';
import 'package:reaprime/src/models/device/scale.dart';

import '../../helpers/mock_device_scanner.dart';
import '../../helpers/test_scale.dart';

class _HandoverScanner extends MockDeviceScanner
    implements ScaleWatchHandoverScanner {
  final token = Object();
  int claimCalls = 0;
  int cancelCalls = 0;
  Completer<void>? stopGate;

  @override
  Object? claimScaleWatchHandover(Device device) {
    claimCalls++;
    return token;
  }

  @override
  void cancelScaleWatchHandover(Object claim) {
    if (identical(claim, token)) cancelCalls++;
  }

  @override
  Future<void> stopScaleWatch() async {
    await stopGate?.future;
    await super.stopScaleWatch();
  }
}

void main() {
  const scaleId = 'pref-scale';

  late _HandoverScanner scanner;

  late bool gate;
  late String? preferredId;
  late List<Scale> connectCalls;
  late int unavailableCalls;
  late bool connectSucceeds;
  Completer<void>? connectGate;

  late ScaleWatch watch;

  ScaleWatch build() => ScaleWatch(
    scanner: scanner,
    shouldWatch: () => gate,
    preferredScaleId: () => preferredId,
    connectScale: (scale) async {
      connectCalls.add(scale);
      if (connectGate != null) {
        await connectGate!.future;
      }
      if (connectSucceeds) gate = false;
    },
    onWatchUnavailable: () => unavailableCalls++,
  );

  setUp(() {
    scanner = _HandoverScanner()..supportsWatch = true;
    gate = true;
    preferredId = scaleId;
    connectCalls = [];
    unavailableCalls = 0;
    connectSucceeds = true;
    connectGate = null;
    watch = build();
  });

  tearDown(() async {
    await watch.dispose();
    scanner.dispose();
  });

  Future<void> pump([int n = 2]) async {
    for (var i = 0; i < n; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  test('arm is a no-op when the gate does not hold', () async {
    gate = false;
    await watch.arm();
    expect(watch.armed, isFalse);
    expect(scanner.startWatchCallCount, 0);
  });

  test('arm starts an unfiltered scale watch', () async {
    await watch.arm();
    expect(watch.armed, isTrue);
    expect(scanner.startWatchCallCount, 1);
    expect(scanner.lastWatchFilter?.namePrefix, isNull);
  });

  test('arm is idempotent', () async {
    await watch.arm();
    await watch.arm();
    expect(scanner.startWatchCallCount, 1);
  });

  test('preferred scale already discovered at arm time connects directly, '
      'no watch scan', () async {
    scanner.addDevice(TestScale(deviceId: scaleId));
    await watch.arm();
    await pump();

    expect(connectCalls.map((s) => s.deviceId), [scaleId]);
    expect(
      scanner.startWatchCallCount,
      0,
      reason: 'device is already visible — no scan needed',
    );
    expect(
      watch.armed,
      isFalse,
      reason: 'successful connect ends the watch cycle',
    );
  });

  test(
    'cached connect failure arms and consumes a replacement watch',
    () async {
      connectSucceeds = false;
      scanner.addDevice(TestScale(deviceId: scaleId));

      await watch.arm();
      await pump();

      expect(connectCalls, hasLength(1));
      expect(scanner.startWatchCallCount, 1);
      expect(watch.armed, isTrue);
      expect(watch.diagnostics['deviceSubscriptionInstalled'], isTrue);

      scanner.removeDevice(scaleId);
      scanner.addDevice(TestScale(deviceId: scaleId));
      await pump();

      expect(connectCalls, hasLength(2));
    },
  );

  test('cached preferred scale does not bypass an active full scan', () async {
    scanner.addDevice(TestScale(deviceId: scaleId));
    scanner.scanCompleter = Completer<void>();
    final scan = scanner.scanForDevices();
    await pump();

    final arming = watch.arm();
    await pump();
    expect(connectCalls, isEmpty);
    expect(scanner.startWatchCallCount, 0);

    scanner.completeScan();
    await scan;
    await arming;
    await pump();

    expect(connectCalls, isEmpty);
    expect(scanner.startWatchCallCount, 1);
    expect(watch.armed, isTrue);
  });

  test(
    'sighting stops the watch before connecting, then disarms on success',
    () async {
      var watchActiveDuringConnect = true;
      var watchArmedDuringConnect = true;
      late ScaleWatch probe;
      watch = build();
      probe = ScaleWatch(
        scanner: scanner,
        shouldWatch: () => gate,
        preferredScaleId: () => preferredId,
        connectScale: (scale) async {
          connectCalls.add(scale);
          watchActiveDuringConnect = scanner.watchActive;
          watchArmedDuringConnect = probe.armed;
          gate = false;
        },
        onWatchUnavailable: () => unavailableCalls++,
      );
      await probe.arm();
      scanner.addDevice(TestScale(deviceId: scaleId));
      await pump();

      expect(connectCalls.map((s) => s.deviceId), [scaleId]);
      expect(
        watchActiveDuringConnect,
        isFalse,
        reason:
            'the watch scan must stop before the connect attempt so '
            'the radio is free for GATT',
      );
      expect(
        watchArmedDuringConnect,
        isFalse,
        reason: 'a stopped lower-level watch is not armed during GATT',
      );
      expect(probe.armed, isFalse);
      await probe.dispose();
    },
  );

  test('a sighting of a different device is ignored', () async {
    await watch.arm();
    scanner.addDevice(TestScale(deviceId: 'other-scale'));
    await pump();

    expect(connectCalls, isEmpty);
    expect(watch.armed, isTrue);
    expect(scanner.watchActive, isTrue);
  });

  test(
    'failed connect backs off instead of immediately restarting the watch',
    () async {
      connectSucceeds = false;
      await watch.arm();
      scanner.addDevice(TestScale(deviceId: scaleId));
      await pump();

      expect(connectCalls, hasLength(1));
      expect(
        scanner.startWatchCallCount,
        1,
        reason: 'a failed attempt must not create a scan restart storm',
      );
      expect(watch.armed, isFalse);

      scanner.removeDevice(scaleId);
      scanner.addDevice(TestScale(deviceId: scaleId));
      await pump();
      expect(
        connectCalls,
        hasLength(1),
        reason: 'repeated sightings before backoff expiry are coalesced',
      );
    },
  );

  test('failed attempts use bounded 1, 2, 5 and capped 15 second backoff', () {
    fakeAsync((async) {
      connectSucceeds = false;
      watch.arm();
      async.flushMicrotasks();
      scanner.addDevice(TestScale(deviceId: scaleId));
      async.flushMicrotasks();

      void sighting() {
        scanner.removeDevice(scaleId);
        scanner.addDevice(TestScale(deviceId: scaleId));
        async.flushMicrotasks();
      }

      expect(connectCalls, hasLength(1));
      expect(scanner.startWatchCallCount, 1);

      async.elapse(const Duration(milliseconds: 999));
      async.flushMicrotasks();
      expect(scanner.startWatchCallCount, 1);
      async.elapse(const Duration(milliseconds: 1));
      async.flushMicrotasks();
      expect(scanner.startWatchCallCount, 2);
      sighting();
      expect(connectCalls, hasLength(2));

      async.elapse(const Duration(milliseconds: 1999));
      async.flushMicrotasks();
      expect(scanner.startWatchCallCount, 2);
      async.elapse(const Duration(milliseconds: 1));
      async.flushMicrotasks();
      expect(scanner.startWatchCallCount, 3);
      sighting();
      expect(connectCalls, hasLength(3));

      async.elapse(const Duration(milliseconds: 4999));
      async.flushMicrotasks();
      expect(scanner.startWatchCallCount, 3);
      async.elapse(const Duration(milliseconds: 1));
      async.flushMicrotasks();
      expect(scanner.startWatchCallCount, 4);
      sighting();
      expect(connectCalls, hasLength(4));

      async.elapse(const Duration(milliseconds: 14999));
      async.flushMicrotasks();
      expect(scanner.startWatchCallCount, 4);
      async.elapse(const Duration(milliseconds: 1));
      async.flushMicrotasks();
      expect(scanner.startWatchCallCount, 5);
      sighting();
      expect(connectCalls, hasLength(5));

      async.elapse(const Duration(milliseconds: 14999));
      async.flushMicrotasks();
      expect(scanner.startWatchCallCount, 5);
      async.elapse(const Duration(milliseconds: 1));
      async.flushMicrotasks();
      expect(scanner.startWatchCallCount, 6);
    });
  });

  test('cancellation clears retry work and success resets its delay', () {
    fakeAsync((async) {
      connectSucceeds = false;
      watch.arm();
      async.flushMicrotasks();
      scanner.addDevice(TestScale(deviceId: scaleId));
      async.flushMicrotasks();
      expect(connectCalls, hasLength(1));

      watch.disarm();
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 30));
      async.flushMicrotasks();
      expect(connectCalls, hasLength(1));
      expect(scanner.startWatchCallCount, 1);

      gate = true;
      scanner.removeDevice(scaleId);
      watch.arm();
      async.flushMicrotasks();
      scanner.addDevice(TestScale(deviceId: scaleId));
      async.flushMicrotasks();
      expect(connectCalls, hasLength(2));

      async.elapse(const Duration(seconds: 1));
      async.flushMicrotasks();
      expect(scanner.startWatchCallCount, 3);
      connectSucceeds = true;
      scanner.removeDevice(scaleId);
      scanner.addDevice(TestScale(deviceId: scaleId));
      async.flushMicrotasks();
      expect(connectCalls, hasLength(3));
      expect(watch.armed, isFalse);

      gate = true;
      connectSucceeds = false;
      scanner.removeDevice(scaleId);
      watch.arm();
      async.flushMicrotasks();
      scanner.addDevice(TestScale(deviceId: scaleId));
      async.flushMicrotasks();
      expect(connectCalls, hasLength(4));
      expect(scanner.startWatchCallCount, 4);
      async.elapse(const Duration(seconds: 1));
      async.flushMicrotasks();
      expect(scanner.startWatchCallCount, 5);
    });
  });

  test('concurrent sightings coalesce into one connect', () async {
    connectGate = Completer<void>();
    await watch.arm();
    scanner.addDevice(TestScale(deviceId: scaleId));
    await pump();
    scanner.removeDevice(scaleId);
    scanner.addDevice(TestScale(deviceId: scaleId));
    await pump();

    expect(
      connectCalls,
      hasLength(1),
      reason: 'in-flight connect must swallow repeat sightings',
    );
    connectGate!.complete();
    await pump();
  });

  test(
    'a pending lower-level watch stays unarmed until it becomes active',
    () async {
      final startGate = Completer<void>();
      scanner.holdNextWatchStart = startGate;
      final arming = watch.arm();
      await pump();

      expect(watch.armed, isFalse);
      expect(scanner.startWatchCallCount, 1);

      startGate.complete();
      await arming;

      expect(watch.armed, isTrue);
    },
  );

  test('disarm during a pending start leaves no active watch', () async {
    final startGate = Completer<void>();
    scanner.holdNextWatchStart = startGate;
    final arming = watch.arm();
    await pump();
    final disarming = watch.disarm();

    startGate.complete();
    await arming;
    await disarming;
    await pump();

    expect(watch.armed, isFalse);
    expect(scanner.watchActive, isFalse);
    expect(scanner.stopWatchCallCount, 1);
  });

  test(
    'disarm during handover stop cancels the claim before connecting',
    () async {
      scanner.stopGate = Completer<void>();
      await watch.arm();
      scanner.addDevice(TestScale(deviceId: scaleId));
      await pump();

      expect(scanner.claimCalls, 1);
      final disarming = watch.disarm();
      await pump();
      expect(scanner.cancelCalls, 1);
      expect(connectCalls, isEmpty);

      scanner.stopGate!.complete();
      await disarming;
      await pump();
      expect(connectCalls, isEmpty);
      expect(watch.armed, isFalse);
    },
  );

  test('stop failure during a sighting prevents the connect attempt', () async {
    scanner.failNextWatchStopWith = Exception('stop denied');
    await watch.arm();
    scanner.addDevice(TestScale(deviceId: scaleId));
    await pump();

    expect(connectCalls, isEmpty);
    expect(unavailableCalls, 1);
    expect(watch.armed, isFalse);
  });

  test(
    'startScaleWatch failure reports watch-unavailable and stays disarmed',
    () async {
      scanner.failNextWatchWith = Exception('no watch for you');
      await watch.arm();

      expect(unavailableCalls, 1);
      expect(watch.armed, isFalse);
    },
  );

  test('disarm stops the watch and is idempotent', () async {
    await watch.arm();
    expect(scanner.watchActive, isTrue);

    await watch.disarm();
    expect(watch.armed, isFalse);
    expect(scanner.watchActive, isFalse);

    await watch.disarm();
    expect(scanner.stopWatchCallCount, 1);
  });

  test('disarm before arm is safe', () async {
    await watch.disarm();
    expect(scanner.stopWatchCallCount, 0);
  });

  test(
    'disarm during an in-flight connect does not resurrect the watch',
    () async {
      connectSucceeds = false;
      connectGate = Completer<void>();
      await watch.arm();
      scanner.addDevice(TestScale(deviceId: scaleId));
      await pump();
      expect(connectCalls, hasLength(1));

      await watch.disarm();
      connectGate!.complete();
      await pump();

      expect(watch.armed, isFalse);
      expect(
        scanner.startWatchCallCount,
        1,
        reason:
            'a connect completing after disarm must not restart the '
            'watch (generation token)',
      );
    },
  );

  test(
    'disarm racing a replacement start leaves no watch or subscriptions',
    () async {
      connectSucceeds = false;
      await watch.arm();
      scanner.addDevice(TestScale(deviceId: scaleId));
      await pump();

      final restartGate = Completer<void>();
      scanner.holdNextWatchStart = restartGate;
      scanner.removeDevice(scaleId);
      scanner.addDevice(TestScale(deviceId: scaleId));
      await pump();

      final disarming = watch.disarm();
      restartGate.complete();
      await disarming;
      await pump();

      expect(watch.armed, isFalse);
      expect(scanner.watchActive, isFalse);
      expect(watch.diagnostics['deviceSubscriptionInstalled'], isFalse);
      expect(watch.diagnostics['failureSubscriptionInstalled'], isFalse);
    },
  );

  test('re-arm after disarm starts a fresh watch', () async {
    await watch.arm();
    await watch.disarm();
    await watch.arm();

    expect(scanner.startWatchCallCount, 2);
    expect(watch.armed, isTrue);

    scanner.addDevice(TestScale(deviceId: scaleId));
    await pump();
    expect(
      connectCalls,
      hasLength(1),
      reason: 'the re-armed watch must still react to sightings',
    );
  });

  test(
    'a watch-failure event disarms and falls back to legacy reconnect',
    () async {
      await watch.arm();
      expect(watch.armed, isTrue);

      scanner.emitWatchFailure();
      await pump();

      expect(
        watch.armed,
        isFalse,
        reason:
            'a dead watch must not stay armed — that leaves scale '
            'reacquisition silently off',
      );
      expect(
        unavailableCalls,
        1,
        reason: 'the legacy backoff loop must take over',
      );
    },
  );

  test('watch-failure events after disarm are ignored', () async {
    await watch.arm();
    await watch.disarm();

    scanner.emitWatchFailure();
    await pump();

    expect(unavailableCalls, 0);
  });

  test('dispose stops the watch', () async {
    await watch.arm();
    await watch.dispose();
    expect(scanner.watchActive, isFalse);
    expect(watch.armed, isFalse);
  });
}
