import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/impl/de1/unified_de1/unified_de1.dart';
import 'package:reaprime/src/models/device/transport/serial_port.dart';
import 'package:reaprime/src/models/errors.dart';
import 'package:rxdart/rxdart.dart';

class _QuietSerialTransport extends SerialTransport {
  final _connState = BehaviorSubject<ConnectionState>.seeded(
    ConnectionState.connected,
  );

  @override
  String get id => 'quiet-serial-de1';

  @override
  String get name => 'QuietSerialDe1';

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
  group('_mmrRead timeout (comms-harden #2)', () {
    late _QuietSerialTransport transport;
    late UnifiedDe1 de1;

    setUp(() {
      transport = _QuietSerialTransport();
      de1 = UnifiedDe1(transport: transport);
    });

    tearDown(() {
      transport.dispose();
    });

    test(
      'throws MmrTimeoutException when no matching response arrives',
      () async {
        await expectLater(
          () => de1.getSteamFlow(),
          throwsA(isA<MmrTimeoutException>()),
        );
      },
      timeout: const Timeout(Duration(seconds: 20)),
    );
  });
}
