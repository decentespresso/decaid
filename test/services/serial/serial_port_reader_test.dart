import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:libserialport/libserialport.dart';

void main() {
  final rxName = Platform.environment['SERIAL_TEST_RX'];
  final txName = Platform.environment['SERIAL_TEST_TX'];

  test(
    'reader delivers short replies promptly and preserves burst bytes',
    () async {
      final rx = SerialPort(rxName!);
      final tx = SerialPort(txName!);
      expect(await rx.openReadWrite(), isTrue);
      expect(await tx.openReadWrite(), isTrue);
      final reader = SerialPortReader(rx);
      final received = <int>[];
      final chunks = <int>[];
      var target = 0;
      Completer<void>? delivery;
      final subscription = reader.stream.listen(
        (data) {
          chunks.add(data.length);
          received.addAll(data);
          if (received.length >= target && !(delivery?.isCompleted ?? true)) {
            delivery!.complete();
          }
        },
        onError: (Object error, StackTrace stack) {
          if (!(delivery?.isCompleted ?? true)) {
            delivery!.completeError(error, stack);
          }
        },
      );
      addTearDown(() async {
        await subscription.cancel();
        reader.close();
      });

      Future<int> exchange(List<int> bytes, {int deadlineMs = 200}) async {
        final start = received.length;
        target = start + bytes.length;
        delivery = Completer<void>();
        final watch = Stopwatch()..start();
        expect(
          await tx.write(Uint8List.fromList(bytes), timeout: 500),
          bytes.length,
        );
        await delivery!.future.timeout(Duration(milliseconds: deadlineMs));
        expect(received.sublist(start), bytes);
        return watch.elapsedMicroseconds;
      }

      await exchange(List.filled(255, 0x55), deadlineMs: 2000);
      await Future<void>.delayed(const Duration(milliseconds: 600));
      expect(received, hasLength(255));
      final timings = <int>[];
      for (var i = 0; i < 100; i++) {
        timings.add(await exchange('[N]0400\n'.codeUnits));
      }
      await exchange(List.generate(4096, (i) => i % 256), deadlineMs: 2000);
      expect(chunks, everyElement(inInclusiveRange(1, 255)));
      timings.sort();
      stdout.writeln(
        'Short-reply latency (us): median=${timings[50]}, '
        'p99=${timings[98]}, max=${timings.last}',
      );
    },
    skip: rxName == null || txName == null
        ? 'Set SERIAL_TEST_RX and SERIAL_TEST_TX to an isolated loopback pair'
        : false,
  );
}
