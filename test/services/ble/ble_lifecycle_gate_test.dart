import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/services/ble/ble_lifecycle_gate.dart';

void main() {
  test('serializes normalized device ids', () async {
    final gate = BleLifecycleGate();
    final firstStarted = Completer<void>();
    final releaseFirst = Completer<void>();
    var active = 0;
    var peak = 0;

    Future<void> operation(Completer<void>? blocker) async {
      active++;
      peak = active > peak ? active : peak;
      if (!firstStarted.isCompleted) firstStarted.complete();
      if (blocker != null) await blocker.future;
      active--;
    }

    final first = gate.run('AA:BB', () => operation(releaseFirst));
    await firstStarted.future;
    final second = gate.run('aa:bb', () => operation(null));
    await Future<void>.delayed(Duration.zero);
    expect(active, 1);
    releaseFirst.complete();
    await Future.wait([first, second]);
    expect(peak, 1);
  });

  test('allows different device ids concurrently', () async {
    final gate = BleLifecycleGate();
    final release = Completer<void>();
    var active = 0;

    Future<void> operation() async {
      active++;
      await release.future;
      active--;
    }

    final first = gate.run('a', operation);
    final second = gate.run('b', operation);
    await Future<void>.delayed(Duration.zero);
    expect(active, 2);
    release.complete();
    await Future.wait([first, second]);
  });

  test('cancels a queued connection', () async {
    final gate = BleLifecycleGate();
    final firstStarted = Completer<void>();
    final releaseFirst = Completer<void>();
    final queuedStarted = Completer<void>();

    final first = gate.run('AA:BB', () async {
      firstStarted.complete();
      await releaseFirst.future;
    });
    await firstStarted.future;
    final queued = gate.runConnection('aa:bb', (_) async {
      queuedStarted.complete();
    });

    gate.cancelConnectionAttempts('AA:BB');
    releaseFirst.complete();
    await first;

    await expectLater(queued, throwsA(isA<BleConnectionAttemptCancelled>()));
    expect(queuedStarted.isCompleted, isFalse);
  });
}
