import 'dart:convert';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/impl/decent_scale/scale_serial.dart';
import 'package:reaprime/src/models/errors.dart';

import 'hds_serial_disconnect_test.dart';

Uint8List weightFrame(double weight) {
  final raw = (weight * 10).toInt() & 0xFFFF;
  final bytes = [0x03, 0xCE, (raw >> 8) & 0xFF, raw & 0xFF, 0x00, 0x00];
  return Uint8List.fromList([...bytes, bytes.reduce((a, b) => a ^ b)]);
}

void main() {
  group('HDSSerial protocol', () {
    test('writes current enable and tare commands', () {
      fakeAsync((async) {
        final transport = MockSerialTransport();
        final hds = HDSSerial(transport: transport);

        hds.onConnect();
        async.flushMicrotasks();
        hds.tare();
        async.flushMicrotasks();

        expect(transport.writtenHexCommands, [
          Uint8List.fromList([0x03, 0x20, 0x01, 0x01]),
          Uint8List.fromList([0x03, 0x0F, 0x00, 0x00, 0x00, 0x01, 0x0D]),
        ]);
      });
    });

    test('stays connecting until a valid weight frame arrives', () {
      fakeAsync((async) {
        final transport = MockSerialTransport();
        final hds = HDSSerial(transport: transport);
        final states = <ConnectionState>[];
        hds.connectionState.listen(states.add);

        hds.onConnect();
        async.flushMicrotasks();
        expect(states.last, ConnectionState.connecting);

        transport.emitRawData(weightFrame(42));
        async.flushMicrotasks();
        expect(states.last, ConnectionState.connected);
      });
    });

    test('fails connection when no valid weight frame arrives', () {
      fakeAsync((async) {
        final transport = MockSerialTransport();
        final hds = HDSSerial(transport: transport);
        Object? error;

        hds.onConnect().catchError((Object caught) {
          error = caught;
        });
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 3));
        async.flushMicrotasks();

        expect(error, isA<EndpointUnavailableException>());
        expect(transport.disconnectCalled, isTrue);
      });
    });

    test('preserves a transport error during initialization', () {
      fakeAsync((async) {
        final transport = MockSerialTransport();
        final hds = HDSSerial(transport: transport);
        final transportError = StateError('USB read failed');
        Object? error;

        hds.onConnect().catchError((Object caught) {
          error = caught;
        });
        async.flushMicrotasks();
        transport.emitRawError(transportError);
        async.flushMicrotasks();

        expect(error, same(transportError));
        expect(transport.disconnectCalled, isTrue);
      });
    });

    test('reports a closed transport during initialization', () {
      fakeAsync((async) {
        final transport = MockSerialTransport();
        final hds = HDSSerial(transport: transport);
        Object? error;

        hds.onConnect().catchError((Object caught) {
          error = caught;
        });
        async.flushMicrotasks();
        transport.closeRawStream();
        async.flushMicrotasks();

        expect(error, isA<StateError>());
        expect(error.toString(), contains('closed'));
        expect(transport.disconnectCalled, isTrue);
      });
    });

    test('decodes signed frames split and coalesced across chunks', () {
      fakeAsync((async) {
        final transport = MockSerialTransport();
        final hds = HDSSerial(transport: transport);
        final weights = <double>[];
        hds.currentSnapshot.listen((snapshot) => weights.add(snapshot.weight));
        hds.onConnect();
        async.flushMicrotasks();

        final positive = weightFrame(12.3);
        transport.emitRawData(positive.sublist(0, 3));
        transport.emitRawData(positive.sublist(3));
        transport.emitRawData(
          Uint8List.fromList([
            ...utf8.encode('HDS log\n'),
            ...weightFrame(-4.5),
            ...weightFrame(6.7),
          ]),
        );
        async.flushMicrotasks();

        expect(weights, [12.3, -4.5, 6.7]);
      });
    });

    test('ignores a bad checksum and resynchronizes to the next frame', () {
      fakeAsync((async) {
        final transport = MockSerialTransport();
        final hds = HDSSerial(transport: transport);
        final weights = <double>[];
        hds.currentSnapshot.listen((snapshot) => weights.add(snapshot.weight));
        hds.onConnect();
        async.flushMicrotasks();
        final invalid = weightFrame(10)..[6] ^= 0xFF;

        transport.emitRawData(
          Uint8List.fromList([...invalid, ...weightFrame(20)]),
        );
        async.flushMicrotasks();

        expect(weights, [20]);
      });
    });
  });

  group('HDSSerial watchdog', () {
    test('does not fire when data flows normally', () {
      fakeAsync((async) {
        final transport = MockSerialTransport();
        final hds = HDSSerial(transport: transport);
        hds.onConnect();
        async.elapse(Duration(milliseconds: 100));

        for (var i = 0; i < 20; i++) {
          transport.emitRawData(weightFrame(10.0 + i));
          async.elapse(Duration(seconds: 1));
        }

        expect(transport.disconnectCalled, isFalse);
      });
    });

    test('sends retry command after data gap exceeds warning threshold', () {
      fakeAsync((async) {
        final transport = MockSerialTransport();
        final hds = HDSSerial(transport: transport);
        hds.onConnect();
        async.elapse(Duration(milliseconds: 100));

        transport.emitRawData(weightFrame(42.0));
        async.elapse(Duration(milliseconds: 100));

        final initialCommands = transport.writtenHexCommands.length;

        async.elapse(Duration(seconds: 7));

        expect(
          transport.writtenHexCommands.length,
          greaterThan(initialCommands),
        );
        expect(
          transport.writtenHexCommands.last,
          Uint8List.fromList([0x03, 0x20, 0x01, 0x01]),
        );
      });
    });

    test('firmware text does not reset the watchdog', () {
      fakeAsync((async) {
        final transport = MockSerialTransport();
        final hds = HDSSerial(transport: transport);
        hds.onConnect();
        async.flushMicrotasks();
        transport.emitRawData(weightFrame(42));
        async.flushMicrotasks();

        for (var i = 0; i < 7; i++) {
          transport.emitRawData(Uint8List.fromList(utf8.encode('log\n')));
          async.elapse(const Duration(seconds: 2));
        }

        expect(transport.disconnectCalled, isTrue);
      });
    });

    test('disconnects after data gap exceeds disconnect threshold', () {
      fakeAsync((async) {
        final transport = MockSerialTransport();
        final hds = HDSSerial(transport: transport);
        hds.onConnect();
        async.elapse(Duration(milliseconds: 100));

        transport.emitRawData(weightFrame(42.0));
        async.elapse(Duration(milliseconds: 100));

        async.elapse(Duration(seconds: 13));

        expect(transport.disconnectCalled, isTrue);
      });
    });

    test('resets watchdog when data resumes after warning', () {
      fakeAsync((async) {
        final transport = MockSerialTransport();
        final hds = HDSSerial(transport: transport);
        hds.onConnect();
        async.elapse(Duration(milliseconds: 100));

        transport.emitRawData(weightFrame(10.0));
        async.elapse(Duration(milliseconds: 100));
        final initialCommands = transport.writtenHexCommands.length;

        async.elapse(Duration(seconds: 7));

        expect(
          transport.writtenHexCommands.length,
          greaterThan(initialCommands),
        );

        transport.emitRawData(weightFrame(20.0));

        async.elapse(Duration(seconds: 10));

        expect(transport.disconnectCalled, isFalse);
      });
    });

    test('watchdog timer is cancelled on disconnect', () {
      fakeAsync((async) {
        final transport = MockSerialTransport();
        final hds = HDSSerial(transport: transport);
        hds.onConnect();
        async.elapse(Duration(milliseconds: 100));
        transport.emitRawData(weightFrame(10));
        async.flushMicrotasks();

        hds.disconnect();
        async.elapse(Duration(milliseconds: 100));

        transport.disconnectCalled = false;
        async.elapse(Duration(seconds: 30));

        expect(transport.disconnectCalled, isFalse);
      });
    });
  });
}
