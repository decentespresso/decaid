import 'dart:async';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/impl/acaia/acaia_scale.dart';
import 'package:reaprime/src/models/device/scale.dart';
import 'package:reaprime/src/models/device/transport/ble_transport.dart';
import 'package:reaprime/src/models/errors.dart';
import 'package:rxdart/rxdart.dart';

const _weightBody = <int>[0xDF, 0x06, 0x00, 0x00, 0x01, 0x00];
const _realWeightFrame = <int>[
  0xEF,
  0xDD,
  0x0C,
  0x0C,
  0x05,
  0xDF,
  0x06,
  0x00,
  0x00,
  0x01,
  0x00,
  0x07,
  0x00,
  0x00,
  0x02,
  0xF3,
  0x0D,
];
const _secondWeightBody = <int>[0xA4, 0x01, 0x00, 0x00, 0x01, 0x00];
const _realSettingsFrame = <int>[
  0xEF,
  0xDD,
  0x08,
  0x09,
  0x5D,
  0x02,
  0x02,
  0x01,
  0x00,
  0x01,
  0x01,
  0x00,
  0x0D,
  0x60,
];

List<int> _frame(int command, List<int> payload) {
  final body = [payload.length + 1, ...payload];
  var even = 0;
  var odd = 0;
  for (var i = 0; i < body.length; i++) {
    if (i.isEven) {
      even = (even + body[i]) & 0xFF;
    } else {
      odd = (odd + body[i]) & 0xFF;
    }
  }
  return [0xEF, 0xDD, command, ...body, even, odd];
}

List<int> _eventFrame(int eventType, List<int> payload) =>
    _frame(0x0C, [eventType, ...payload]);

List<int> _minimalWeightFrame() => _eventFrame(5, _weightBody);

List<int> _heartbeatWeightFrame() => _eventFrame(11, [0, 0, 5, ..._weightBody]);

List<int> _heartbeatTimerFrame() =>
    _eventFrame(11, [0, 0, 7, 0x01, 0x1E, 0x05]);

List<int> _heartbeatButtonFrame() => _eventFrame(11, [0, 0, 8, 0]);

List<int> _settingsFrame(int battery) => _frame(0x08, [battery, 0]);

class _AcaiaTransport extends BLETransport {
  _AcaiaTransport({
    required this.services,
    this.emitWeightDuringInit = true,
    this.initializationFrame = _realWeightFrame,
  });

  final List<String> services;
  final bool emitWeightDuringInit;
  final List<int> initializationFrame;
  final BehaviorSubject<ConnectionState> states = BehaviorSubject.seeded(
    ConnectionState.discovered,
  );
  final List<List<int>> writes = [];
  void Function(Uint8List)? notification;
  Future<void> Function(Uint8List)? writeBehavior;
  Object? disconnectError;
  int disconnectCalls = 0;
  bool _initWeightSent = false;

  @override
  String get id => 'acaia-test';

  @override
  String get name => 'LUNAR-TEST';

  @override
  Stream<ConnectionState> get connectionState => states.stream;

  @override
  Future<ConnectionState> getConnectionState() async => states.value;

  @override
  Future<void> connect() async => states.add(ConnectionState.connected);

  @override
  Future<void> disconnect() async {
    disconnectCalls++;
    final error = disconnectError;
    if (error != null) throw error;
    states.add(ConnectionState.disconnected);
  }

  @override
  Future<List<String>> discoverServices() async => services;

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
    notification = callback;
  }

  @override
  Future<void> write(
    String serviceUUID,
    String characteristicUUID,
    Uint8List data, {
    bool withResponse = true,
    Duration? timeout,
  }) async {
    writes.add(data.toList());
    if (emitWeightDuringInit && !_initWeightSent && data[2] == 0x0C) {
      _initWeightSent = true;
      scheduleMicrotask(() => emit(initializationFrame));
    }
    await writeBehavior?.call(data);
  }

  void emit(List<int> data) => notification!(Uint8List.fromList(data));

  @override
  Future<void> setTransportPriority(bool prioritized) async {}

  @override
  Future<void> dispose() async => states.close();
}

