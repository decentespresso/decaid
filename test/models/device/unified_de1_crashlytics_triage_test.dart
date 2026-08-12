import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/impl/de1/de1.models.dart';
import 'package:reaprime/src/models/device/impl/de1/unified_de1/unified_de1.dart';
import 'package:reaprime/src/models/device/transport/serial_port.dart';
import 'package:rxdart/rxdart.dart';

import '../../helpers/fake_ble_transport.dart';

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
    test('a 9-byte shotSample does not propagate a RangeError through '
        'currentSnapshot', () async {
      final transport = FakeBleTransport()..queueOnConnectResponses();
      final de1 = UnifiedDe1(transport: transport);

      final errors = <Object>[];
      final sub = de1.currentSnapshot.listen((_) {}, onError: errors.add);

      await de1.onConnect();

      transport.emitNotification(Endpoint.shotSample, [
        0x00,
        0x01,
        0x02,
        0x03,
        0x04,
        0x05,
        0x06,
        0x07,
        0x08,
      ]);
      await Future<void>.delayed(Duration.zero);

      expect(
        errors.whereType<RangeError>(),
        isEmpty,
        reason:
            'short frames must be dropped at the notification '
            'layer, not propagate through the parser',
      );

      await sub.cancel();
      await de1.disconnect();
      await transport.dispose();
    });
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
