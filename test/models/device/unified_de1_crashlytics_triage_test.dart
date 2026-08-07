import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/impl/de1/unified_de1/unified_de1.dart';
import 'package:reaprime/src/models/device/transport/serial_port.dart';
import 'package:reaprime/src/models/errors.dart';
import 'package:rxdart/rxdart.dart';

/// Regression coverage for two crashes surfaced in the 2026-04-24
/// Crashlytics triage pass:
///
/// 1b. `_parseStateAndShotSample` threw `RangeError (length 0..8: 9)`
///     when a short (9-byte) shotSample frame was published. Observed on
///     Galaxy Tab A9+ v0.5.13 (issue `204f6a96…`). Fix: drop short
///     state/shotSample frames at the transport notification layer.
///
/// 1c. `UnifiedDe1Transport.disconnect()` threw `LateInitializationError:
///     _transportSubscription` when invoked before `_serialConnect()` had
///     wired the subscription. Observed on Android v0.5.14, FRESH
///     2026-04-23 (issue `9b3a0fdf…`). Fix: subscription is nullable.

class _ControllableSerialTransport extends SerialTransport {
  final _connState = BehaviorSubject<ConnectionState>.seeded(
    ConnectionState.connected,
  );
  final _readCtl = StreamController<String>.broadcast();

  @override
  String get id => 'triage-test-de1';

  @override
  String get name => 'TriageTestDe1';

  @override
  Stream<ConnectionState> get connectionState => _connState.stream;

  @override
  Future<void> connect() async {}

  @override
  Future<void> disconnect() async {}

  @override
  Stream<String> get readStream => _readCtl.stream;

  @override
  Stream<Uint8List> get rawStream => const Stream.empty();

  @override
  Future<void> writeHexCommand(Uint8List command) async {}

  @override
  Future<void> writeCommand(String command) async {}

  /// Feeds a raw serial chunk into the transport's input parser.
  void injectSerial(String chunk) {
    _readCtl.add(chunk);
  }

  @override
  Future<void> dispose() async {
    _connState.close();
    _readCtl.close();
  }
}

void main() {
  group('1b — short BLE frames do not crash _parseStateAndShotSample', () {
    late _ControllableSerialTransport transport;
    late UnifiedDe1 de1;

    setUp(() {
      transport = _ControllableSerialTransport();
      de1 = UnifiedDe1(transport: transport);
    });

    tearDown(() {
      transport.dispose();
    });

    test('a 9-byte shotSample does not propagate a RangeError through '
        'currentSnapshot', () async {
      final errors = <Object>[];
      final sub = de1.currentSnapshot.listen((_) {}, onError: errors.add);

      final onConnectFuture = de1.onConnect().catchError((e) {
        if (e is MmrTimeoutException) return;
        throw e;
      });

      await Future<void>.delayed(const Duration(milliseconds: 100));

      transport.injectSerial('[M]000102030405060708\n');

      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(
        errors.whereType<RangeError>(),
        isEmpty,
        reason:
            'short frames must be dropped at the notification '
            'layer, not propagate through the parser',
      );

      await sub.cancel();
      await onConnectFuture;
    }, timeout: const Timeout(Duration(seconds: 20)));
  });

  group('1c — UnifiedDe1Transport.disconnect() is safe before connect()', () {
    late _ControllableSerialTransport transport;

    setUp(() {
      transport = _ControllableSerialTransport();
    });

    tearDown(() {
      transport.dispose();
    });

    test('disconnect() without a prior connect() does not throw '
        'LateInitializationError', () async {
      final de1 = UnifiedDe1(transport: transport);
      await expectLater(de1.disconnect(), completes);
    });
  });
}
