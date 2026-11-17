import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/device_implementation.dart';
import 'package:reaprime/src/models/device/impl/sensor/bengle_debug_port.dart';
import 'package:reaprime/src/models/device/transport/serial_port.dart';
import 'package:rxdart/rxdart.dart';

class _FakeSerialTransport extends SerialTransport {
  final BehaviorSubject<ConnectionState> _connection = BehaviorSubject.seeded(
    ConnectionState.discovered,
  );
  final BehaviorSubject<Uint8List> _raw = BehaviorSubject<Uint8List>();
  final List<Uint8List> writes = [];
  List<Uint8List> emitDuringConnect = const [];
  int connectCalls = 0;
  int disconnectCalls = 0;
  bool failConnect = false;

  @override
  String get id => 'usb-2e8a-a-SERIAL-if02';

  @override
  String get name => 'tap';

  @override
  Stream<ConnectionState> get connectionState => _connection.stream;

  @override
  Stream<Uint8List> get rawStream => _raw.stream;

  @override
  Stream<String> get readStream => const Stream.empty();

  @override
  Future<void> connect() async {
    connectCalls++;
    if (failConnect) throw Exception('connect failed');
    for (final chunk in emitDuringConnect) {
      _raw.add(chunk);
    }
    _connection.add(ConnectionState.connected);
  }

  @override
  Future<void> disconnect() async {
    disconnectCalls++;
    _connection.add(ConnectionState.disconnected);
  }

  @override
  Future<void> dispose() async {}

  @override
  Future<void> writeCommand(String command) async {
    fail('writeCommand must never be called on the EBus tap');
  }

  @override
  Future<void> writeHexCommand(Uint8List command) async {
    writes.add(Uint8List.fromList(command));
  }
}

