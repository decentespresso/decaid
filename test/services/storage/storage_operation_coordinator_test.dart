import 'dart:async';
import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:reaprime/src/services/storage/hive_store_service.dart';
import 'package:reaprime/src/services/storage/storage_operation_coordinator.dart';

const _limits = StorageOperationLimits(
  operationTimeout: Duration(seconds: 5),
  drainTimeout: Duration(seconds: 5),
  maxOutstandingPerNamespace: 3,
);

Matcher _storageError(StorageErrorCode code) =>
    isA<StorageOperationException>().having((e) => e.code, 'code', code);

void main() {
  late StorageOperationCoordinator coordinator;

  setUp(() => coordinator = StorageOperationCoordinator(limits: _limits));

  test('default limits match the accepted contract', () {
    const defaults = StorageOperationLimits();
    expect(defaults.operationTimeout, const Duration(seconds: 5));
    expect(defaults.drainTimeout, const Duration(seconds: 5));
    expect(defaults.maxOutstandingPerNamespace, 32);
  });

  test('reads return values or null and writes succeed', () async {
    expect(await coordinator.read('p', 'k', () async => 'v'), 'v');
    expect(await coordinator.read('p', 'missing', () async => null), isNull);
    await coordinator.write('p', 'k', () async {});
    expect(coordinator.outstanding('p'), 0);
  });

  test('backend failures map to a safe storage error', () async {
    await expectLater(
      coordinator.read('p', 'k', () => throw StateError('secret /path')),
      throwsA(_storageError(StorageErrorCode.storageError)),
    );
    await expectLater(
      coordinator.write('p', 'k', () async => throw StateError('secret')),
      throwsA(_storageError(StorageErrorCode.storageError)),
    );
    expect(coordinator.outstanding('p'), 0);
    expect(coordinator.isQuarantined('p', 'k'), isFalse);
    expect(
      const StorageOperationException(StorageErrorCode.storageError).toString(),
      isNot(contains('secret')),
    );
  });

  test('a never-settling read times out but keeps its backend slot', () {
    fakeAsync((async) {
      final backend = Completer<Object?>();
      Object? error;
      coordinator.read('p', 'k', () => backend.future).catchError((Object e) {
        error = e;
        return null;
      });

      async.elapse(const Duration(seconds: 5));
      expect(error, _storageError(StorageErrorCode.timeout));
      expect(coordinator.outstanding('p'), 1);

      backend.complete('late');
      async.flushMicrotasks();
      expect(coordinator.outstanding('p'), 0);
    });
  });

  test('a timed-out write quarantines its key until it settles', () {
    fakeAsync((async) {
      final first = Completer<void>();
      final errors = <Object>[];
      coordinator
          .write('p', 'k', () => first.future)
          .catchError((Object e) => errors.add(e));

      async.elapse(const Duration(seconds: 5));
      expect(errors.single, _storageError(StorageErrorCode.writeIndeterminate));
      expect(coordinator.isQuarantined('p', 'k'), isTrue);

      var replacementIssued = false;
      coordinator
          .write('p', 'k', () async => replacementIssued = true)
          .catchError((Object e) => errors.add(e));
      async.flushMicrotasks();
      expect(errors.last, _storageError(StorageErrorCode.quarantined));
      expect(replacementIssued, isFalse);

      var otherKey = false;
      coordinator.write('p', 'other', () async => otherKey = true);
      async.flushMicrotasks();
      expect(otherKey, isTrue);

      first.complete();
      async.flushMicrotasks();
      expect(coordinator.isQuarantined('p', 'k'), isFalse);

      var resumed = false;
      coordinator.write('p', 'k', () async => resumed = true);
      async.flushMicrotasks();
      expect(resumed, isTrue);
    });
  });

  test('a failing late write also releases quarantine', () {
    fakeAsync((async) {
      final first = Completer<void>();
      coordinator.write('p', 'k', () => first.future).ignore();
      async.elapse(const Duration(seconds: 5));
      expect(coordinator.isQuarantined('p', 'k'), isTrue);

      first.completeError(StateError('disk full'));
      async.flushMicrotasks();
      expect(coordinator.isQuarantined('p', 'k'), isFalse);
      expect(coordinator.outstanding('p'), 0);
    });
  });

  test('writes to one key run in admission order', () {
    fakeAsync((async) {
      final calls = <String>[];
      final first = Completer<void>();
      coordinator.write('p', 'k', () {
        calls.add('first');
        return first.future;
      });
      coordinator.write('p', 'k', () async => calls.add('second'));
      async.flushMicrotasks();
      expect(calls, ['first']);

      first.complete();
      async.flushMicrotasks();
      expect(calls, ['first', 'second']);
    });
  });

  test('a queued write that times out before starting is never issued', () {
    fakeAsync((async) {
      final first = Completer<void>();
      coordinator.write('p', 'k', () => first.future).ignore();
      async.elapse(const Duration(seconds: 1));

      var issued = false;
      Object? error;
      coordinator.write('p', 'k', () async => issued = true).catchError((
        Object e,
      ) {
        error = e;
      });
      async.elapse(const Duration(seconds: 5));
      expect(error, _storageError(StorageErrorCode.timeout));

      first.complete();
      async.flushMicrotasks();
      expect(issued, isFalse);
      expect(coordinator.outstanding('p'), 0);
      expect(coordinator.isQuarantined('p', 'k'), isFalse);
    });
  });

  test('queued writes that give up release their budget', () {
    fakeAsync((async) {
      final shared = StorageOperationCoordinator();
      final calls = <int>[];
      shared.write('p', 'k', () => Completer<void>().future).ignore();
      for (var i = 0; i < 31; i++) {
        shared.write('p', 'k', () async => calls.add(i)).ignore();
      }
      expect(shared.outstanding('p'), 32);

      async.elapse(const Duration(seconds: 60));
      expect(shared.outstanding('p'), 1);
      expect(calls, isEmpty);
      Object? value;
      shared.read('p', 'other', () async => 'ok').then((v) => value = v);
      async.flushMicrotasks();
      expect(value, 'ok');
    });
  });

  test('a write queued behind abandoned writes keeps admission order', () {
    fakeAsync((async) {
      final head = Completer<void>();
      final calls = <String>[];
      coordinator.write('p', 'k', () {
        calls.add('head');
        return head.future;
      }).ignore();
      async.elapse(const Duration(seconds: 1));
      coordinator.write('p', 'k', () async => calls.add('abandoned')).ignore();
      async.elapse(const Duration(seconds: 3));
      coordinator.write('p', 'k', () async => calls.add('last'));
      async.elapse(const Duration(seconds: 2));
      expect(coordinator.outstanding('p'), 2);

      head.complete();
      async.flushMicrotasks();
      expect(calls, ['head', 'last']);
      expect(coordinator.outstanding('p'), 0);
    });
  });

  test('namespaces are matched case-insensitively like Hive box names', () {
    fakeAsync((async) {
      final write = Completer<void>();
      coordinator.write('Plugin.A', 'k', () => write.future).ignore();
      async.elapse(const Duration(seconds: 5));
      expect(coordinator.isQuarantined('plugin.a', 'k'), isTrue);
      expect(coordinator.outstanding('PLUGIN.A'), 1);

      Object? quarantined;
      coordinator
          .write('plugin.a', 'k', () async {})
          .catchError((Object e) => quarantined = e);
      Object? refused;
      coordinator
          .runMaintenance({'PLUGIN.a'}, () async {})
          .then(
            (_) {},
            onError: (Object e) {
              refused = e;
            },
          );
      async.elapse(const Duration(seconds: 5));
      expect(quarantined, _storageError(StorageErrorCode.quarantined));
      expect(refused, _storageError(StorageErrorCode.unresolvedWrites));

      write.complete();
      async.flushMicrotasks();
      final hold = Completer<void>();
      coordinator.runMaintenance({'Visualizer.Reaplugin'}, () => hold.future);
      async.flushMicrotasks();
      Object? guarded;
      coordinator
          .write('visualizer.reaplugin', 'k', () async {})
          .catchError((Object e) => guarded = e);
      async.flushMicrotasks();
      expect(guarded, _storageError(StorageErrorCode.maintenance));
      hold.complete();
      async.flushMicrotasks();
    });
  });

  test('outstanding backend work is bounded per namespace', () {
    fakeAsync((async) {
      final pending = Completer<Object?>();
      for (var i = 0; i < 3; i++) {
        coordinator.read('p', 'k$i', () => pending.future).ignore();
      }
      Object? readError;
      Object? writeError;
      coordinator
          .read('p', 'x', () async => 1)
          .catchError((Object e) => readError = e);
      coordinator
          .write('p', 'x', () async {})
          .catchError((Object e) => writeError = e);
      async.flushMicrotasks();
      expect(readError, _storageError(StorageErrorCode.capacity));
      expect(writeError, _storageError(StorageErrorCode.capacity));

      Object? other;
      coordinator.read('q', 'x', () async => 'ok').then((v) => other = v);
      async.flushMicrotasks();
      expect(other, 'ok');

      async.elapse(const Duration(seconds: 10));
      expect(coordinator.outstanding('p'), 3);
      pending.complete(null);
      async.flushMicrotasks();
      expect(coordinator.outstanding('p'), 0);
    });
  });

  group('maintenance', () {
    test('blocks new access and waits for pending writes', () {
      fakeAsync((async) {
        final write = Completer<void>();
        coordinator.write('p', 'k', () => write.future);
        var ran = false;
        coordinator.runMaintenance({'p'}, () async => ran = true);
        async.flushMicrotasks();

        final errors = <Object>[];
        coordinator
            .read('p', 'k', () async => 1)
            .then((_) {}, onError: errors.add);
        coordinator
            .write('p', 'j', () async {})
            .catchError((Object e) => errors.add(e));
        async.flushMicrotasks();
        expect(errors, [
          _storageError(StorageErrorCode.maintenance),
          _storageError(StorageErrorCode.maintenance),
        ]);
        expect(ran, isFalse);

        write.complete();
        async.flushMicrotasks();
        expect(ran, isTrue);

        Object? value;
        coordinator.read('p', 'k', () async => 'after').then((v) => value = v);
        async.flushMicrotasks();
        expect(value, 'after');
      });
    });

    test('refuses while a quarantined write stays unresolved', () {
      fakeAsync((async) {
        final write = Completer<void>();
        coordinator.write('p', 'k', () => write.future).ignore();
        async.elapse(const Duration(seconds: 5));
        expect(coordinator.isQuarantined('p', 'k'), isTrue);

        var ran = false;
        Object? error;
        coordinator
            .runMaintenance({'p'}, () async => ran = true)
            .then(
              (_) {},
              onError: (Object e) {
                error = e;
              },
            );
        async.elapse(const Duration(seconds: 5));
        expect(error, _storageError(StorageErrorCode.unresolvedWrites));
        expect(ran, isFalse);
        expect(coordinator.isQuarantined('p', 'k'), isTrue);

        Object? value;
        coordinator.read('p', 'k', () async => 'open').then((v) => value = v);
        async.flushMicrotasks();
        expect(value, 'open');
      });
    });

    test('ignores other namespaces and refuses overlapping guards', () {
      fakeAsync((async) {
        final other = Completer<void>();
        coordinator.write('q', 'k', () => other.future).ignore();
        final hold = Completer<void>();
        var ran = false;
        coordinator.runMaintenance({'p'}, () {
          ran = true;
          return hold.future;
        });
        async.flushMicrotasks();
        expect(ran, isTrue);

        Object? error;
        coordinator
            .runMaintenance({'p', 'r'}, () async {})
            .then(
              (_) {},
              onError: (Object e) {
                error = e;
              },
            );
        async.flushMicrotasks();
        expect(error, _storageError(StorageErrorCode.maintenance));

        hold.complete();
        async.flushMicrotasks();
        var second = false;
        coordinator.runMaintenance({'p', 'r'}, () async => second = true);
        async.flushMicrotasks();
        expect(second, isTrue);
      });
    });

    test('a failed action releases the guard and propagates', () async {
      await expectLater(
        coordinator.runMaintenance({'p'}, () async => throw StateError('x')),
        throwsStateError,
      );
      expect(await coordinator.read('p', 'k', () async => 1), 1);
    });
  });

  group('persisted ordering', () {
    late Directory dir;
    late HiveStoreService store;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('storage_ordering');
      Hive.init(dir.path);
      store = HiveStoreService(defaultNamespace: 'ordering');
      await store.initialize();
      coordinator = StorageOperationCoordinator(
        limits: const StorageOperationLimits(
          operationTimeout: Duration(milliseconds: 500),
          drainTimeout: Duration(milliseconds: 500),
        ),
      );
    });

    tearDown(() async {
      await Hive.close();
      await dir.delete(recursive: true);
    });

    test('a late old write cannot overwrite a newer accepted write', () async {
      final gate = Completer<void>();
      await expectLater(
        coordinator.write('p', 'k', () async {
          await gate.future;
          await store.set(namespace: 'p', key: 'k', value: 'old');
        }),
        throwsA(_storageError(StorageErrorCode.writeIndeterminate)),
      );

      await expectLater(
        coordinator.write(
          'p',
          'k',
          () => store.set(namespace: 'p', key: 'k', value: 'refused'),
        ),
        throwsA(_storageError(StorageErrorCode.quarantined)),
      );

      gate.complete();
      while (coordinator.isQuarantined('p', 'k')) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(await store.get(namespace: 'p', key: 'k'), 'old');

      await coordinator.write(
        'p',
        'k',
        () => store.set(namespace: 'p', key: 'k', value: 'new'),
      );
      await Hive.close();
      Hive.init(dir.path);
      final reopened = HiveStoreService(defaultNamespace: 'ordering');
      await reopened.initialize();
      expect(await reopened.get(namespace: 'p', key: 'k'), 'new');
    });
  });
}
