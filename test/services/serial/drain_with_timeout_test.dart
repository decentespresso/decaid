import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/services/serial/utils.dart';

/// Regression coverage for the Windows scan hang: probing a non-Decent
/// USB-serial device (e.g. a Valve VR Radio on COM3) blocked the main
/// isolate forever inside the native `sp_drain`, freezing app startup.
///
/// `drainWithTimeout` is the non-blocking replacement — it polls the
/// output-buffer count and MUST return within its timeout no matter what
/// the device does. These tests pin that invariant without touching FFI.
void main() {
  group('drainWithTimeout', () {
    test('returns without sleeping when buffer is already empty', () async {
      var sleeps = 0;
      await drainWithTimeout(
        bytesToWrite: () => 0,
        sleep: (_) async => sleeps++,
      );
      expect(sleeps, 0);
    });

    test('returns once the buffer drains partway through', () async {
      final readings = <int>[3, 2, 0, 0];
      var i = 0;
      var sleeps = 0;
      await drainWithTimeout(
        bytesToWrite: () => readings[i++],
        sleep: (_) async => sleeps++,
      );
      expect(sleeps, 2);
    });

    test('is bounded when the buffer never empties (never hangs)', () async {
      var sleeps = 0;
      await drainWithTimeout(
        bytesToWrite: () => 10,
        timeout: const Duration(milliseconds: 100),
        pollInterval: const Duration(milliseconds: 10),
        sleep: (_) async => sleeps++,
      );
      expect(sleeps, 10);
    });

    test('completes promptly even with the default real sleep', () async {
      await drainWithTimeout(
        bytesToWrite: () => 1,
        timeout: const Duration(milliseconds: 20),
        pollInterval: const Duration(milliseconds: 5),
      ).timeout(const Duration(seconds: 2));
    });
  });
}
