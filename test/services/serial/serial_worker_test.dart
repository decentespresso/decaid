import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:libserialport/libserialport.dart';
import 'package:reaprime/src/services/serial/serial_writer.dart';
import 'package:reaprime/src/services/serial/serial_service_desktop.dart';

void main() {
  final rxName = Platform.environment['SERIAL_TEST_RX'];
  final txName = Platform.environment['SERIAL_TEST_TX'];

  group(
    'serial workers',
    () {
      late SerialPort rx;
      late SerialPort tx;

      setUp(() async {
        rx = SerialPort(rxName!);
        tx = SerialPort(txName!);
        expect(await rx.openReadWrite(), isTrue);
        expect(await tx.openReadWrite(), isTrue);
      });

      tearDown(() async {
        await rx.close();
        await tx.close();
        rx.dispose();
        tx.dispose();
      });

      test(
        'reader cancellation joins the worker before port disposal',
        () async {
          final reader = SerialPortReader(rx);
          final subscription = reader.stream.listen((_) {});
          await subscription.cancel();
          await reader.close();
          await reader.close();
        },
      );

      test(
        'reader pause and resume do not start overlapping readers',
        () async {
          final reader = SerialPortReader(rx);
          final bytes = <int>[];
          final delivered = Completer<void>();
          final subscription = reader.stream.listen((data) {
            bytes.addAll(data);
            if (bytes.length == 3) delivered.complete();
          });
          for (var i = 0; i < 10; i++) {
            subscription.pause();
            subscription.resume();
          }
          await tx.write(Uint8List.fromList([1, 2, 3]), timeout: 500);
          await delivered.future.timeout(const Duration(seconds: 2));
          expect(bytes, [1, 2, 3]);
          await reader.close();
          await subscription.cancel();
        },
      );

      test('reader reports native errors and still completes close', () async {
        await rx.close();
        final reader = SerialPortReader(rx);
        await expectLater(
          reader.stream,
          emitsInOrder([emitsError(isA<SerialPortError>()), emitsDone]),
        );
        await reader.close();
      });

      test('reader closes while its subscription is paused', () async {
        final reader = SerialPortReader(rx);
        final subscription = reader.stream.listen((_) {});
        await Future<void>.delayed(const Duration(milliseconds: 20));
        subscription.pause();
        await reader.close().timeout(const Duration(seconds: 2));
        await subscription.cancel();
      });

      test('writer serializes complete commands and drains on close', () async {
        final reader = SerialPortReader(rx);
        final received = <int>[];
        final delivered = Completer<void>();
        final subscription = reader.stream.listen((data) {
          received.addAll(data);
          if (received.length == 96) delivered.complete();
        });
        final writer = SerialWriter(tx);
        final writes = List.generate(
          32,
          (i) => writer.write(Uint8List.fromList([i, i, i])),
        );
        await expectLater(writer.write(Uint8List(1)), throwsStateError);
        await writer.close();
        await Future.wait(writes);
        await delivered.future.timeout(const Duration(seconds: 2));
        expect(received, [
          for (var i = 0; i < 32; i++) ...[i, i, i],
        ]);
        await expectLater(writer.write(Uint8List(1)), throwsStateError);
        await reader.close();
        await subscription.cancel();
      });

      test(
        'writer rejects oversized requests and closes during startup',
        () async {
          final writer = SerialWriter(tx);
          await expectLater(writer.write(Uint8List(65537)), throwsStateError);
          await writer.close();
          await writer.close();
        },
      );

      test('blocked writer leaves the calling isolate responsive', () async {
        final writer = SerialWriter(tx);
        var ticks = 0;
        final heartbeat = Timer.periodic(
          const Duration(milliseconds: 5),
          (_) => ticks++,
        );
        try {
          await expectLater(writer.write(Uint8List(65536)), throwsStateError);
          expect(ticks, greaterThan(20));
        } finally {
          heartbeat.cancel();
          await writer.close();
        }
      });
    },
    skip: rxName == null || txName == null
        ? 'Set SERIAL_TEST_RX and SERIAL_TEST_TX to an isolated loopback pair'
        : false,
  );
  group(
    'desktop serial lifetime',
    () {
      test('dispose during startup and connect after disposal', () async {
        final transport = createDesktopSerialPortForTest(SerialPort(rxName!));
        final connecting = transport.connect();
        final failedConnect = expectLater(connecting, throwsStateError);
        final disposed = transport.dispose();
        await failedConnect;
        await disposed;
        await transport.dispose();
        await expectLater(transport.connect(), throwsStateError);
      });

      test('disconnect joins I/O before reconnecting the same port', () async {
        final transport = createDesktopSerialPortForTest(SerialPort(rxName!));
        try {
          for (var i = 0; i < 5; i++) {
            await transport.connect();
            final writes = [
              transport.writeCommand('<N>'),
              transport.writeCommand('<V>'),
            ];
            await transport.disconnect();
            await Future.wait(writes);
          }
        } finally {
          await transport.dispose();
        }
      });
    },
    skip: rxName == null || txName == null
        ? 'Set SERIAL_TEST_RX and SERIAL_TEST_TX to an isolated loopback pair'
        : false,
  );
}
