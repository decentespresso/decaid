import 'dart:async';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/impl/decent_scale/scale.dart';
import 'package:reaprime/src/models/device/scale.dart';
import 'package:reaprime/src/models/device/transport/ble_transport.dart';
import 'package:reaprime/src/models/errors.dart';
import 'package:rxdart/rxdart.dart';

class _IntegrityTransport extends BLETransport {
  final _connectionState = BehaviorSubject.seeded(ConnectionState.discovered);
  final writes = <Uint8List>[];
  ConnectionState _nativeState = ConnectionState.disconnected;
  void Function(Uint8List)? _notificationCallback;
  Completer<void>? blockedWrite;
  final blockedSubscriptions = <int, Completer<void>>{};
  Object? writeError;
  int connectCalls = 0;
  int subscribeCalls = 0;

  @override
  String get id => 'decent-integrity';

  @override
  String get name => 'Decent Integrity';

  @override
  Stream<ConnectionState> get connectionState => _connectionState.stream;

  @override
  Future<ConnectionState> getConnectionState() async => _nativeState;

  @override
  Future<void> connect() async {
    connectCalls++;
    _nativeState = ConnectionState.connected;
    _connectionState.add(ConnectionState.connected);
  }

  @override
  Future<void> disconnect() async {
    _nativeState = ConnectionState.disconnected;
    _connectionState.add(ConnectionState.disconnected);
  }

  @override
  Future<List<String>> discoverServices() async => [
    DecentScale.serviceIdentifier.long,
  ];

  @override
  Future<Uint8List> read(
    String serviceUUID,
    String characteristicUUID, {
    Duration? timeout,
  }) async => Uint8List(0);

  @override
  Future<void> subscribe(
    String serviceUUID,
    String characteristicUUID,
    void Function(Uint8List) callback,
  ) async {
    subscribeCalls++;
    final blocked = blockedSubscriptions[subscribeCalls];
    if (blocked != null) await blocked.future;
    _notificationCallback = callback;
  }

  @override
  Future<void> resetSubscription(
    String serviceUUID,
    String characteristicUUID,
    void Function(Uint8List) callback,
  ) => subscribe(serviceUUID, characteristicUUID, callback);

  @override
  Future<void> setTransportPriority(bool prioritized) async {}

  @override
  Future<void> write(
    String serviceUUID,
    String characteristicUUID,
    Uint8List data, {
    bool withResponse = true,
    Duration? timeout,
  }) async {
    writes.add(Uint8List.fromList(data));
    final blocked = blockedWrite;
    if (blocked != null) await blocked.future;
    final error = writeError;
    if (error != null) throw error;
    if (data.length == 7 && data[1] == 0x0A && data[2] == 0x01) {
      scheduleMicrotask(() => emitNotification([0x03, 0x0A, 0, 0, 100, 0, 0]));
    }
  }

  void emitNotification(List<int> data) {
    _notificationCallback!(Uint8List.fromList(data));
  }

  @override
  Future<void> dispose() async {
    await _connectionState.close();
  }
}

