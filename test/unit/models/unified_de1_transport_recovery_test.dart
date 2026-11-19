import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/impl/de1/de1.models.dart';
import 'package:reaprime/src/models/device/impl/de1/unified_de1/unified_de1_transport.dart';
import 'package:reaprime/src/models/device/transport/ble_timeout_exception.dart';
import 'package:reaprime/src/models/device/transport/ble_transport.dart';
import 'package:rxdart/rxdart.dart';

import '../../helpers/fake_ble_transport.dart';

Uint8List _settingsMmrWritePayload() {
  final payload = Uint8List(20);
  payload.setAll(0, [0x04, 0x80, 0x38, 0x08, 0x2a, 0x00, 0x00, 0x00]);
  return payload;
}

class _TimeoutAfterDispatchFakeTransport extends FakeBleTransport {
  final Map<String, int> _timeoutsRemaining = {};

  void timeoutAfterDispatch(Endpoint endpoint, {required int count}) {
    _timeoutsRemaining[endpoint.uuid] = count;
  }

  @override
  Future<void> write(
    String serviceUUID,
    String characteristicUUID,
    Uint8List data, {
    bool withResponse = true,
    Duration? timeout,
  }) async {
    await super.write(
      serviceUUID,
      characteristicUUID,
      data,
      withResponse: withResponse,
      timeout: timeout,
    );
    final remaining = _timeoutsRemaining[characteristicUUID] ?? 0;
    if (remaining > 0) {
      _timeoutsRemaining[characteristicUUID] = remaining - 1;
      throw BleTimeoutException('write after dispatch');
    }
  }
}

class _RecoveryFakeTransport extends BLETransport {
  _RecoveryFakeTransport({required this.reconnectSucceeds});

  final bool reconnectSucceeds;

  final _connState = BehaviorSubject<ConnectionState>.seeded(
    ConnectionState.connected,
  );

  int writeCount = 0;
  int connectCount = 0;
  int disconnectCount = 0;
  final Map<String, Uint8List> readResponses = {};
  final Map<String, void Function(Uint8List)> subscribers = {};
  void Function()? duringDisconnect;

  @override
  String get id => 'recovery-fake';

  @override
  String get name => 'RecoveryFake';

  @override
  Stream<ConnectionState> get connectionState => _connState.stream;

  @override
  Future<ConnectionState> getConnectionState() async =>
      ConnectionState.disconnected;

  @override
  Future<void> connect() async {
    connectCount++;
    if (!reconnectSucceeds) {
      throw StateError('reconnect failed');
    }
    _connState.add(ConnectionState.connected);
  }

  @override
  Future<void> disconnect() async {
    disconnectCount++;
    duringDisconnect?.call();
    _connState.add(ConnectionState.disconnected);
  }

  @override
  Future<List<String>> discoverServices() async => [de1ServiceUUID];

  @override
  Future<Uint8List> read(String s, String c, {Duration? timeout}) async =>
      Uint8List.fromList(readResponses[c] ?? Uint8List(20));

  @override
  Future<void> subscribe(
    String s,
    String c,
    void Function(Uint8List) cb,
  ) async {
    subscribers[c] = cb;
  }

  @override
  Future<void> setTransportPriority(bool prioritized) async {}

  @override
  Future<void> write(
    String s,
    String c,
    Uint8List data, {
    bool withResponse = true,
    Duration? timeout,
  }) async {
    writeCount++;
    if (writeCount == 1) {
      throw BleTimeoutException('write');
    }
  }

  @override
  Future<void> dispose() async => _connState.close();
}

