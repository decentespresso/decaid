import 'dart:async';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/impl/decent_scale/protocol.dart';
import 'package:reaprime/src/models/device/impl/decent_scale/scale.dart';
import 'package:reaprime/src/models/device/transport/ble_transport.dart';
import 'package:reaprime/src/models/errors.dart';
import 'package:rxdart/rxdart.dart';

class _ReliabilityBleTransport extends BLETransport {
  _ReliabilityBleTransport({
    this.initialNotifications = const [
      [0x03, 0x0A, 0x00, 0x00, 100, 0x00, 0x00],
    ],
    this.respondToVoltageProbe = false,
    this.hangVoltageProbe = false,
    this.writeError,
    this.disconnectOnDeviceNotConnectedWrite = true,
  });

  final List<List<int>> initialNotifications;
  final bool respondToVoltageProbe;
  final bool hangVoltageProbe;
  Object? Function(Uint8List data, int writeNumber)? writeError;
  final bool disconnectOnDeviceNotConnectedWrite;
  final _connectionState = BehaviorSubject<ConnectionState>.seeded(
    ConnectionState.disconnected,
  );
  final writes = <Uint8List>[];
  void Function(Uint8List)? notificationCallback;
  int subscribeCalls = 0;
  int resetSubscriptionCalls = 0;
  int disconnectCalls = 0;
  ConnectionState nativeState = ConnectionState.disconnected;

  @override
  String get id => 'decent-scale-reliability-test';

  @override
  String get name => 'Decent Scale Reliability Test';

  @override
  Stream<ConnectionState> get connectionState => _connectionState.stream;

  @override
  Future<ConnectionState> getConnectionState() async => nativeState;

  @override
  Future<void> connect() async {
    nativeState = ConnectionState.connected;
    _connectionState.add(ConnectionState.connected);
  }

  @override
  Future<void> disconnect() async {
    disconnectCalls++;
    nativeState = ConnectionState.disconnected;
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
    subscribeCalls++;
    notificationCallback = callback;
  }