void main() {
  late _FakeSerialTransport transport;
  late BengleDebugPort sensor;

  setUp(() {
    transport = _FakeSerialTransport();
    sensor = BengleDebugPort(transport: transport);
  });

  group('raw byte preservation', () {
    test('arbitrary binary chunks round-trip exactly through base64', () async {
      final chunks = <Uint8List>[
        Uint8List.fromList([0x00, 0xFF, 0x0A, 0x12]), // NUL, invalid UTF-8, LF
        Uint8List.fromList([0x34]),
        Uint8List.fromList([0x56, 0x78, 0x00, 0x80, 0x81]), // split part 2
        Uint8List.fromList([0x0D, 0x0A, 0x00]),
      ];
      await sensor.onConnect();

      final snapshots = <Map<String, dynamic>>[];
      final sub = sensor.data.listen(snapshots.add);
      for (final chunk in chunks) {
        transport._raw.add(chunk);
      }
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();

      expect(snapshots, hasLength(chunks.length));
      for (var i = 0; i < chunks.length; i++) {
        final bytes = base64Decode(snapshots[i]['bytes'] as String);
        expect(bytes, chunks[i], reason: 'chunk $i must be preserved');
        expect(snapshots[i]['timestamp'], isA<String>());
      }
    });

    test('chunks stay separate events in arrival order', () async {
      await sensor.onConnect();
      final snapshots = <Map<String, dynamic>>[];
      final sub = sensor.data.listen(snapshots.add);
      transport._raw.add(Uint8List.fromList([0x01]));
      transport._raw.add(Uint8List.fromList([0x02, 0x03]));
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();

      expect(
        snapshots.map((s) => base64Decode(s['bytes'] as String)).toList(),
        [
          Uint8List.fromList([0x01]),
          Uint8List.fromList([0x02, 0x03]),
        ],
      );
    });

    test('new subscribers do not receive previously emitted chunks', () async {
      await sensor.onConnect();
      transport._raw.add(Uint8List.fromList([0x01]));
      await Future<void>.delayed(Duration.zero);

      final lateSnapshots = <Map<String, dynamic>>[];
      final sub = sensor.data.listen(lateSnapshots.add);
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();

      expect(
        lateSnapshots,
        isEmpty,
        reason: 'raw chunks are events, not state',
      );
    });
  });

  group('write command', () {
    test('writes decoded bytes unchanged', () async {
      final bytes = Uint8List.fromList([0x00, 0xDE, 0xAD, 0x0A, 0xFF]);
      final result = await sensor.execute('write', {
        'bytes': base64Encode(bytes),
      });

      expect(transport.writes, hasLength(1));
      expect(transport.writes.single, bytes);
      expect(result, {'bytesWritten': bytes.length});
    });

    test('invalid command id writes nothing', () async {
      await expectLater(
        sensor.execute('input', {
          'bytes': base64Encode([0x01]),
        }),
        throwsA(anything),
      );
      expect(transport.writes, isEmpty);
    });

    test('invalid base64 writes nothing', () async {
      await expectLater(
        sensor.execute('write', {'bytes': 'not base64 !!!'}),
        throwsA(isA<FormatException>()),
      );
      expect(transport.writes, isEmpty);
    });

    test('missing or non-string bytes writes nothing', () async {
      await expectLater(sensor.execute('write', {}), throwsA(anything));
      await expectLater(
        sensor.execute('write', {'bytes': 42}),
        throwsA(anything),
      );
      expect(transport.writes, isEmpty);
    });
  });

  group('lifecycle', () {
    test('chunks emitted synchronously during connect are not lost', () async {
      transport.emitDuringConnect = [
        Uint8List.fromList([0x42]),
      ];
      final snapshots = <Map<String, dynamic>>[];
      final sub = sensor.data.listen(snapshots.add);

      await sensor.onConnect();
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();

      expect(snapshots, hasLength(1));
      expect(base64Decode(snapshots.single['bytes'] as String), [0x42]);
    });

    test('connect failure cancels the subscription and rethrows', () async {
      transport.failConnect = true;
      await expectLater(sensor.onConnect(), throwsA(isA<Exception>()));

      final snapshots = <Map<String, dynamic>>[];
      final sub = sensor.data.listen(snapshots.add);
      transport._raw.add(Uint8List.fromList([0x01]));
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();
      expect(snapshots, isEmpty, reason: 'subscription must be cancelled');
    });

    test('concurrent onConnect calls share one transport connect', () async {
      final first = sensor.onConnect();
      final second = sensor.onConnect();
      await Future.wait([first, second]);

      expect(transport.connectCalls, 1);
      expect(await sensor.connectionState.first, ConnectionState.connected);
    });

    test(
      'one raw chunk after concurrent connects yields one snapshot',
      () async {
        final first = sensor.onConnect();
        final second = sensor.onConnect();
        await Future.wait([first, second]);

        final snapshots = <Map<String, dynamic>>[];
        final sub = sensor.data.listen(snapshots.add);
        final chunk = Uint8List.fromList([0x00, 0xFF, 0x0A, 0x42]);
        transport._raw.add(chunk);
        await Future<void>.delayed(Duration.zero);
        await sub.cancel();

        expect(snapshots, hasLength(1));
        expect(base64Decode(snapshots.single['bytes'] as String), chunk);
      },
    );

    test(
      'failed shared connect clears in-flight state and retry succeeds',
      () async {
        transport.failConnect = true;
        final first = sensor.onConnect();
        final second = sensor.onConnect();
        await expectLater(
          Future.wait([first, second]),
          throwsA(isA<Exception>()),
        );
        expect(transport.connectCalls, 1);

        transport.failConnect = false;
        await sensor.onConnect();
        expect(transport.connectCalls, 2);

        // No leaked duplicate subscriptions from the failed attempt.
        final snapshots = <Map<String, dynamic>>[];
        final sub = sensor.data.listen(snapshots.add);
        transport._raw.add(Uint8List.fromList([0x01]));
        await Future<void>.delayed(Duration.zero);
        await sub.cancel();
        expect(snapshots, hasLength(1));
      },
    );

    test('onConnect is idempotent', () async {
      await sensor.onConnect();
      await sensor.onConnect();
      expect(transport.connectCalls, 1);
      expect(await sensor.connectionState.first, ConnectionState.connected);
    });

    test('disconnect is idempotent and cancels the subscription', () async {
      await sensor.onConnect();
      final snapshots = <Map<String, dynamic>>[];
      final sub = sensor.data.listen(snapshots.add);
      await Future<void>.delayed(Duration.zero);

      await sensor.disconnect();
      await sensor.disconnect();
      expect(transport.disconnectCalls, 1);
      expect(await sensor.connectionState.first, ConnectionState.disconnected);

      transport._raw.add(Uint8List.fromList([0x01]));
      await Future<void>.delayed(Duration.zero);
      expect(snapshots, isEmpty, reason: 'no events after disconnect');
      await sub.cancel();
    });

    test('reconnects after disconnect', () async {
      await sensor.onConnect();
      await sensor.disconnect();
      await sensor.onConnect();
      expect(transport.connectCalls, 2);
      expect(await sensor.connectionState.first, ConnectionState.connected);
    });

    test('transport error surfaces as disconnected', () async {
      await sensor.onConnect();
      transport._raw.addError(Exception('port died'));
      await Future<void>.delayed(Duration.zero);
      expect(await sensor.connectionState.first, ConnectionState.disconnected);
    });

    test('transport onDone surfaces as disconnected', () async {
      await sensor.onConnect();
      await transport._raw.close();
      await Future<void>.delayed(Duration.zero);
      expect(await sensor.connectionState.first, ConnectionState.disconnected);
    });
  });

  group('contract', () {
    test('exposes the Bengle EBus Tap manifest', () {
      expect(sensor.deviceId, 'usb-2e8a-a-SERIAL-if02');
      expect(sensor.name, 'Bengle EBus Tap');
      expect(sensor.implementation, DeviceImplementation.bengleDebugPort);
      expect(sensor.type, DeviceType.sensor);

      final info = sensor.info.toJson();
      expect(info['name'], 'Bengle EBus Tap');
      expect(info['vendor'], 'Decent Espresso');
      expect(info['data'], [
        {'key': 'bytes', 'type': 'string', 'unit': 'base64'},
      ]);
      expect((info['commands'] as List).single['id'], 'write');
    });
  });
}
