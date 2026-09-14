import 'dart:async';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/impl/decent_scale/scale.dart';
import 'package:reaprime/src/models/device/transport/ble_transport.dart';
import 'package:rxdart/rxdart.dart';

class _LifecycleBleTransport extends BLETransport {
  _LifecycleBleTransport({this.respondToVoltage = false});

  final BehaviorSubject<ConnectionState> _connectionState =
      BehaviorSubject.seeded(ConnectionState.disconnected);
  bool respondToVoltage;
  final writes = <Uint8List>[];
  void Function(Uint8List)? notificationCallback;
  int disconnectCalls = 0;

  @override
  String get id => 'decent-scale-lifecycle-test';

  @override
  String get name => 'Decent Scale Lifecycle Test';

  @override
  Stream<ConnectionState> get connectionState => _connectionState.stream;

  @override
  Future<ConnectionState> getConnectionState() async => _connectionState.value;

  @override
  Future<void> connect() async {
    _connectionState.add(ConnectionState.connected);
  }

  @override
  Future<void> disconnect() async {
    disconnectCalls++;
    _connectionState.add(ConnectionState.disconnected);
  }

  @override
  Future<List<String>> discoverServices() async => [
    DecentScale.serviceIdentifier.long,
  ];

  @override
  Future<void> subscribe(
    String serviceUUID,
    String characteristicUUID,
    void Function(Uint8List) callback,
  ) async {
    notificationCallback = callback;
  }

  @override
  Future<void> resetSubscription(
    String serviceUUID,
    String characteristicUUID,
    void Function(Uint8List) callback,
  ) async {
    notificationCallback = callback;
  }

  @override
  Future<Uint8List> read(
    String serviceUUID,
    String characteristicUUID, {
    Duration? timeout,
  }) async => Uint8List(0);

  @override
  Future<void> write(
    String serviceUUID,
    String characteristicUUID,
    Uint8List data, {
    bool withResponse = true,
    Duration? timeout,
  }) async {
    final frame = Uint8List.fromList(data);
    writes.add(frame);
    if (frame.length == 7 && frame[1] == 0x0A && frame[2] == 0x01) {
      scheduleMicrotask(
        () => emitNotification([0x03, 0x0A, 0x00, 0x00, 0x64, 0x01, 0x20]),
      );
    }
    if (frame.length == 7 && frame[1] == 0x22 && respondToVoltage) {
      scheduleMicrotask(
        () => emitNotification([0x03, 0x22, 0x00, 0x64, 0x00, 0x00, 0x00]),
      );
    }
  }

  @override
  Future<void> setTransportPriority(bool prioritized) async {}

  void emitNotification(List<int> data) {
    notificationCallback?.call(Uint8List.fromList(data));
  }

  @override
  Future<void> dispose() async {
    await _connectionState.close();
  }
}

bool _hasCommand(
  _LifecycleBleTransport transport,
  int command, [
  int? subcommand,
]) => transport.writes.any(
  (data) =>
      data.length >= 3 &&
      data[1] == command &&
      (subcommand == null || data[2] == subcommand),
);

Future<void> _connectAndSettle(
  DecentScale scale, {
  Duration timeout = const Duration(milliseconds: 900),
}) async {
  await scale.onConnect();
  await pumpEventQueue();
  await Future<void>.delayed(timeout);
  await pumpEventQueue();
}

Future<void> _disposeScale(
  DecentScale scale,
  _LifecycleBleTransport transport,
) async {
  await scale.disconnectForHandoff();
  await transport.dispose();
}

