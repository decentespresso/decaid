import 'dart:async';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/transport/ble_transport.dart';
import 'package:reaprime/src/plugins/plugin_ble_session.dart';
import '../helpers/completing_cancel_stream.dart';

class SessionTransport extends BLETransport {
  @override
  String get id => 'physical';
  @override
  String get name => 'Test';
  @override
  Stream<ConnectionState> get connectionState => CompletingCancelStream(states);
  final states = StreamController<ConnectionState>.broadcast(sync: true);
  final Map<String, void Function(Uint8List)> callbacks = {};
  final List<(String, String, bool)> writes = [];
  final List<String> unsubscribed = [];
  Completer<void>? nativeTeardown;
  Completer<void>? writeCompletion;
  bool disposed = false;
  @override
  Future<void> connect() async {}
  @override
  Future<void> disconnect() async {}
  @override
  Future<void> disconnectConfirmed() async => await nativeTeardown?.future;
  @override
  Future<void> dispose() async {
    disposed = true;
    unawaited(states.close());
  }

  @override
  Future<ConnectionState> getConnectionState() async =>
      ConnectionState.connected;
  @override
  Future<List<String>> discoverServices() async => ['0ffe'];
  @override
  Future<void> setTransportPriority(bool prioritized) async {}
  @override
  Future<Uint8List> read(
    String service,
    String characteristic, {
    Duration? timeout,
  }) async => Uint8List.fromList([1]);
  @override
  Future<void> write(
    String service,
    String characteristic,
    Uint8List data, {
    bool withResponse = true,
    Duration? timeout,
  }) async {
    writes.add((service, characteristic, withResponse));
    await writeCompletion?.future;
  }

  @override
  Future<void> subscribe(
    String service,
    String characteristic,
    void Function(Uint8List) callback,
  ) async {
    callbacks[characteristic] = callback;
    callback(Uint8List.fromList([7]));
  }

  @override
  Future<void> unsubscribe(String service, String characteristic) async {
    unsubscribed.add(characteristic);
    callbacks.remove(characteristic);
  }
}

const gattArgs = {'service': '0ffe', 'characteristic': 'ff11', 'data': 'AQ=='};

