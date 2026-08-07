import 'dart:async';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/impl/decent_scale/scale.dart';
import 'package:reaprime/src/models/device/transport/ble_transport.dart';
import 'package:reaprime/src/models/errors.dart';
import 'package:rxdart/rxdart.dart';

class _DisconnectedBleTransport extends BLETransport {
  final _connectionState = BehaviorSubject<ConnectionState>.seeded(
    ConnectionState.disconnected,
  );

  @override
  String get id => 'decent-scale-test';

  @override
  String get name => 'Test Decent Scale';

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
    _connectionState.add(ConnectionState.disconnected);
  }

  @override
  Future<List<String>> discoverServices() async => [];

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
  ) async {}

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
    throw Exception(
      'PlatformException(writeCharacteristic, device is disconnected)',
    );
  }

  @override
  Future<void> dispose() async {
    _connectionState.close();
  }
}

class _HangingBleTransport extends _DisconnectedBleTransport {
  @override
  Future<void> write(
    String serviceUUID,
    String characteristicUUID,
    Uint8List data, {
    bool withResponse = true,
    Duration? timeout,
  }) {
    return Completer<void>().future;
  }
}

class _RecordingBleTransport extends BLETransport {
  _RecordingBleTransport({
    ConnectionState nativeState = ConnectionState.disconnected,
    this.responseSubscribeCalls = const [1],
  }) : _nativeState = nativeState;

  final BehaviorSubject<ConnectionState> _connectionState =
      BehaviorSubject.seeded(ConnectionState.discovered);
  ConnectionState _nativeState;
  final writes = <Uint8List>[];
  void Function(Uint8List)? notificationCallback;
  int connectCalls = 0;
  int nativeConnectCalls = 0;
  int disconnectCalls = 0;
  int subscribeCalls = 0;
  int resetSubscriptionCalls = 0;
  int readCalls = 0;
  int respondedSubscribeCall = 0;
  bool failWrites = false;
  bool failDisconnect = false;
  int? disconnectOnWrite;
  bool failSubscriptions = false;
  final List<int> responseSubscribeCalls;
  Uint8List diagnosticRead = Uint8List(0);

  @override
  String get id => 'recording-decent-scale';

  @override
  String get name => 'Recording Decent Scale';

  @override
  Stream<ConnectionState> get connectionState => _connectionState.stream;

  @override
  Future<ConnectionState> getConnectionState() async => _nativeState;

  @override
  Future<void> connect() async {
    connectCalls++;
    if (_nativeState != ConnectionState.connected) {
      nativeConnectCalls++;
      _nativeState = ConnectionState.connected;
    }
    _connectionState.add(ConnectionState.connected);
  }

  @override
  Future<void> disconnect() async {
    disconnectCalls++;
    if (failDisconnect) throw StateError('unsafe teardown');
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
  }) async {
    readCalls++;
    return diagnosticRead;
  }

  @override
  Future<void> subscribe(
    String serviceUUID,
    String characteristicUUID,
    void Function(Uint8List) callback,
  ) async {
    subscribeCalls++;
    if (failSubscriptions) {
      throw StateError('subscription failed');
    }
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
    if (failWrites || writes.length == disconnectOnWrite) {
      _nativeState = ConnectionState.disconnected;
      _connectionState.add(ConnectionState.disconnected);
      throw const DeviceNotConnectedException.scale();
    }
    if (data.length == 7 &&
        data[1] == 0x0A &&
        data[2] == 0x01 &&
        responseSubscribeCalls.contains(subscribeCalls) &&
        respondedSubscribeCall < subscribeCalls) {
      respondedSubscribeCall = subscribeCalls;
      scheduleMicrotask(() => emitNotification([0x03, 0x0A, 0, 0, 100, 0, 0]));
    }
  }

  void emitDisconnected() {
    _nativeState = ConnectionState.disconnected;
    _connectionState.add(ConnectionState.disconnected);
  }

  void emitNotification(List<int> data) {
    notificationCallback!(Uint8List.fromList(data));
  }

  @override
  Future<void> dispose() async {
    await _connectionState.close();
  }
}

