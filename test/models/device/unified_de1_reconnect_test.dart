import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/impl/de1/unified_de1/unified_de1.dart';
import 'package:reaprime/src/models/device/transport/serial_port.dart';
import 'package:rxdart/rxdart.dart';

class _QuietSerialTransport extends SerialTransport {
  final _connState = BehaviorSubject<ConnectionState>.seeded(
    ConnectionState.connected,
  );

  @override
  String get id => 'reconnect-test-de1';

  @override
  String get name => 'ReconnectTestDe1';

  @override
  Stream<ConnectionState> get connectionState => _connState.stream;

  @override
  Future<void> connect() async {}

  @override
  Future<void> disconnect() async {}

  @override
  Stream<String> get readStream => const Stream.empty();

  @override
  Stream<Uint8List> get rawStream => const Stream.empty();

  @override
  Future<void> writeHexCommand(Uint8List command) async {}

  @override
  Future<void> writeCommand(String command) async {}

  @override
  Future<void> dispose() async {
    _connState.close();
  }
}

void main() {
  group('UnifiedDe1 reconnect (comms-harden #3)', () {
    test('initRawStream is idempotent — calling it twice does not throw', () {
      final transport = _QuietSerialTransport();
      final de1 = UnifiedDe1(transport: transport);

      expect(() => de1.initRawStream(), returnsNormally);
      expect(
        () => de1.initRawStream(),
        returnsNormally,
        reason:
            'second call simulates a reconnect; must not throw '
            '"Bad state: Stream has already been listened to."',
      );

      transport.dispose();
    });
  });
}