_AcaiaTransport _ips({
  bool emitWeightDuringInit = true,
  List<int> initializationFrame = _realWeightFrame,
}) => _AcaiaTransport(
  services: const ['00001820-0000-1000-8000-00805f9b34fb'],
  emitWeightDuringInit: emitWeightDuringInit,
  initializationFrame: initializationFrame,
);

const _zeroTimings = AcaiaTimings(
  initialIpsSettle: Duration.zero,
  initialPyxisSettle: Duration.zero,
  identSettle: Duration.zero,
  configSettle: Duration.zero,
);

Future<(AcaiaScale, _AcaiaTransport)> _connected({
  AcaiaTimings timings = _zeroTimings,
}) async {
  final transport = _ips();
  final scale = AcaiaScale(transport: transport, timings: timings);
  await scale.onConnect();
  return (scale, transport);
}

void main() {
  test('detects IPS and Pyxis services', () async {
    for (final services in [
      ['00001820-0000-1000-8000-00805f9b34fb'],
      ['49535343-fe7d-4ae5-8fa9-9fafd205e455'],
    ]) {
      final transport = _AcaiaTransport(services: services);
      final scale = AcaiaScale(transport: transport, timings: _zeroTimings);
      await scale.onConnect();
      expect(await scale.connectionState.first, ConnectionState.connected);
      await scale.disconnect();
      await transport.dispose();
    }
  });

  test('rejects unsupported services', () async {
    final transport = _AcaiaTransport(
      services: const ['0000fff0-0000-1000-8000-00805f9b34fb'],
    );
    final scale = AcaiaScale(transport: transport, timings: _zeroTimings);
    await scale.onConnect();
    expect(await scale.connectionState.first, ConnectionState.disconnected);
    await transport.dispose();
  });

  test(
    'timer event 11 emits no weight and weight selector emits 175.9g',
    () async {
      final (scale, transport) = await _connected();
      final snapshots = <ScaleSnapshot>[];
      final subscription = scale.currentSnapshot.listen(snapshots.add);

      transport.emit(_heartbeatTimerFrame());
      transport.emit(_heartbeatWeightFrame());
      await Future<void>.delayed(Duration.zero);

      expect(snapshots.map((snapshot) => snapshot.weight), [175.9]);
      await subscription.cancel();
      await scale.disconnect();
      await transport.dispose();
    },
  );

  test(
    'real multi-record direct frame completes initialization once',
    () async {
      final transport = _ips(initializationFrame: _realWeightFrame);
      final scale = AcaiaScale(transport: transport, timings: _zeroTimings);
      final snapshots = <ScaleSnapshot>[];
      final subscription = scale.currentSnapshot.listen(snapshots.add);

      await scale.onConnect();

      expect(await scale.connectionState.first, ConnectionState.connected);
      expect(snapshots.map((snapshot) => snapshot.weight), [175.9]);
      expect(_realWeightFrame[3], 0x0C);

      await subscription.cancel();
      await scale.disconnect();
      await transport.dispose();
    },
  );

  test(
    'initialization requests the reference timer notification interval',
    () async {
      final (scale, transport) = await _connected();
      final request = transport.writes.firstWhere((write) => write[2] == 0x0C);

      expect(request.sublist(3, 12), [9, 0, 1, 1, 2, 2, 5, 3, 4]);

      await scale.disconnect();
      await transport.dispose();
    },
  );

  test('minimal direct weight uses the declared protocol length', () async {
    final frame = _minimalWeightFrame();
    final transport = _ips(initializationFrame: frame);
    final scale = AcaiaScale(transport: transport, timings: _zeroTimings);
    final snapshots = <ScaleSnapshot>[];
    final subscription = scale.currentSnapshot.listen(snapshots.add);

    await scale.onConnect();

    expect(frame[3], 8);
    expect(await scale.connectionState.first, ConnectionState.connected);
    expect(snapshots.map((snapshot) => snapshot.weight), [175.9]);

    await subscription.cancel();
    await scale.disconnect();
    await transport.dispose();
  });

  test('heartbeat-wrapped weight completes initialization', () async {
    final frame = _heartbeatWeightFrame();
    final transport = _ips(initializationFrame: frame);
    final scale = AcaiaScale(transport: transport, timings: _zeroTimings);
    final snapshots = <ScaleSnapshot>[];
    final subscription = scale.currentSnapshot.listen(snapshots.add);

    await scale.onConnect();

    expect(frame[3], 11);
    expect(await scale.connectionState.first, ConnectionState.connected);
    expect(snapshots.map((snapshot) => snapshot.weight), [175.9]);

    await subscription.cancel();
    await scale.disconnect();
    await transport.dispose();
  });

  test('heartbeat timer and button records never publish weight', () async {
    final (scale, transport) = await _connected();
    final snapshots = <ScaleSnapshot>[];
    final subscription = scale.currentSnapshot.listen(snapshots.add);

    transport.emit(_heartbeatTimerFrame());
    transport.emit(_heartbeatButtonFrame());
    await Future<void>.delayed(Duration.zero);

    expect(snapshots, isEmpty);
    await subscription.cancel();
    await scale.disconnect();
    await transport.dispose();
  });

  test('short heartbeat button frames refresh Pyxis liveness', () {
    fakeAsync((async) {
      final transport = _AcaiaTransport(
        services: const ['49535343-fe7d-4ae5-8fa9-9fafd205e455'],
      );
      final scale = AcaiaScale(transport: transport);
      final snapshots = <ScaleSnapshot>[];
      final states = <ConnectionState>[];
      scale.currentSnapshot.listen(snapshots.add);
      scale.connectionState.listen(states.add);

      scale.onConnect();
      async.elapse(const Duration(seconds: 2));
      async.flushMicrotasks();
      expect(states.last, ConnectionState.connected);

      snapshots.clear();
      transport.emit(_heartbeatButtonFrame());
      async.flushMicrotasks();
      async.elapse(const Duration(milliseconds: 4500));
      async.flushMicrotasks();

      expect(states.last, ConnectionState.connected);
      expect(snapshots, isEmpty);
      scale.disconnect();
      async.flushMicrotasks();
      transport.dispose();
    });
  });

  test('unknown and incomplete heartbeat records are rejected', () async {
    for (final frame in [
      _eventFrame(11, [0, 0, 9, 0]),
      _eventFrame(11, [0, 0, 5, ..._weightBody.sublist(0, 5)]),
    ]) {
      final (scale, transport) = await _connected();
      final snapshots = <ScaleSnapshot>[];
      final subscription = scale.currentSnapshot.listen(snapshots.add);

      transport.emit([...frame, ..._minimalWeightFrame()]);
      await Future<void>.delayed(Duration.zero);

      expect(snapshots.map((snapshot) => snapshot.weight), [175.9]);
      await subscription.cancel();
      await scale.disconnect();
      await transport.dispose();
    }
  });

  test('direct weight accepts complete trailing records', () async {
    final frame = _eventFrame(5, [..._weightBody, 7, 0x01, 0x1E, 0x05]);
    final (scale, transport) = await _connected();
    final snapshots = <ScaleSnapshot>[];
    final subscription = scale.currentSnapshot.listen(snapshots.add);

    transport.emit(frame);
    await Future<void>.delayed(Duration.zero);

    expect(snapshots.map((snapshot) => snapshot.weight), [175.9]);
    await subscription.cancel();
    await scale.disconnect();
    await transport.dispose();
  });

  test(
    'complete weights ignore unknown or incomplete trailing records',
    () async {
      for (final frame in [
        _eventFrame(5, [..._weightBody, 0x09]),
        _eventFrame(5, [..._weightBody, 0x07, 0x01]),
        _eventFrame(11, [0, 0, 5, ..._weightBody, 0x09]),
        _eventFrame(11, [0, 0, 5, ..._weightBody, 0x07, 0x01]),
      ]) {
        final (scale, transport) = await _connected();
        final snapshots = <ScaleSnapshot>[];
        final subscription = scale.currentSnapshot.listen(snapshots.add);

        transport.emit(frame);
        await Future<void>.delayed(Duration.zero);

        expect(snapshots.map((snapshot) => snapshot.weight), [175.9]);
        await subscription.cancel();
        await scale.disconnect();
        await transport.dispose();
      }
    },
  );

  test('weight flags use bit 0x02 for the negative sign', () async {
    final (scale, transport) = await _connected();
    final snapshots = <ScaleSnapshot>[];
    final subscription = scale.currentSnapshot.listen(snapshots.add);

    transport.emit(_eventFrame(5, [..._weightBody.sublist(0, 5), 0x03]));
    await Future<void>.delayed(Duration.zero);

    expect(snapshots.map((snapshot) => snapshot.weight), [-175.9]);
    await subscription.cancel();
    await scale.disconnect();
    await transport.dispose();
  });

  test(
    'truncated direct and heartbeat weights recover before a valid frame',
    () async {
      for (final frame in [_minimalWeightFrame(), _heartbeatWeightFrame()]) {
        final (scale, transport) = await _connected();
        final snapshots = <ScaleSnapshot>[];
        final subscription = scale.currentSnapshot.listen(snapshots.add);
        final weightOffset = frame[4] == 5 ? 5 : 8;

        transport.emit(frame.sublist(0, weightOffset + 5));
        await Future<void>.delayed(Duration.zero);
        expect(snapshots, isEmpty);

        transport.emit(_minimalWeightFrame());
        await Future<void>.delayed(Duration.zero);
        expect(snapshots.map((snapshot) => snapshot.weight), [175.9]);

        await subscription.cancel();
        await scale.disconnect();
        await transport.dispose();
      }
    },
  );

  test('truncated real records preserve the following weight frame', () async {
    for (var cut = 11; cut < _realWeightFrame.length; cut++) {
      final (scale, transport) = await _connected();
      final snapshots = <ScaleSnapshot>[];
      final subscription = scale.currentSnapshot.listen(snapshots.add);

      transport.emit(_realWeightFrame.sublist(0, cut));
      await Future<void>.delayed(Duration.zero);
      expect(snapshots, isEmpty);

      transport.emit(_eventFrame(5, _secondWeightBody));
      await Future<void>.delayed(Duration.zero);

      expect(snapshots.map((snapshot) => snapshot.weight), [42.0]);
      await subscription.cancel();
      await scale.disconnect();
      await transport.dispose();
    }
  });

  test(
    'two complete weight frames in one notification are both consumed',
    () async {
      final (scale, transport) = await _connected();
      final snapshots = <ScaleSnapshot>[];
      final subscription = scale.currentSnapshot.listen(snapshots.add);

      transport.emit([..._minimalWeightFrame(), ..._heartbeatWeightFrame()]);
      await Future<void>.delayed(Duration.zero);

      expect(snapshots.map((snapshot) => snapshot.weight), [175.9, 175.9]);
      await subscription.cancel();
      await scale.disconnect();
      await transport.dispose();
    },
  );

  test(
    'embedded header bytes remain inside a complete weight payload',
    () async {
      final frame = _eventFrame(5, [0xEF, 0xDD, 0x00, 0x00, 0x01, 0x00]);
      final (scale, transport) = await _connected();
      final snapshots = <ScaleSnapshot>[];
      final subscription = scale.currentSnapshot.listen(snapshots.add);

      transport.emit(frame);
      await Future<void>.delayed(Duration.zero);

      expect(snapshots.map((snapshot) => snapshot.weight), [5681.5]);
      await subscription.cancel();
      await scale.disconnect();
      await transport.dispose();
    },
  );

  test(
    'short and oversized frames cannot consume the following weight frame',
    () async {
      for (final prefix in [
        [0xEF, 0xDD, 0x0C, 0x02, 0x05, 0xAA, 0xBB],
        [0xEF, 0xDD, 0x0C, 0x0C, 0x05, ..._weightBody.sublist(0, 2)],
        [0xEF, 0xDD, 0x0C, 0xFF, 0x05, 0x00],
      ]) {
        final (scale, transport) = await _connected();
        final snapshots = <ScaleSnapshot>[];
        final subscription = scale.currentSnapshot.listen(snapshots.add);

        transport.emit([...prefix, ..._realWeightFrame]);
        await Future<void>.delayed(Duration.zero);

        expect(snapshots.map((snapshot) => snapshot.weight), [175.9]);
        await subscription.cancel();
        await scale.disconnect();
        await transport.dispose();
      }
    },
  );

  test('unsupported frames isolate embedded headers', () async {
    final (scale, transport) = await _connected();
    final snapshots = <ScaleSnapshot>[];
    final subscription = scale.currentSnapshot.listen(snapshots.add);

    transport.emit([
      ..._frame(0x0B, [0x01, ..._minimalWeightFrame()]),
      ..._minimalWeightFrame(),
    ]);
    await Future<void>.delayed(Duration.zero);

    expect(snapshots.map((snapshot) => snapshot.weight), [175.9]);
    await subscription.cancel();
    await scale.disconnect();
    await transport.dispose();
  });

  test('concatenated settings and weight frames are both processed', () async {
    for (final frames in [
      [..._settingsFrame(72), ..._minimalWeightFrame()],
      [..._minimalWeightFrame(), ..._settingsFrame(72)],
    ]) {
      final (scale, transport) = await _connected();
      final snapshots = <ScaleSnapshot>[];
      final subscription = scale.currentSnapshot.listen(snapshots.add);
      transport.emit(frames);
      transport.emit(_minimalWeightFrame());
      await Future<void>.delayed(Duration.zero);
      expect(snapshots.last.batteryLevel, 72);
      await subscription.cancel();
      await scale.disconnect();
      await transport.dispose();
    }
  });

  test('real declared-length settings frame updates the battery', () async {
    final (scale, transport) = await _connected();
    final snapshot = scale.currentSnapshot.first;

    transport.emit(_realSettingsFrame);
    transport.emit(_minimalWeightFrame());

    expect(_realSettingsFrame[3], 9);
    expect((await snapshot).batteryLevel, 93);
    await scale.disconnect();
    await transport.dispose();
  });

  test('split frames and split headers are retained', () async {
    for (final split in [1, 3, 4, 8, 12, 16]) {
      final (scale, transport) = await _connected();
      final snapshots = <ScaleSnapshot>[];
      final subscription = scale.currentSnapshot.listen(snapshots.add);
      transport.emit([0x99, ..._realWeightFrame.sublist(0, split)]);
      await Future<void>.delayed(Duration.zero);
      expect(snapshots, isEmpty);
      transport.emit(_realWeightFrame.sublist(split));
      await Future<void>.delayed(Duration.zero);
      expect(snapshots.map((snapshot) => snapshot.weight), [175.9]);
      await subscription.cancel();
      await scale.disconnect();
      await transport.dispose();
    }
  });

  test('battery high bit is masked and invalid battery is retained', () async {
    final (scale, transport) = await _connected();
    var snapshot = scale.currentSnapshot.first;
    transport.emit(_settingsFrame(0xC8));
    transport.emit(_minimalWeightFrame());
    expect((await snapshot).batteryLevel, 72);

    snapshot = scale.currentSnapshot.first;
    transport.emit(_settingsFrame(0xE5));
    transport.emit(_minimalWeightFrame());
    expect((await snapshot).batteryLevel, 72);
    await scale.disconnect();
    await transport.dispose();
  });

  test('mute initialization never publishes connected', () {
    fakeAsync((async) {
      final transport = _ips(emitWeightDuringInit: false);
      final scale = AcaiaScale(transport: transport);
      final states = <ConnectionState>[];
      scale.connectionState.listen(states.add);
      scale.onConnect();
      async.flushMicrotasks();
      async.flushTimers();
      async.flushMicrotasks();
      expect(transport.writes, hasLength(20));
      expect(states, isNot(contains(ConnectionState.connected)));
      expect(states.last, ConnectionState.disconnected);
      expect(transport.disconnectCalls, 1);
      transport.dispose();
    });
  });

  test('heartbeat timer initialization does not establish readiness', () {
    fakeAsync((async) {
      final transport = _ips(initializationFrame: _heartbeatTimerFrame());
      final scale = AcaiaScale(transport: transport);
      final snapshots = <ScaleSnapshot>[];
      final states = <ConnectionState>[];
      scale.currentSnapshot.listen(snapshots.add);
      scale.connectionState.listen(states.add);

      scale.onConnect();
      async.elapse(const Duration(seconds: 9));
      async.flushMicrotasks();

      expect(snapshots, isEmpty);
      expect(states, isNot(contains(ConnectionState.connected)));
      expect(states.last, ConnectionState.disconnected);
      expect(transport.disconnectCalls, 1);
      transport.dispose();
    });
  });

  test('event 5 and event 11 weight complete initialization', () {
    for (final frame in [_minimalWeightFrame(), _heartbeatWeightFrame()]) {
      fakeAsync((async) {
        final transport = _ips(emitWeightDuringInit: false);
        transport.writeBehavior = (data) async {
          if (data[2] == 0x0C) scheduleMicrotask(() => transport.emit(frame));
        };
        final scale = AcaiaScale(transport: transport);
        scale.onConnect();
        async.elapse(const Duration(seconds: 1));
        async.flushMicrotasks();
        expect(scale.connectionState, emits(ConnectionState.connected));
        scale.disconnect();
        async.flushMicrotasks();
        transport.dispose();
      });
    }
  });

  test('transport disconnect invalidates pending initialization', () {
    fakeAsync((async) {
      final transport = _ips(emitWeightDuringInit: false);
      transport.writeBehavior = (data) async {
        if (data[2] != 0x0C) return;
        scheduleMicrotask(() => transport.emit(_minimalWeightFrame()));
        Timer(
          const Duration(milliseconds: 100),
          () => transport.states.add(ConnectionState.disconnected),
        );
      };
      final scale = AcaiaScale(transport: transport);
      final states = <ConnectionState>[];
      scale.connectionState.listen(states.add);

      scale.onConnect();
      async.flushTimers();
      async.flushMicrotasks();

      final disconnected = states.lastIndexOf(ConnectionState.disconnected);
      expect(disconnected, greaterThan(0));
      expect(
        states.skip(disconnected + 1),
        isNot(contains(ConnectionState.connected)),
      );
      transport.dispose();
    });
  });

  test('maintenance is serialized and stops after disconnect', () {
    fakeAsync((async) {
      final transport = _ips();
      final scale = AcaiaScale(transport: transport);
      scale.onConnect();
      async.elapse(const Duration(seconds: 1));
      async.flushMicrotasks();
      transport.writes.clear();
      final blocked = Completer<void>();
      transport.writeBehavior = (data) => blocked.future;

      async.elapse(const Duration(seconds: 12));
      async.flushMicrotasks();
      expect(transport.writes.where((write) => write[2] == 0), hasLength(1));

      scale.disconnect();
      async.flushMicrotasks();
      blocked.complete();
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 6));
      async.flushMicrotasks();
      expect(transport.writes.where((write) => write[2] == 0), hasLength(1));
      transport.dispose();
    });
  });

  test('known malformed frames do not refresh Pyxis liveness', () {
    fakeAsync((async) {
      final transport = _AcaiaTransport(
        services: const ['49535343-fe7d-4ae5-8fa9-9fafd205e455'],
      );
      final scale = AcaiaScale(transport: transport);
      scale.onConnect();
      async.elapse(const Duration(milliseconds: 1200));
      async.flushMicrotasks();
      expect(transport.disconnectCalls, 0);

      for (var i = 0; i < 13; i++) {
        transport.emit(const [0xEF, 0xDD, 0x0C, 0x0C, 0x05, 0xAA, 0xBB]);
        async.elapse(const Duration(milliseconds: 500));
        async.flushMicrotasks();
      }

      expect(transport.disconnectCalls, 1);
      scale.disconnect();
      async.flushMicrotasks();
      transport.dispose();
    });
  });

  test('Pyxis watchdog is independent of a blocked heartbeat', () {
    fakeAsync((async) {
      final transport = _AcaiaTransport(
        services: const ['49535343-fe7d-4ae5-8fa9-9fafd205e455'],
      );
      final scale = AcaiaScale(transport: transport);
      scale.onConnect();
      async.elapse(const Duration(milliseconds: 1200));
      async.flushMicrotasks();
      final blocked = Completer<void>();
      transport.writeBehavior = (data) => blocked.future;

      async.elapse(const Duration(seconds: 6));
      async.flushMicrotasks();

      expect(transport.disconnectCalls, 1);
      blocked.complete();
      scale.disconnect();
      async.flushMicrotasks();
      transport.dispose();
    });
  });

  test('watchdog disconnect failures stay contained', () {
    fakeAsync((async) {
      final uncaught = <Object>[];
      runZonedGuarded(() {
        final transport = _AcaiaTransport(
          services: const ['49535343-fe7d-4ae5-8fa9-9fafd205e455'],
        );
        final scale = AcaiaScale(transport: transport);
        final states = <ConnectionState>[];
        scale.connectionState.listen(states.add);
        scale.onConnect();
        async.elapse(const Duration(milliseconds: 1200));
        async.flushMicrotasks();
        transport.disconnectError = StateError('disconnect failed');

        async.elapse(const Duration(seconds: 6));
        async.flushMicrotasks();

        expect(states.last, ConnectionState.disconnected);
        transport.dispose();
      }, (error, stackTrace) => uncaught.add(error));

      expect(uncaught, isEmpty);
    });
  });

  test(
    'maintenance errors do not escape and config is initialization-only',
    () {
      for (final error in <Object>[
        TimeoutException('timeout'),
        const DeviceNotConnectedException.scale(),
        StateError('transport'),
      ]) {
        fakeAsync((async) {
          final uncaught = <Object>[];
          runZonedGuarded(() {
            final transport = _ips();
            final scale = AcaiaScale(transport: transport);
            scale.onConnect();
            async.elapse(const Duration(seconds: 1));
            async.flushMicrotasks();
            final configCount = transport.writes
                .where((write) => write[2] == 0x0C)
                .length;
            transport.writeBehavior = (data) async {
              if (data[2] == 0) throw error;
            };
            async.elapse(const Duration(seconds: 3));
            async.flushMicrotasks();
            expect(
              transport.writes.where((write) => write[2] == 0x0C),
              hasLength(configCount),
            );
            scale.disconnect();
            async.flushMicrotasks();
            transport.dispose();
          }, (error, stack) => uncaught.add(error));
          expect(uncaught, isEmpty);
        });
      }
    },
  );

  test('tare sends the command three times', () async {
    final (scale, transport) = await _connected();
    transport.writes.clear();
    await scale.tare();
    expect(transport.writes.where((write) => write[2] == 0x04), hasLength(3));
    await scale.disconnect();
    await transport.dispose();
  });
}
