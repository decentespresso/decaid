import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/device/impl/decent_scale/scale_serial.dart';

import 'hds_serial_disconnect_test.dart';

/// Build a valid HDS weight frame: [0x03, 0xCE, high, low, 0x00]
Uint8List weightFrame(double weight) {
  final raw = (weight * 10).toInt();
  return Uint8List.fromList([0x03, 0xCE, (raw >> 8) & 0xFF, raw & 0xFF, 0x00]);
}

void main() {
  group('HDSSerial watchdog', () {
    test('does not fire when data flows normally', () {
      fakeAsync((async) {
        final transport = MockSerialTransport();
        final hds = HDSSerial(transport: transport);
        hds.onConnect();
        async.elapse(Duration(milliseconds: 100));

        // Feed weight data every second for 20 seconds
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

        // Advance past warning threshold (6s = 3 watchdog ticks at 2s each)
        async.elapse(Duration(seconds: 7));

        // Should have sent a retry enable command
        expect(
          transport.writtenHexCommands.length,
          greaterThan(initialCommands),
          reason: 'Expected retry enable command after data gap',
        );
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

        // Gap of 5 seconds (past warning but before disconnect)
        async.elapse(Duration(seconds: 5));

        transport.emitRawData(weightFrame(20.0));

        // Another 10 seconds — should NOT disconnect because timer reset
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

        hds.disconnect();
        async.elapse(Duration(milliseconds: 100));

        // Advance well past disconnect threshold — should not throw or re-disconnect
        transport.disconnectCalled = false;
        async.elapse(Duration(seconds: 30));

        // disconnect() should not be called again by the watchdog
        expect(transport.disconnectCalled, isFalse);
      });
    });
  });
}