void main() {
  test(
    'normalizes UUIDs, preserves acknowledgement, and rejects foreign authority',
    () async {
      final transport = SessionTransport();
      final session = PluginBleSession(
        transport: transport,
        authorized: () => true,
        runtimeAlive: () => true,
      );
      await session.connect();
      await expectLater(
        session.call('foreign', 'write', gattArgs),
        throwsA(isA<PluginBleException>()),
      );
      expect(transport.writes, isEmpty);
      await session.call(session.id, 'write', {
        ...gattArgs,
        'withResponse': true,
      });
      expect(transport.writes.single, (
        '00000ffe-0000-1000-8000-00805f9b34fb',
        '0000ff11-0000-1000-8000-00805f9b34fb',
        true,
      ));
      expect(await session.call(session.id, 'read', gattArgs), 'AQ==');
      expect(await session.call(session.id, 'discoverServices', {}), [
        '00000ffe-0000-1000-8000-00805f9b34fb',
      ]);
      await session.retire();
      await session.closed;
    },
  );

  test(
    'retirement gives only its invocation cleanup authority and retains native ownership',
    () async {
      final transport = SessionTransport()..nativeTeardown = Completer<void>();
      final session = PluginBleSession(
        transport: transport,
        authorized: () => true,
        runtimeAlive: () => true,
      );
      await session.connect();
      session.markReady();
      String? cleanupAuthority;
      await session.retire(
        cleanup: (authority) async {
          cleanupAuthority = authority;
          expect(session.state, PluginBleSessionState.retiring);
          await expectLater(
            session.call(session.id, 'write', gattArgs),
            throwsA(isA<PluginBleException>()),
          );
          await expectLater(
            session.call(authority, 'subscribe', gattArgs),
            throwsA(isA<PluginBleException>()),
          );
          await session.call(authority, 'write', gattArgs);
        },
      );
      expect(session.state, PluginBleSessionState.revoked);
      await expectLater(
        session.call(cleanupAuthority!, 'write', gattArgs),
        throwsA(isA<PluginBleException>()),
      );
      expect(transport.disposed, isFalse);
      transport.nativeTeardown!.complete();
      await session.closed;
      expect(transport.disposed, isTrue);
      expect(session.state, PluginBleSessionState.closed);
    },
  );

  test('hanging cleanup is bounded without plugin cooperation', () {
    fakeAsync((async) {
      final session = PluginBleSession(
        transport: SessionTransport(),
        authorized: () => true,
        runtimeAlive: () => true,
        cleanupTimeout: const Duration(seconds: 1),
      );
      session.connect();
      async.flushMicrotasks();
      session.retire(cleanup: (_) => Completer<void>().future);
      async.flushMicrotasks();
      expect(session.state, PluginBleSessionState.retiring);
      async.elapse(const Duration(seconds: 1));
      async.flushMicrotasks();
      expect(session.state, PluginBleSessionState.closed);
    });
  });

  test(
    'throwing cleanup, repeated disconnect and revoked runtime still clean native resources',
    () async {
      final transport = SessionTransport();
      var cleanupCalls = 0;
      final session = PluginBleSession(
        transport: transport,
        authorized: () => true,
        runtimeAlive: () => true,
      );
      await session.connect();
      await session.retire(
        cleanup: (_) async {
          cleanupCalls++;
          throw StateError('cleanup');
        },
      );
      await session.retire(
        cleanup: (_) async {
          cleanupCalls++;
        },
      );
      await session.closed;
      expect(cleanupCalls, 1);
      expect(transport.disposed, isTrue);
    },
  );

  test(
    'permission loss causes no native operation and interrupts cleanup',
    () async {
      var permitted = true;
      final session = PluginBleSession(
        transport: SessionTransport(),
        authorized: () => permitted,
        runtimeAlive: () => true,
      );
      await session.connect();
      final retiring = session.retire(cleanup: (_) => Completer<void>().future);
      permitted = false;
      session.revoke();
      await retiring;
      await session.closed;
      await expectLater(
        session.call(session.id, 'write', gattArgs),
        throwsA(isA<PluginBleException>()),
      );
    },
  );

  test(
    'setup notifications are retained and old unsubscribe cannot remove replacement',
    () async {
      final events = <Map<String, dynamic>>[];
      final session = PluginBleSession(
        transport: SessionTransport(),
        authorized: () => true,
        runtimeAlive: () => true,
        eventSink: (event) async {
          events.add(event);
        },
      );
      await session.connect();
      final first = await session.call(session.id, 'subscribe', gattArgs);
      final second = await session.call(session.id, 'subscribe', gattArgs);
      await session.call(session.id, 'unsubscribe', {'subscription': first});
      expect(session.subscriptionCount, 1);
      expect(first, isNot(second));
      expect(
        events.where((event) => event['type'] == 'notification'),
        isNotEmpty,
      );
      await session.retire();
      await session.closed;
    },
  );

  test(
    'retirement settles pending callers once and fences late native completion',
    () async {
      final transport = SessionTransport()..writeCompletion = Completer<void>();
      final session = PluginBleSession(
        transport: transport,
        authorized: () => true,
        runtimeAlive: () => true,
      );
      await session.connect();
      final result = expectLater(
        session.call(session.id, 'write', gattArgs),
        throwsA(isA<PluginBleException>()),
      );
      await session.retire();
      await result;
      transport.writeCompletion!.complete();
      await session.closed;
      expect(session.state, PluginBleSessionState.closed);
    },
  );

  test(
    'payload and pending operation limits reject without native writes',
    () async {
      final transport = SessionTransport()..writeCompletion = Completer<void>();
      final session = PluginBleSession(
        transport: transport,
        authorized: () => true,
        runtimeAlive: () => true,
        maxPendingOperations: 1,
      );
      await session.connect();
      await expectLater(
        session.call(session.id, 'write', {...gattArgs, 'data': 'A' * 22000}),
        throwsA(isA<PluginBleException>()),
      );
      expect(transport.writes, isEmpty);
      final write = expectLater(
        session.call(session.id, 'write', gattArgs),
        throwsA(isA<PluginBleException>()),
      );
      await expectLater(
        session.call(session.id, 'read', gattArgs),
        throwsA(isA<PluginBleException>()),
      );
      await session.retire();
      transport.writeCompletion!.complete();
      await write;
      await session.closed;
    },
  );
}