void main() {
  group('UnifiedDe1Transport timeout recovery', () {
    test(
      'recovery clears cached replay without closing active listeners',
      () async {
        final fake = _RecoveryFakeTransport(reconnectSucceeds: true);
        fake.readResponses[Endpoint.stateInfo.uuid] = Uint8List.fromList([
          1,
          0,
        ]);
        fake.readResponses[Endpoint.shotSettings.uuid] = Uint8List.fromList([
          1,
        ]);
        final transport = UnifiedDe1Transport(transport: fake);
        addTearDown(transport.dispose);
        await transport.connect();

        final oldWater = <ByteData>[];
        final oldFirmware = <ByteData>[];
        final oldSettings = <ByteData>[];
        final subscriptions = [
          transport.waterLevels.listen(oldWater.add),
          transport.fwMapRequest.listen(oldFirmware.add),
          transport.shotSettings.listen(oldSettings.add),
        ];
        addTearDown(() async {
          for (final subscription in subscriptions) {
            await subscription.cancel();
          }
        });
        final staleWater = fake.subscribers[Endpoint.waterLevels.uuid]!;
        final staleFirmware = fake.subscribers[Endpoint.fwMapRequest.uuid]!;
        staleWater(Uint8List.fromList([1]));
        staleFirmware(Uint8List.fromList([1]));
        await pumpEventQueue();
        expect(oldWater.single.getUint8(0), 1);
        expect(oldFirmware.single.getUint8(0), 1);
        expect(oldSettings.single.getUint8(0), 1);

        fake.readResponses[Endpoint.stateInfo.uuid] = Uint8List.fromList([
          2,
          0,
        ]);
        fake.readResponses[Endpoint.shotSettings.uuid] = Uint8List.fromList([
          2,
        ]);
        fake.duringDisconnect = () {
          staleWater(Uint8List.fromList([99]));
          staleFirmware(Uint8List.fromList([99]));
        };
        await transport.write(Endpoint.requestedState, Uint8List.fromList([2]));
        fake.duringDisconnect = null;

        final currentWater = <ByteData>[];
        final currentFirmware = <ByteData>[];
        subscriptions.addAll([
          transport.waterLevels.listen(currentWater.add),
          transport.fwMapRequest.listen(currentFirmware.add),
        ]);
        await pumpEventQueue();
        expect(currentWater, isEmpty);
        expect(currentFirmware, isEmpty);
        expect(oldWater, hasLength(1));
        expect(oldFirmware, hasLength(1));
        expect(oldSettings.map((frame) => frame.getUint8(0)), [1, 2]);
        expect((await transport.state.first).getUint8(0), 2);
        expect((await transport.shotSettings.first).getUint8(0), 2);

        fake.subscribers[Endpoint.waterLevels.uuid]!(Uint8List.fromList([2]));
        fake.subscribers[Endpoint.fwMapRequest.uuid]!(Uint8List.fromList([2]));
        await pumpEventQueue();
        expect(oldWater.map((frame) => frame.getUint8(0)), [1, 2]);
        expect(oldFirmware.map((frame) => frame.getUint8(0)), [1, 2]);
        expect(currentWater.single.getUint8(0), 2);
        expect(currentFirmware.single.getUint8(0), 2);
      },
    );

    test('successful reconnect after timeout does not surface disconnected '
        'to upstream', () async {
      final fake = _RecoveryFakeTransport(reconnectSucceeds: true);
      addTearDown(fake.dispose);
      final unified = UnifiedDe1Transport(transport: fake);

      final seen = <ConnectionState>[];
      final sub = unified.connectionState.listen(seen.add);
      addTearDown(sub.cancel);

      await unified.write(Endpoint.requestedState, Uint8List.fromList([0x02]));
      await Future<void>.delayed(Duration.zero);

      expect(fake.disconnectCount, 1);
      expect(fake.connectCount, 1);
      expect(fake.writeCount, 2);

      expect(seen, isNot(contains(ConnectionState.disconnected)));
    });

    test('ordinary write recovers once after a dispatched timeout', () async {
      final fake = _TimeoutAfterDispatchFakeTransport();
      addTearDown(fake.dispose);
      fake.timeoutAfterDispatch(Endpoint.writeToMMR, count: 1);
      final unified = UnifiedDe1Transport(transport: fake);

      await unified.write(Endpoint.writeToMMR, _settingsMmrWritePayload());

      expect(
        fake.writes
            .where(
              (write) => write.characteristicUUID == Endpoint.writeToMMR.uuid,
            )
            .length,
        2,
      );
      expect(fake.connectCalls, 1);
    });

    test(
      'ordinary write with response recovers once after a dispatched timeout',
      () async {
        final fake = _TimeoutAfterDispatchFakeTransport();
        addTearDown(fake.dispose);
        fake.timeoutAfterDispatch(Endpoint.writeToMMR, count: 1);
        final unified = UnifiedDe1Transport(transport: fake);

        await unified.writeWithResponse(
          Endpoint.writeToMMR,
          _settingsMmrWritePayload(),
        );

        expect(
          fake.writes
              .where(
                (write) => write.characteristicUUID == Endpoint.writeToMMR.uuid,
              )
              .length,
          2,
        );
        expect(fake.connectCalls, 1);
      },
    );

    test(
      'write opt-out surfaces a dispatched timeout without replay',
      () async {
        final fake = _TimeoutAfterDispatchFakeTransport();
        addTearDown(fake.dispose);
        fake.timeoutAfterDispatch(Endpoint.writeToMMR, count: 1);
        final unified = UnifiedDe1Transport(transport: fake);

        await expectLater(
          unified.write(
            Endpoint.writeToMMR,
            _settingsMmrWritePayload(),
            retryOnTimeout: false,
          ),
          throwsA(isA<BleTimeoutException>()),
        );

        expect(
          fake.writes
              .where(
                (write) => write.characteristicUUID == Endpoint.writeToMMR.uuid,
              )
              .length,
          1,
        );
        expect(fake.connectCalls, 0);
      },
    );

    test('write with response opt-out surfaces a dispatched timeout without replay', () async {
      final fake = _TimeoutAfterDispatchFakeTransport();
      addTearDown(fake.dispose);
      fake.timeoutAfterDispatch(Endpoint.writeToMMR, count: 1);
      final unified = UnifiedDe1Transport(transport: fake);

      await expectLater(
        unified.writeWithResponse(
          Endpoint.writeToMMR,
          _settingsMmrWritePayload(),
          retryOnTimeout: false,
        ),
        throwsA(isA<BleTimeoutException>()),
      );

      expect(
        fake.writes
            .where(
              (write) => write.characteristicUUID == Endpoint.writeToMMR.uuid,
            )
            .length,
        1,
      );
      expect(fake.connectCalls, 0);
    });

    test('ordinary write surfaces its second timeout', () async {
      final fake = _TimeoutAfterDispatchFakeTransport();
      addTearDown(fake.dispose);
      fake.timeoutAfterDispatch(Endpoint.writeToMMR, count: 2);
      final unified = UnifiedDe1Transport(transport: fake);

      await expectLater(
        unified.write(Endpoint.writeToMMR, _settingsMmrWritePayload()),
        throwsA(isA<BleTimeoutException>()),
      );

      expect(
        fake.writes
            .where(
              (write) => write.characteristicUUID == Endpoint.writeToMMR.uuid,
            )
            .length,
        2,
      );
      expect(fake.connectCalls, 1);
    });

    test('ordinary write with response surfaces its second timeout', () async {
      final fake = _TimeoutAfterDispatchFakeTransport();
      addTearDown(fake.dispose);
      fake.timeoutAfterDispatch(Endpoint.writeToMMR, count: 2);
      final unified = UnifiedDe1Transport(transport: fake);

      await expectLater(
        unified.writeWithResponse(
          Endpoint.writeToMMR,
          _settingsMmrWritePayload(),
        ),
        throwsA(isA<BleTimeoutException>()),
      );

      expect(
        fake.writes
            .where(
              (write) => write.characteristicUUID == Endpoint.writeToMMR.uuid,
            )
            .length,
        2,
      );
      expect(fake.connectCalls, 1);
    });

    test(
      'failed reconnect after timeout surfaces disconnected to upstream',
      () async {
        final fake = _RecoveryFakeTransport(reconnectSucceeds: false);
        addTearDown(fake.dispose);
        final unified = UnifiedDe1Transport(transport: fake);

        final seen = <ConnectionState>[];
        final sub = unified.connectionState.listen(seen.add);
        addTearDown(sub.cancel);

        await expectLater(
          unified.write(Endpoint.requestedState, Uint8List.fromList([0x02])),
          throwsA(isA<BleTimeoutException>()),
        );
        await Future<void>.delayed(Duration.zero);

        expect(seen, contains(ConnectionState.disconnected));
      },
    );
  });
}