void main() {
  group('conservative profile lifecycle', () {
    test('unknown/original scale sleeps by disconnecting', () async {
      final transport = _LifecycleBleTransport();
      final scale = DecentScale(transport: transport);
      await _connectAndSettle(scale);

      expect(scale.disconnectsToSleep, isTrue);
      final disconnectsBeforeSleep = transport.disconnectCalls;
      await scale.sleepDisplay();

      expect(transport.disconnectCalls, disconnectsBeforeSleep + 1);
      expect(_hasCommand(transport, 0x0A, 0x04), isFalse);
      expect(_hasCommand(transport, 0x0A, 0x02), isFalse);
      await _disposeScale(scale, transport);
    });

    test('unknown/original scale recovers after sleep', () async {
      final transport = _LifecycleBleTransport();
      final scale = DecentScale(transport: transport);
      await _connectAndSettle(scale);
      await scale.sleepDisplay();

      await scale.onConnect();
      await scale.wakeDisplay();
      final snapshot = scale.currentSnapshot.first;
      transport.emitNotification([0x03, 0xCE, 0x00, 0x64, 0x00, 0x00, 0x00]);

      expect((await snapshot).weight, 10.0);
      await Future<void>.delayed(const Duration(milliseconds: 900));
      await pumpEventQueue();
      await _disposeScale(scale, transport);
    });

    test('late profile evidence after sleep is ignored', () async {
      final transport = _LifecycleBleTransport();
      final scale = DecentScale(transport: transport);
      await _connectAndSettle(scale);
      await scale.sleepDisplay();
      transport.writes.clear();

      transport.emitNotification([0x03, 0x22, 0x00, 0x64, 0x00, 0x00, 0x00]);

      expect(scale.disconnectsToSleep, isTrue);
      expect(_hasCommand(transport, 0x0A, 0x04), isFalse);
      await _disposeScale(scale, transport);
    });

    test('profile does not leak across connections', () async {
      final transport = _LifecycleBleTransport(respondToVoltage: true);
      final scale = DecentScale(transport: transport);
      await _connectAndSettle(scale);
      expect(scale.disconnectsToSleep, isFalse);
      await scale.disconnectForHandoff();

      transport.respondToVoltage = false;
      transport.writes.clear();
      await _connectAndSettle(scale);

      expect(scale.disconnectsToSleep, isTrue);
      await scale.sleepDisplay();
      expect(_hasCommand(transport, 0x0A, 0x04), isFalse);
      expect(transport.disconnectCalls, 2);
      await _disposeScale(scale, transport);
    });

    test(
      'explicit disconnect withholds power off from an unproven scale',
      () async {
        final transport = _LifecycleBleTransport(respondToVoltage: false);
        final scale = DecentScale(transport: transport);
        await _connectAndSettle(scale);
        transport.writes.clear();

        await scale.disconnect();

        expect(_hasCommand(transport, 0x0A, 0x02), isFalse);
        expect(transport.disconnectCalls, 1);
        await transport.dispose();
      },
    );
  });

  group('confirmed HDS lifecycle', () {
    test('confirmed HDS sleeps with SoftSleep without disconnecting', () async {
      final transport = _LifecycleBleTransport(respondToVoltage: true);
      final scale = DecentScale(transport: transport);
      await _connectAndSettle(scale);
      transport.writes.clear();

      expect(scale.disconnectsToSleep, isFalse);
      await scale.sleepDisplay();

      expect(transport.disconnectCalls, 0);
      expect(
        transport.writes,
        contains(orderedEquals([0x03, 0x0A, 0x04, 0x01, 0x00, 0x00, 0x0C])),
      );
      expect(
        transport.writes
            .where((data) => data[1] == 0x0A && data[2] == 0x04)
            .every((data) => data[4] == 0x00),
        isTrue,
      );
      await _disposeScale(scale, transport);
    });

    test('confirmed HDS wake writes SoftSleep exit', () async {
      final transport = _LifecycleBleTransport(respondToVoltage: true);
      final scale = DecentScale(transport: transport);
      await _connectAndSettle(scale);
      await scale.sleepDisplay();
      transport.writes.clear();

      await scale.wakeDisplay();
      await pumpEventQueue();

      expect(
        transport.writes,
        contains(orderedEquals([0x03, 0x0A, 0x04, 0x00, 0x00, 0x00, 0x0D])),
      );
      expect(
        transport.writes
            .where((data) => data[1] == 0x0A)
            .every((data) => data[4] == 0x00),
        isTrue,
      );
      await _disposeScale(scale, transport);
    });
  });

  group('command and maintenance safety', () {
    test('no heartbeat is sent by lifecycle or scale commands', () async {
      final transport = _LifecycleBleTransport(respondToVoltage: true);
      final scale = DecentScale(transport: transport);
      await _connectAndSettle(scale);

      await scale.tare();
      await scale.startTimer();
      await scale.stopTimer();
      await scale.resetTimer();
      await scale.sleepDisplay();
      await scale.wakeDisplay();
      await pumpEventQueue();

      expect(_hasCommand(transport, 0x0A, 0x03), isFalse);
      expect(
        transport.writes
            .where((data) => data[1] == 0x0A)
            .every((data) => data[4] == 0x00),
        isTrue,
      );
      expect(
        transport.writes,
        contains(orderedEquals([0x03, 0x0F, 0x00, 0x00, 0x00, 0x00, 0x0C])),
      );
      await _disposeScale(scale, transport);
    });

    test('maintenance is read-only', () {
      fakeAsync((async) {
        final transport = _LifecycleBleTransport(respondToVoltage: true);
        final scale = DecentScale(transport: transport);
        var connected = false;
        scale.onConnect().then((_) => connected = true);
        async.flushMicrotasks();
        expect(connected, isTrue);
        transport.writes.clear();

        for (var tick = 0; tick < 15; tick++) {
          async.elapse(const Duration(seconds: 4));
          async.flushMicrotasks();
          transport.emitNotification([
            0x03,
            0xCE,
            0x00,
            0x64,
            0x00,
            0x00,
            0x00,
          ]);
          async.flushMicrotasks();
        }

        expect(transport.writes, isEmpty);
        expect(transport.disconnectCalls, 0);
        expect(connected, isTrue);
        scale.disconnectForHandoff();
        async.flushMicrotasks();
        transport.dispose();
        async.flushMicrotasks();
      });
    });
  });
}