bool _hasCommand(
  _RecordingBleTransport transport,
  int command, [
  int? subcommand,
]) => transport.writes.any(
  (data) =>
      data.length == 7 &&
      data[1] == command &&
      (subcommand == null || data[2] == subcommand),
);

void _elapse(FakeAsync async, Duration duration) {
  async.elapse(duration);
  async.flushMicrotasks();
}

({DecentScale scale, _RecordingBleTransport transport}) _sleepingReconnect(
  FakeAsync async, {
  required List<int> responseSubscribeCalls,
}) {
  final transport = _RecordingBleTransport(
    responseSubscribeCalls: responseSubscribeCalls,
  );
  final scale = DecentScale(transport: transport);
  var connected = false;
  scale.onConnect().then((_) => connected = true);
  async.flushMicrotasks();
  _elapse(async, const Duration(milliseconds: 100));
  expect(connected, isTrue);
  var slept = false;
  scale.sleepDisplay().then((_) => slept = true);
  async.flushMicrotasks();
  _elapse(async, const Duration(milliseconds: 100));
  expect(slept, isTrue);
  var disconnected = false;
  scale.disconnectForHandoff().then((_) => disconnected = true);
  async.flushMicrotasks();
  expect(disconnected, isTrue);
  transport.writes.clear();
  var reconnected = false;
  scale.onConnect().then((_) => reconnected = true);
  async.flushMicrotasks();
  expect(reconnected, isTrue);
  expect(transport.writes, isEmpty);
  transport.disconnectCalls = 0;
  return (scale: scale, transport: transport);
}