void main() {
  test(
    'weight frames require a verified command and complete length',
    () async {
      final transport = _IntegrityTransport();
      final scale = DecentScale(transport: transport);
      await scale.onConnect();
      final snapshots = <ScaleSnapshot>[];
      final subscription = scale.currentSnapshot.listen(snapshots.add);

      for (final command in [0xCE, 0xCA]) {
        for (final length in [7, 10]) {
          transport.emitNotification([
            0x03,
            command,
            0xFF,
            0x9C,
            ...List<int>.filled(length - 4, 0),
          ]);
        }
      }
      for (final data in [
        [0x03, 0xCE, 0, 100],
        [0x03, 0xCE, 0, 100, 0],
        [0x03, 0xCE, 0, 100, 0, 0],
        [0x04, 0xCE, 0, 100, 0, 0, 0],
        [0x03, 0xAA, 0, 100, 0, 0, 0],
      ]) {
        expect(() => transport.emitNotification(data), returnsNormally);
      }
      await Future<void>.delayed(Duration.zero);

      expect(snapshots, hasLength(4));
      expect(snapshots.every((snapshot) => snapshot.weight == -10), isTrue);
      await subscription.cancel();
      await scale.disconnectForHandoff();
      await transport.dispose();
    },
  );

  test('maintenance performs no periodic writes', () {
    fakeAsync((async) {
      final transport = _IntegrityTransport();
      final scale = DecentScale(transport: transport);
      scale.onConnect();
      async.flushMicrotasks();
      async.elapse(const Duration(milliseconds: 100));
      async.flushMicrotasks();
      transport.writes.clear();

      async.elapse(const Duration(seconds: 30));
      async.flushMicrotasks();

      expect(transport.writes, isEmpty);
      expect(transport.subscribeCalls, greaterThanOrEqualTo(2));
      scale.disconnectForHandoff();
      async.flushMicrotasks();
      transport.dispose();
    });
  });

  test('maintenance failures stay contained', () {
    for (final failure in <Object>[
      TimeoutException('timeout'),
      const DeviceNotConnectedException.scale(),
      StateError('transport'),
    ]) {
      fakeAsync((async) {
        final uncaught = <Object>[];
        runZonedGuarded(() {
          final transport = _IntegrityTransport();
          final scale = DecentScale(transport: transport);
          scale.onConnect();
          async.flushMicrotasks();
          async.elapse(const Duration(milliseconds: 100));
          async.flushMicrotasks();
          transport.writeError = failure;
          async.elapse(const Duration(seconds: 8));
          async.flushMicrotasks();
          scale.disconnectForHandoff();
          async.flushMicrotasks();
          transport.dispose();
        }, (error, stack) => uncaught.add(error));
        expect(uncaught, isEmpty);
      });
    }
  });

  test('public commands report disconnected writes', () async {
    for (final command in <Future<void> Function(DecentScale)>[
      (scale) => scale.tare(),
      (scale) => scale.startTimer(),
      (scale) => scale.stopTimer(),
      (scale) => scale.resetTimer(),
    ]) {
      final transport = _IntegrityTransport();
      final scale = DecentScale(transport: transport);
      await scale.onConnect();
      transport.writeError = const DeviceNotConnectedException.scale();
      await expectLater(
        command(scale),
        throwsA(isA<DeviceNotConnectedException>()),
      );
      transport.writeError = null;
      await scale.disconnectForHandoff();
      await transport.dispose();
    }
  });

  test('notification recovery stays single-flight after disconnect', () {
    fakeAsync((async) {
      final transport = _IntegrityTransport();
      final scale = DecentScale(transport: transport);
      scale.onConnect();
      async.flushMicrotasks();
      async.elapse(const Duration(milliseconds: 100));
      async.flushMicrotasks();
      transport.blockedSubscriptions[2] = Completer<void>();

      async.elapse(const Duration(seconds: 20));
      async.flushMicrotasks();
      expect(transport.subscribeCalls, 2);

      scale.disconnectForHandoff();
      async.flushMicrotasks();
      transport.blockedSubscriptions[2]!.complete();
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 20));
      async.flushMicrotasks();
      expect(transport.subscribeCalls, 2);
      transport.dispose();
    });
  });

  test('reconnect waits for stale pending subscription', () {
    fakeAsync((async) {
      final transport = _IntegrityTransport();
      final scale = DecentScale(transport: transport);
      scale.onConnect();
      async.flushMicrotasks();
      async.elapse(const Duration(milliseconds: 100));
      async.flushMicrotasks();
      transport.blockedSubscriptions[2] = Completer<void>();

      async.elapse(const Duration(seconds: 5));
      async.flushMicrotasks();
      expect(transport.subscribeCalls, 2);

      scale.disconnectForHandoff();
      async.flushMicrotasks();
      scale.onConnect();
      async.flushMicrotasks();
      async.elapse(const Duration(milliseconds: 100));
      async.flushMicrotasks();
      expect(transport.connectCalls, 1);
      expect(transport.subscribeCalls, 2);

      transport.blockedSubscriptions[2]!.complete();
      async.flushMicrotasks();
      async.elapse(const Duration(milliseconds: 100));
      async.flushMicrotasks();
      expect(transport.connectCalls, 2);
      expect(transport.subscribeCalls, 3);

      scale.disconnectForHandoff();
      async.flushMicrotasks();
      transport.dispose();
    });
  });
}
