import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/impl/decent_scale/scale_wifi.dart';
import 'package:reaprime/src/models/device/scale.dart';

import '../../helpers/fake_web_socket_transport.dart';

WebSocketTransportFactory _seqFactory(List<FakeWebSocketTransport> queue) {
  var i = 0;
  return () => queue[i < queue.length ? i++ : queue.length - 1];
}

void main() {
  group('HDSWifi connect / handshake / recognition', () {
    test('deviceId is wifi-scoped and name marks it WiFi', () {
      final scale = HDSWifi(
        host: '192.168.1.42',
        transportFactory: () => FakeWebSocketTransport(host: '192.168.1.42'),
      );
      expect(scale.deviceId, 'wifi:192.168.1.42');
      expect(scale.name, contains('WiFi'));
      expect(scale.type, DeviceType.scale);
    });

    test(
      'sends handshake in order and connects on first valid frame',
      () async {
        final fake = FakeWebSocketTransport();
        final scale = HDSWifi(host: 'hds.local', transportFactory: () => fake);

        final connectFuture = scale.onConnect();
        await Future.delayed(const Duration(milliseconds: 10));
        fake.emit('{"grams":0.0,"ms":1}');
        await connectFuture;

        expect(fake.sent.take(3).toList(), ['rate 10k', 'events on', 'status']);
        expect(await scale.connectionState.first, ConnectionState.connected);
      },
    );

    test(
      'recognition timeout fails onConnect and reports disconnected',
      () async {
        final fake = FakeWebSocketTransport();
        final scale = HDSWifi(
          host: 'hds.local',
          transportFactory: () => fake,
          recognitionTimeout: const Duration(milliseconds: 60),
        );

        await expectLater(scale.onConnect(), throwsA(isA<StateError>()));
        expect(await scale.connectionState.first, ConnectionState.disconnected);
      },
    );

    test('weight frames produce snapshots; status sets battery', () async {
      final fake = FakeWebSocketTransport();
      final scale = HDSWifi(host: 'hds.local', transportFactory: () => fake);

      final snapshots = <ScaleSnapshot>[];
      final sub = scale.currentSnapshot.listen(snapshots.add);

      final connectFuture = scale.onConnect();
      await Future.delayed(const Duration(milliseconds: 10));
      fake.emit(
        '{"type":"status","battery_percent":42,"charging":false,"grams":0.0}',
      );
      await connectFuture;
      fake.emit('{"grams":18.5,"ms":2}');
      await Future.delayed(const Duration(milliseconds: 10));

      final weighed = snapshots.lastWhere((s) => s.weight == 18.5);
      expect(weighed.weight, 18.5);
      expect(weighed.batteryLevel, 42);
      await sub.cancel();
    });

    test('tare / timer / display map to protocol commands', () async {
      final fake = FakeWebSocketTransport();
      final scale = HDSWifi(host: 'hds.local', transportFactory: () => fake);

      final connectFuture = scale.onConnect();
      await Future.delayed(const Duration(milliseconds: 10));
      fake.emit('{"grams":0.0}');
      await connectFuture;
      fake.sent.clear();

      await scale.tare();
      await scale.startTimer();
      await scale.stopTimer();
      await scale.resetTimer();
      await scale.sleepDisplay();
      await scale.wakeDisplay();

      expect(fake.sent, [
        'tare',
        'timer start',
        'timer stop',
        'timer reset',
        'display off',
        'display on',
      ]);
    });
  });

  group('HDSWifi drop handling (ConnectionManager owns reconnect)', () {
    test(
      'watchdog stall reports disconnected and does NOT self-reconnect',
      () async {
        var built = 0;
        final fake = FakeWebSocketTransport();
        final scale = HDSWifi(
          host: 'hds.local',
          transportFactory: () {
            built++;
            return fake;
          },
          watchdogInterval: const Duration(milliseconds: 30),
        );

        final states = <ConnectionState>[];
        final sub = scale.connectionState.listen(states.add);

        final connectFuture = scale.onConnect();
        await Future.delayed(const Duration(milliseconds: 10));
        fake.emit('{"grams":1.0}');
        await connectFuture;
        expect(states.last, ConnectionState.connected);
        expect(built, 1);

        await Future.delayed(const Duration(milliseconds: 120));
        expect(states.last, ConnectionState.disconnected);
        expect(fake.disconnectCalled, isTrue);
        expect(built, 1, reason: 'scale must not build a new transport itself');
        await sub.cancel();
      },
    );

    test('peer drop after recognition reports disconnected', () async {
      final fake = FakeWebSocketTransport();
      final scale = HDSWifi(host: 'hds.local', transportFactory: () => fake);
      final states = <ConnectionState>[];
      final sub = scale.connectionState.listen(states.add);

      final connectFuture = scale.onConnect();
      await Future.delayed(const Duration(milliseconds: 10));
      fake.emit('{"grams":1.0}');
      await connectFuture;

      fake.dropFromPeer();
      await Future.delayed(const Duration(milliseconds: 10));
      expect(states.last, ConnectionState.disconnected);
      await sub.cancel();
    });

    test('a power_off frame reports disconnected', () async {
      final fake = FakeWebSocketTransport();
      final scale = HDSWifi(host: 'hds.local', transportFactory: () => fake);
      final states = <ConnectionState>[];
      final sub = scale.connectionState.listen(states.add);

      final f = scale.onConnect();
      await Future.delayed(const Duration(milliseconds: 10));
      fake.emit('{"grams":1.0}');
      await f;
      expect(states.last, ConnectionState.connected);

      fake.emit('{"type":"power","event":"power_off"}');
      await Future.delayed(const Duration(milliseconds: 10));
      expect(states.last, ConnectionState.disconnected);
      await sub.cancel();
    });

    test(
      'dispose emits disconnected before closing so listeners tear down',
      () async {
        final fake = FakeWebSocketTransport();
        final scale = HDSWifi(host: 'hds.local', transportFactory: () => fake);
        final states = <ConnectionState>[];
        final sub = scale.connectionState.listen(states.add);

        final f = scale.onConnect();
        await Future.delayed(const Duration(milliseconds: 10));
        fake.emit('{"grams":1.0}');
        await f;
        expect(states.last, ConnectionState.connected);

        await scale.dispose();
        expect(
          states.last,
          ConnectionState.disconnected,
          reason:
              'dispose must emit disconnected before closing the subject, '
              'so a listener with no onDone handler still tears down',
        );
        await sub.cancel();
      },
    );

    test(
      'a re-entrant onConnect fails the prior pending future (no orphan)',
      () async {
        final first = FakeWebSocketTransport();
        final second = FakeWebSocketTransport();
        final scale = HDSWifi(
          host: 'hds.local',
          transportFactory: _seqFactory([first, second]),
        );

        final f1 = scale.onConnect();
        final f2 = scale.onConnect();

        await expectLater(f1, throwsA(isA<StateError>()));

        await Future.delayed(const Duration(milliseconds: 10));
        second.emit('{"grams":1.0}');
        await f2;
        expect(await scale.connectionState.first, ConnectionState.connected);
      },
    );

    test('onConnect reconnects the same instance after a drop', () async {
      final first = FakeWebSocketTransport();
      final second = FakeWebSocketTransport();
      final scale = HDSWifi(
        host: 'hds.local',
        transportFactory: _seqFactory([first, second]),
      );

      final f1 = scale.onConnect();
      await Future.delayed(const Duration(milliseconds: 10));
      first.emit('{"grams":1.0}');
      await f1;
      first.dropFromPeer();
      await Future.delayed(const Duration(milliseconds: 10));
      expect(await scale.connectionState.first, ConnectionState.disconnected);

      final f2 = scale.onConnect();
      await Future.delayed(const Duration(milliseconds: 10));
      second.emit('{"grams":2.0}');
      await f2;
      expect(await scale.connectionState.first, ConnectionState.connected);
      expect(second.sent.take(3).toList(), ['rate 10k', 'events on', 'status']);
    });
  });
}