  @override
  Future<void> resetSubscription(
    String serviceUUID,
    String characteristicUUID,
    void Function(Uint8List) callback,
  ) async {
    resetSubscriptionCalls++;
    await subscribe(serviceUUID, characteristicUUID, callback);
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
    final error = writeError?.call(frame, writes.length);
    if (error != null) {
      if (error is DeviceNotConnectedException &&
          disconnectOnDeviceNotConnectedWrite) {
        nativeState = ConnectionState.disconnected;
        _connectionState.add(ConnectionState.disconnected);
      }
      throw error;
    }
    if (frame[1] == 0x0A && frame[2] == 0x01) {
      for (final notification in initialNotifications) {
        scheduleMicrotask(() => emitNotification(notification));
      }
    }
    if (frame[1] == 0x22 && hangVoltageProbe) {
      await Completer<void>().future;
    }
    if (frame[1] == 0x22 && respondToVoltageProbe) {
      scheduleMicrotask(
        () => emitNotification([0x03, 0x22, 0x01, 0x89, 0x00, 0x00, 0xA9]),
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

List<Uint8List> _commandWrites(
  _ReliabilityBleTransport transport,
  int command,
  int subcommand,
) => transport.writes
    .where(
      (data) => data.length == 7 && data[1] == command && data[2] == subcommand,
    )
    .toList();

void _elapse(FakeAsync async, Duration duration) {
  async.elapse(duration);
  async.flushMicrotasks();
}

void _settleConnection(
  FakeAsync async,
  DecentScale scale,
  _ReliabilityBleTransport transport,
) {
  var connected = false;
  scale.connectionState.listen((state) {
    if (state == ConnectionState.connected) connected = true;
  });
  scale.onConnect();
  async.flushMicrotasks();
  expect(connected, isTrue);
  expect(
    transport.writes,
    contains(orderedEquals([0x03, 0x0A, 0x01, 0x01, 0x00, 0x00, 0x09])),
  );
  _elapse(async, const Duration(milliseconds: 900));
}

void _close(
  FakeAsync async,
  DecentScale scale,
  _ReliabilityBleTransport transport,
) {
  scale.disconnectForHandoff();
  async.flushMicrotasks();
  transport.dispose();
  async.flushMicrotasks();
}

void main() {
  group('original-firmware command tolerance', () {
    test('duplicates tare by 50ms and advances the logical tare counter', () {
      fakeAsync((async) {
        final transport = _ReliabilityBleTransport(
          initialNotifications: const [
            [0x03, 0x0A, 0x00, 0x00, 100, 0xFE, 0x00],
            [0x03, 0xCE, 0x00, 100, 0x00, 0x00, 0x00],
          ],
        );
        final scale = DecentScale(transport: transport);
        _settleConnection(async, scale, transport);
        transport.writes.clear();

        var complete = false;
        scale.tare().then((_) => complete = true);
        async.flushMicrotasks();
        final first = _commandWrites(transport, 0x0F, 0x00);
        expect(first, hasLength(1));
        expect(
          first.single,
          orderedEquals(
            buildDecentScaleCommand([0x0F, 0x00, 0x00, 0x00, 0x00]),
          ),
        );

        _elapse(async, const Duration(milliseconds: 49));
        expect(_commandWrites(transport, 0x0F, 0x00), hasLength(1));
        expect(complete, isFalse);
        _elapse(async, const Duration(milliseconds: 1));

        final tareWrites = _commandWrites(transport, 0x0F, 0x00);
        expect(tareWrites, hasLength(2));
        expect(tareWrites[1], orderedEquals(tareWrites[0]));
        expect(complete, isTrue);

        transport.writes.clear();
        scale.tare();
        async.flushMicrotasks();
        expect(_commandWrites(transport, 0x0F, 0x01), hasLength(1));
        _elapse(async, const Duration(milliseconds: 50));
        final secondTareWrites = _commandWrites(transport, 0x0F, 0x01);
        expect(secondTareWrites, hasLength(2));
        expect(secondTareWrites[1], orderedEquals(secondTareWrites[0]));
        _close(async, scale, transport);
      });
    });

    test('duplicates each timer command on the conservative profile', () {
      fakeAsync((async) {
        final transport = _ReliabilityBleTransport();
        final scale = DecentScale(transport: transport);
        _settleConnection(async, scale, transport);
        transport.writes.clear();

        void check(Future<void> Function() operation, int subcommand) {
          operation();
          async.flushMicrotasks();
          expect(_commandWrites(transport, 0x0B, subcommand), hasLength(1));
          _elapse(async, const Duration(milliseconds: 50));
          final frames = _commandWrites(transport, 0x0B, subcommand);
          expect(frames, hasLength(2));
          expect(
            frames[0],
            orderedEquals(buildDecentScaleCommand([0x0B, subcommand, 0, 0, 0])),
          );
          expect(frames[1], orderedEquals(frames[0]));
        }

        check(scale.startTimer, 0x03);
        check(scale.stopTimer, 0x00);
        check(scale.resetTimer, 0x02);
        _close(async, scale, transport);
      });
    });
  });

  group('reliable profiles', () {
    test('records one tare for original v1.1', () {
      fakeAsync((async) {
        final transport = _ReliabilityBleTransport(
          initialNotifications: const [
            [0x03, 0x0A, 0x00, 0x00, 100, 0x02, 0x00],
          ],
        );
        final scale = DecentScale(transport: transport);
        _settleConnection(async, scale, transport);
        transport.writes.clear();

        scale.tare();
        async.flushMicrotasks();
        _elapse(async, const Duration(milliseconds: 50));
        expect(_commandWrites(transport, 0x0F, 0x00), hasLength(1));
        _close(async, scale, transport);
      });
    });

    test('records one tare for original v1.2 marker and powers off', () async {
      final transport = _ReliabilityBleTransport(
        initialNotifications: const [
          [0x03, 0x0A, 0x00, 0x00, 100, 0x03, 0x00],
        ],
      );
      final scale = DecentScale(transport: transport);
      await scale.onConnect();
      await pumpEventQueue();
      await Future<void>.delayed(const Duration(milliseconds: 900));
      transport.writes.clear();

      await scale.tare();
      expect(_commandWrites(transport, 0x0F, 0x00), hasLength(1));
      await scale.disconnect();
      expect(_commandWrites(transport, 0x0A, 0x02), hasLength(1));
      await transport.dispose();
    });

    test('does not duplicate tare for a v1.2 timestamped profile', () {
      fakeAsync((async) {
        final transport = _ReliabilityBleTransport(
          initialNotifications: const [
            [0x03, 0x0A, 0x00, 0x00, 100, 0x01, 0x00],
            [0x03, 0xCE, 0x00, 100, 0x00, 0x00, 0x00, 0x00, 0x00, 0xA9],
          ],
        );
        final scale = DecentScale(transport: transport);
        _settleConnection(async, scale, transport);
        transport.writes.clear();

        scale.tare();
        async.flushMicrotasks();
        _elapse(async, const Duration(milliseconds: 50));
        expect(_commandWrites(transport, 0x0F, 0x00), hasLength(1));
        _close(async, scale, transport);
      });
    });

    test('does not duplicate tare for an HDS voltage response', () {
      fakeAsync((async) {
        final transport = _ReliabilityBleTransport(respondToVoltageProbe: true);
        final scale = DecentScale(transport: transport);
        _settleConnection(async, scale, transport);
        transport.writes.clear();

        scale.tare();
        async.flushMicrotasks();
        expect(_commandWrites(transport, 0x0F, 0x00), hasLength(1));
        _close(async, scale, transport);
      });
    });
  });

  test('hanging voltage probe is bounded and keeps the link connected', () {
    fakeAsync((async) {
      final transport = _ReliabilityBleTransport(hangVoltageProbe: true);
      final scale = DecentScale(transport: transport);
      final errors = <Object>[];
      runZonedGuarded(() {
        scale.onConnect();
      }, (error, stack) => errors.add(error));
      async.flushMicrotasks();
      _elapse(async, const Duration(milliseconds: 900));
      expect(transport.nativeState, ConnectionState.connected);
      expect(scale.debugCompletedNegotiations, 1);
      expect(errors, isEmpty);
      _close(async, scale, transport);
    });
  });

  test('nonessential voltage probe failure keeps a healthy link connected', () {
    fakeAsync((async) {
      final transport = _ReliabilityBleTransport(
        writeError: (data, _) => data[1] == 0x22
            ? TimeoutException('voltage probe timed out')
            : null,
      );
      final scale = DecentScale(transport: transport);
      _settleConnection(async, scale, transport);
      expect(transport.nativeState, ConnectionState.connected);
      expect(transport.disconnectCalls, 0);
      expect(_commandWrites(transport, 0x22, 0x00), hasLength(1));

      double? weight;
      scale.currentSnapshot.first.then((snapshot) => weight = snapshot.weight);
      transport.emitNotification([0x03, 0xCE, 0x00, 100, 0x00, 0x00, 0x00]);
      async.flushMicrotasks();
      expect(weight, 10);
      expect(transport.nativeState, ConnectionState.connected);
      expect(transport.disconnectCalls, 0);
      _close(async, scale, transport);
    });
  });

  test(
    'disconnected initialization fails loudly without publishing connected',
    () async {
      final transport = _ReliabilityBleTransport(
        writeError: (data, _) => data[1] == 0x0A && data[2] == 0x01
            ? const DeviceNotConnectedException.scale()
            : null,
      );
      final scale = DecentScale(transport: transport);
      final states = <ConnectionState>[];
      final subscription = scale.connectionState.listen(states.add);

      await expectLater(
        scale.onConnect(),
        throwsA(isA<DeviceNotConnectedException>()),
      );
      expect(
        await transport.getConnectionState(),
        ConnectionState.disconnected,
      );
      expect(states, isNot(contains(ConnectionState.connected)));
      expect(transport.disconnectCalls, greaterThanOrEqualTo(1));
      await scale.disconnectForHandoff();
      await subscription.cancel();
      await transport.dispose();
    },
  );

  test('required commands report disconnected write failures', () async {
    final transport = _ReliabilityBleTransport(
      respondToVoltageProbe: true,
      disconnectOnDeviceNotConnectedWrite: false,
    );
    final scale = DecentScale(transport: transport);
    await scale.onConnect();
    await pumpEventQueue();
    transport.writes.clear();
    transport.writeError = (data, _) =>
        const DeviceNotConnectedException.scale();

    for (final operation in [
      scale.tare,
      scale.startTimer,
      scale.stopTimer,
      scale.resetTimer,
    ]) {
      await expectLater(
        operation(),
        throwsA(isA<DeviceNotConnectedException>()),
      );
    }
    expect(_commandWrites(transport, 0x0F, 0x00), hasLength(1));
    expect(_commandWrites(transport, 0x0B, 0x03), hasLength(1));
    expect(_commandWrites(transport, 0x0B, 0x00), hasLength(1));
    expect(_commandWrites(transport, 0x0B, 0x02), hasLength(1));
    await scale.disconnectForHandoff();
    await transport.dispose();
  });

  test(
    'notification starvation retries subscription then disconnects without power off',
    () {
      fakeAsync((async) {
        final transport = _ReliabilityBleTransport();
        final scale = DecentScale(transport: transport);
        _settleConnection(async, scale, transport);
        final initialSubscriptions = transport.subscribeCalls;

        _elapse(async, const Duration(seconds: 12));
        expect(transport.subscribeCalls, greaterThan(initialSubscriptions));
        expect(transport.disconnectCalls, 0);

        _elapse(async, const Duration(seconds: 9));
        expect(transport.disconnectCalls, 1);
        expect(transport.nativeState, ConnectionState.disconnected);
        expect(_commandWrites(transport, 0x0A, 0x02), isEmpty);
        _close(async, scale, transport);
      });
    },
  );
}
