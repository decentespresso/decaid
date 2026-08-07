import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/impl/de1/de1.models.dart';
import 'package:reaprime/src/models/device/impl/de1/unified_de1/unified_de1_transport.dart';
import 'package:reaprime/src/models/device/transport/logical_endpoint.dart';
import 'package:reaprime/src/models/device/transport/serial_port.dart';
import 'package:rxdart/rxdart.dart';

import '../../../../helpers/fake_ble_transport.dart';

/// Minimal LogicalEndpoint stub for exercising the guards in
/// `UnifiedDe1Transport.{read,write,writeWithResponse}`. Not a Dart enum,
/// so the `is! Endpoint` check fires on the serial path.
class _StubEndpoint implements LogicalEndpoint {
  @override
  final String? uuid;
  @override
  final String? representation;
  @override
  final String name;
  const _StubEndpoint({this.uuid, this.representation, required this.name});
}

/// Inline serial-transport stub: `FakeBleTransport` is BLE-only by
/// design (the consolidated helper is used across the BLE-facing
/// tests), so the small serial stub stays here for the wire-gap tests.
class _StubSerialTransport extends SerialTransport {
  final _connState = BehaviorSubject<ConnectionState>.seeded(
    ConnectionState.connected,
  );

  @override
  String get id => 'stub-serial';

  @override
  String get name => 'StubSerial';

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
  Future<void> writeCommand(String command) async {}

  @override
  Future<void> writeHexCommand(Uint8List command) async {}

  @override
  Future<void> dispose() async => _connState.close();
}

void main() {
  group('LogicalEndpoint', () {
    test(
      'every Endpoint value implements LogicalEndpoint with non-null wire ids',
      () {
        for (final ep in Endpoint.values) {
          expect(
            ep,
            isA<LogicalEndpoint>(),
            reason: '${ep.name} must implement LogicalEndpoint',
          );
          expect(ep.uuid, isNotNull, reason: '${ep.name} uuid');
          expect(
            ep.representation,
            isNotNull,
            reason: '${ep.name} representation',
          );
          expect(ep.name, isNotEmpty);
        }
      },
    );
  });

  group('UnifiedDe1Transport wire-support guards', () {
    test('read() on BLE with null uuid throws StateError mentioning '
        '"no BLE wire support"', () async {
      final transport = FakeBleTransport();
      addTearDown(transport.dispose);
      final unified = UnifiedDe1Transport(transport: transport);
      const stub = _StubEndpoint(
        uuid: null,
        representation: 'Z',
        name: 'stubNoUuid',
      );

      await expectLater(
        unified.read(stub),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('no BLE wire support'),
          ),
        ),
      );
    });

    test('read() on serial with non-Endpoint LogicalEndpoint throws '
        'StateError mentioning "is not a DE1 Endpoint"', () async {
      final transport = _StubSerialTransport();
      addTearDown(transport.dispose);
      final unified = UnifiedDe1Transport(transport: transport);
      const stub = _StubEndpoint(
        uuid: 'A0FF',
        representation: 'Z',
        name: 'stubNotEndpoint',
      );

      await expectLater(
        unified.read(stub),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('is not a DE1 Endpoint'),
          ),
        ),
      );
    });

    test('write() on serial with null representation throws StateError '
        'mentioning "no serial wire support"', () async {
      final transport = _StubSerialTransport();
      addTearDown(transport.dispose);
      final unified = UnifiedDe1Transport(transport: transport);
      const stub = _StubEndpoint(
        uuid: 'A0FF',
        representation: null,
        name: 'stubNoRepr',
      );

      await expectLater(
        unified.write(stub, Uint8List(0)),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('no serial wire support'),
          ),
        ),
      );
    });
  });
}