void main() {
  test('initialization retries FFF4 once before publishing connected', () {
    fakeAsync((async) {
      final transport = _RecordingBleTransport(
        responseSubscribeCalls: const [2],
      );
      final scale = DecentScale(transport: transport);
      final states = <ConnectionState>[];
      scale.connectionState.listen(states.add);
      var completed = false;
      scale.onConnect().then((_) => completed = true);

      async.flushMicrotasks();
      _elapse(async, const Duration(milliseconds: 100));
      expect(transport.subscribeCalls, 1);
      expect(states, isNot(contains(ConnectionState.connected)));

      _elapse(async, const Duration(seconds: 2));
      _elapse(async, const Duration(milliseconds: 100));

      expect(transport.subscribeCalls, 2);
      expect(transport.resetSubscriptionCalls, 1);
      expect(completed, isTrue);
      expect(states.last, ConnectionState.connected);
      scale.disconnectForHandoff();
      async.flushMicrotasks();
      transport.dispose();
    });
  });

  test(
    'silent FFF4 initialization fails without publishing connected',
    () async {
      final transport = _RecordingBleTransport(responseSubscribeCalls: const [])
        ..diagnosticRead = Uint8List.fromList([0x03, 0x0A, 0, 0, 100, 0, 0]);
      final scale = DecentScale(transport: transport);
      final states = <ConnectionState>[];
      scale.connectionState.listen(states.add);

      final connection = scale.onConnect();
      await Future<void>.delayed(const Duration(milliseconds: 150));
      transport.emitNotification([0x03, 0x0A, 0, 0, 100, 0]);
      await expectLater(connection, throwsA(isA<TimeoutException>()));
      await Future<void>.delayed(Duration.zero);

      expect(transport.subscribeCalls, 2);
      expect(transport.resetSubscriptionCalls, 1);
      expect(transport.readCalls, 1);
      expect(states, isNot(contains(ConnectionState.connected)));
      expect(states.last, ConnectionState.disconnected);
      expect(_hasCommand(transport, 0x0A, 0x02), isFalse);
      await transport.dispose();
    },
    timeout: const Timeout(Duration(seconds: 10)),
  );

  test('sleeping reconnect stays dark and verifies FFF4 on wake', () {
    fakeAsync((async) {
      final (:scale, :transport) = _sleepingReconnect(
        async,
        responseSubscribeCalls: const [1, 4],
      );
      expect(transport.subscribeCalls, 2);

      var woke = false;
      scale.wakeDisplay().then((_) => woke = true);
      async.flushMicrotasks();
      _elapse(async, const Duration(milliseconds: 100));
      expect(woke, isFalse);
      expect(transport.subscribeCalls, 3);

      _elapse(async, const Duration(seconds: 2));
      _elapse(async, const Duration(milliseconds: 100));

      expect(woke, isTrue);
      expect(transport.subscribeCalls, 4);
      expect(_hasCommand(transport, 0x0A, 0x01), isTrue);
      expect(_hasCommand(transport, 0x0A, 0x04), isTrue);
      scale.disconnectForHandoff();
      async.flushMicrotasks();
      transport.dispose();
    });
  });

  test('sleep supersedes a silent wake before its retry', () {
    fakeAsync((async) {
      final (:scale, :transport) = _sleepingReconnect(
        async,
        responseSubscribeCalls: const [1],
      );
      var woke = false;
      scale.wakeDisplay().then((_) => woke = true);
      async.flushMicrotasks();
      _elapse(async, const Duration(milliseconds: 100));

      scale.sleepDisplay();
      async.flushMicrotasks();
      _elapse(async, const Duration(milliseconds: 100));
      final writesAfterSleep = List<Uint8List>.of(transport.writes);

      _elapse(async, const Duration(seconds: 3));

      expect(woke, isTrue);
      expect(transport.subscribeCalls, 3);
      expect(transport.writes, orderedEquals(writesAfterSleep));
      scale.disconnectForHandoff();
      async.flushMicrotasks();
      transport.dispose();
    });
  });

  test('latest wake runs after a superseded wake probe', () {
    fakeAsync((async) {
      final (:scale, :transport) = _sleepingReconnect(
        async,
        responseSubscribeCalls: const [1, 4],
      );
      var firstWoke = false;
      var secondWoke = false;
      scale.wakeDisplay().then((_) => firstWoke = true);
      async.flushMicrotasks();
      _elapse(async, const Duration(milliseconds: 100));

      scale.sleepDisplay();
      async.flushMicrotasks();
      scale.wakeDisplay().then((_) => secondWoke = true);
      async.flushMicrotasks();
      expect(secondWoke, isFalse);
      _elapse(async, const Duration(seconds: 2));
      expect(transport.subscribeCalls, 4);
      _elapse(async, const Duration(milliseconds: 100));

      expect(firstWoke, isTrue);
      expect(secondWoke, isTrue);
      expect(transport.writes.last[2], 0x04);
      expect(transport.writes.last[3], 0);
      scale.disconnectForHandoff();
      async.flushMicrotasks();
      transport.dispose();
    });
  });

  test('silent wake disconnects once without powering off', () async {
    final transport = _RecordingBleTransport(responseSubscribeCalls: const [1]);
    final scale = DecentScale(transport: transport);
    await scale.onConnect();
    await scale.sleepDisplay();
    await scale.disconnectForHandoff();
    transport.writes.clear();
    transport.disconnectCalls = 0;
    await scale.onConnect();

    await expectLater(scale.wakeDisplay(), throwsA(isA<TimeoutException>()));

    expect(transport.disconnectCalls, 1);
    expect(_hasCommand(transport, 0x0A, 0x02), isFalse);
    final subscriptions = transport.subscribeCalls;
    final secondWake = scale.wakeDisplay();
    await Future<void>.delayed(Duration.zero);
    expect(transport.subscribeCalls, subscriptions + 1);
    await scale.sleepDisplay();
    await secondWake;
    await transport.dispose();
  });

  test('disconnected initialization write never publishes connected', () async {
    final transport = _RecordingBleTransport()..failWrites = true;
    final scale = DecentScale(transport: transport);
    final states = <ConnectionState>[];
    final subscription = scale.connectionState.listen(states.add);

    await expectLater(
      scale.onConnect(),
      throwsA(isA<DeviceNotConnectedException>()),
    );
    await Future<void>.delayed(Duration.zero);

    expect(states, isNot(contains(ConnectionState.connected)));
    expect(await scale.connectionState.first, ConnectionState.disconnected);

    await subscription.cancel();
    await transport.dispose();
  });

  test(
    'failed initialization teardown does not publish disconnected',
    () async {
      final transport = _RecordingBleTransport()
        ..failWrites = true
        ..failDisconnect = true;
      final scale = DecentScale(transport: transport);
      final states = <ConnectionState>[];
      final subscription = scale.connectionState.listen(states.add);

      await expectLater(scale.onConnect(), throwsA(isA<StateError>()));

      expect(states, isNot(contains(ConnectionState.connected)));
      expect(states, isNot(contains(ConnectionState.disconnected)));

      await subscription.cancel();
      await transport.dispose();
    },
  );

  test(
    'native drop on the second initialization write never publishes connected',
    () async {
      final transport = _RecordingBleTransport()..disconnectOnWrite = 2;
      final scale = DecentScale(transport: transport);
      final states = <ConnectionState>[];
      final subscription = scale.connectionState.listen(states.add);

      await expectLater(
        scale.onConnect(),
        throwsA(isA<DeviceNotConnectedException>()),
      );
      await Future<void>.delayed(Duration.zero);

      expect(transport.writes, hasLength(2));
      expect(
        transport.writes.first,
        orderedEquals([0x03, 0x0A, 0x01, 0x01, 0x00, 0x00, 0x09]),
      );
      expect(states, isNot(contains(ConnectionState.connected)));
      expect(await scale.connectionState.first, ConnectionState.disconnected);

      await subscription.cancel();
      await transport.dispose();
    },
  );

  test('fresh wrapper attaches to an already-connected transport', () async {
    final transport = _RecordingBleTransport(
      nativeState: ConnectionState.connected,
    );
    final scale = DecentScale(transport: transport);

    await scale.onConnect();

    expect(transport.connectCalls, 1);
    expect(transport.nativeConnectCalls, 0);
    expect(transport.subscribeCalls, 1);
    expect(await scale.connectionState.first, ConnectionState.connected);

    final disconnected = scale.connectionState
        .where((state) => state == ConnectionState.disconnected)
        .first;
    transport.emitDisconnected();
    await disconnected;

    await transport.dispose();
  });

  test(
    'connection and rediscovery use heartbeat-off LED-on without tare',
    () async {
      final transport = _RecordingBleTransport(
        responseSubscribeCalls: const [1, 2],
      );
      final scale = DecentScale(transport: transport);

      await scale.onConnect();

      expect(_hasCommand(transport, 0x0F), isFalse);
      expect(
        transport.writes,
        contains(orderedEquals([0x03, 0x0A, 0x01, 0x01, 0x00, 0x00, 0x09])),
      );
      expect(
        transport.writes
            .where((data) => data[1] == 0x0A && {0x01, 0x04}.contains(data[2]))
            .every((data) => data[5] == 0x00),
        isTrue,
      );

      await scale.disconnectForHandoff();
      transport.writes.clear();
      await scale.onConnect();

      expect(_hasCommand(transport, 0x0F), isFalse);
      expect(
        transport.writes,
        contains(orderedEquals([0x03, 0x0A, 0x01, 0x01, 0x00, 0x00, 0x09])),
      );

      await scale.disconnectForHandoff();
      final rediscoveredTransport = _RecordingBleTransport(
        nativeState: ConnectionState.connected,
      );
      final rediscoveredScale = DecentScale(transport: rediscoveredTransport);
      await rediscoveredScale.onConnect();

      expect(_hasCommand(rediscoveredTransport, 0x0F), isFalse);
      expect(
        rediscoveredTransport.writes,
        contains(orderedEquals([0x03, 0x0A, 0x01, 0x01, 0x00, 0x00, 0x09])),
      );

      await rediscoveredScale.disconnectForHandoff();
      await transport.dispose();
      await rediscoveredTransport.dispose();
    },
  );

  test('notification watchdog disconnects without powering off', () {
    fakeAsync((async) {
      final transport = _RecordingBleTransport();
      final scale = DecentScale(transport: transport);
      final states = <ConnectionState>[];
      scale.connectionState.listen(states.add);
      var connected = false;
      scale.onConnect().then((_) => connected = true);

      async.flushMicrotasks();
      async.elapse(const Duration(milliseconds: 100));
      async.flushMicrotasks();
      expect(connected, isTrue);
      transport.writes.clear();

      async.elapse(const Duration(seconds: 20));
      async.flushMicrotasks();

      expect(_hasCommand(transport, 0x0A, 0x02), isFalse);
      expect(transport.disconnectCalls, 1);
      expect(states.last, ConnectionState.disconnected);
      transport.dispose();
    });
  });

  test('watchdog re-subscribe failures are handled', () {
    fakeAsync((async) {
      final transport = _RecordingBleTransport();
      final scale = DecentScale(transport: transport);
      var connected = false;
      scale.onConnect().then((_) => connected = true);

      async.flushMicrotasks();
      async.elapse(const Duration(milliseconds: 100));
      async.flushMicrotasks();
      expect(connected, isTrue);
      transport.failSubscriptions = true;

      async.elapse(const Duration(seconds: 12));
      async.flushMicrotasks();

      expect(transport.subscribeCalls, 3);
      expect(transport.disconnectCalls, 0);
      scale.disconnectForHandoff();
      async.flushMicrotasks();
      transport.dispose();
    });
  });

  test(
    'remote disconnect is non-destructive but explicit disconnect powers off',
    () async {
      final remoteTransport = _RecordingBleTransport();
      final remoteScale = DecentScale(transport: remoteTransport);
      await remoteScale.onConnect();
      remoteTransport.writes.clear();
      final remoteDisconnected = remoteScale.connectionState
          .where((state) => state == ConnectionState.disconnected)
          .first;

      remoteTransport.emitDisconnected();
      await remoteDisconnected;

      expect(_hasCommand(remoteTransport, 0x0A, 0x02), isFalse);
      await remoteTransport.dispose();

      final explicitTransport = _RecordingBleTransport();
      final explicitScale = DecentScale(transport: explicitTransport);
      await explicitScale.onConnect();
      explicitTransport.writes.clear();

      await explicitScale.disconnect();

      expect(_hasCommand(explicitTransport, 0x0A, 0x02), isTrue);
      await explicitTransport.dispose();
    },
  );

  test('status responses require seven bytes and update battery', () async {
    final transport = _RecordingBleTransport();
    final scale = DecentScale(transport: transport);
    await scale.onConnect();

    for (final data in [
      [0x03, 0x0A, 0x00, 0x00],
      [0x03, 0x0A, 0x00, 0x00, 0x01],
      [0x03, 0x0A, 0x00, 0x00, 0x01, 0x03],
    ]) {
      expect(() => transport.emitNotification(data), returnsNormally);
    }

    var snapshot = scale.currentSnapshot.first;
    transport.emitNotification([0x03, 0xCE, 0x00, 100, 0x00, 0x00, 0x00]);
    expect((await snapshot).batteryLevel, 100);

    snapshot = scale.currentSnapshot.first;
    transport.emitNotification([0x03, 0x0A, 0x00, 0x00, 73, 0x03, 0x1D]);
    transport.emitNotification([0x03, 0xCE, 0x00, 100, 0x00, 0x00, 0x00]);

    expect((await snapshot).batteryLevel, 73);

    await scale.disconnectForHandoff();
    await transport.dispose();
  });

  test(
    'disconnect() does not leak an uncaught async error when the '
    'power-off write throws because the device is already disconnected',
    () async {
      final uncaughtErrors = <Object>[];

      await runZonedGuarded(
        () async {
          final transport = _DisconnectedBleTransport();
          final scale = DecentScale(transport: transport);

          await scale.disconnect();

          await Future<void>.delayed(const Duration(milliseconds: 50));

          transport.dispose();
        },
        (error, stack) {
          uncaughtErrors.add(error);
        },
      );

      expect(
        uncaughtErrors,
        isEmpty,
        reason:
            'Before the fix, `_sendPowerOff()` was called without `await` '
            'inside `disconnect()`. Its write-to-disconnected exception '
            'escaped the surrounding try/catch and landed in '
            'PlatformDispatcher.onError → Crashlytics fatal.',
      );
    },
  );

  test('disconnect() returns within the power-off timeout window when the '
      'BLE write hangs forever', () async {
    final transport = _HangingBleTransport();
    final scale = DecentScale(transport: transport);

    final stopwatch = Stopwatch()..start();
    await scale.disconnect();
    stopwatch.stop();

    expect(
      stopwatch.elapsed,
      lessThan(const Duration(seconds: 4)),
      reason:
          'A hung BLE write must not stall the disconnect sequence — '
          'common on flaky links after wake-from-sleep.',
    );

    transport.dispose();
  }, timeout: const Timeout(Duration(seconds: 10)));
}
