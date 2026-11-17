import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/device/de1_rawmessage.dart';
import 'package:reaprime/src/models/device/impl/de1/unified_de1/unified_de1.dart';

import '../../helpers/fake_ble_transport.dart';

void main() {
  group('raw write receipts', () {
    late FakeBleTransport transport;
    late UnifiedDe1 de1;

    setUp(() {
      transport = FakeBleTransport();
      de1 = UnifiedDe1(transport: transport);
      de1.initRawStream();
    });

    tearDown(() {
      transport.dispose();
    });

    De1RawMessage writeRequest(
      String payload, {
      String characteristicUUID = 'A010',
    }) => De1RawMessage(
      type: De1RawMessageType.request,
      operation: De1RawOperationType.write,
      characteristicUUID: characteristicUUID,
      payload: payload,
    );

    Future<De1RawMessage> writeAndAwaitReceipt(
      String payload, {
      String characteristicUUID = 'A010',
    }) {
      final receipt = de1.rawOutStream.first;
      de1.sendRawMessage(
        writeRequest(payload, characteristicUUID: characteristicUUID),
      );
      return receipt.timeout(const Duration(seconds: 5));
    }

    test('write response carries the written payload', () async {
      final receipt = await writeAndAwaitReceipt('00401EBAFF000400');

      expect(receipt.type, De1RawMessageType.response);
      expect(receipt.operation, De1RawOperationType.write);
      expect(receipt.characteristicUUID, 'A010');
      expect(receipt.payload, '00401EBAFF000400');
      expect(receipt.toJson()['payload'], '00401EBAFF000400');
    });

    test(
      'write responses for different payloads are distinguishable',
      () async {
        final first = await writeAndAwaitReceipt('00401EBAFF000400');
        final second = await writeAndAwaitReceipt('00401EBAFF000401');

        expect(first.payload, '00401EBAFF000400');
        expect(second.payload, '00401EBAFF000401');
        expect(first.payload, isNot(second.payload));
      },
    );

    test('write response normalises the payload to uppercase hex', () async {
      final receipt = await writeAndAwaitReceipt('00401ebaff00ff00');

      expect(receipt.payload, '00401EBAFF00FF00');
    });

    test('receipt matches the bytes handed to the transport', () async {
      final receipt = await writeAndAwaitReceipt('DEADBEEF');

      expect(receipt.payload, 'DEADBEEF');
      final frame = transport.writes.singleWhere(
        (w) => w.characteristicUUID == 'A010',
      );
      expect(frame.data, Uint8List.fromList([0xDE, 0xAD, 0xBE, 0xEF]));
      expect(frame.withResponse, isTrue);
    });

    test('write response echoes on a characteristic other than A010', () async {
      final receipt = await writeAndAwaitReceipt(
        '0102030405',
        characteristicUUID: 'A00F',
      );

      expect(receipt.characteristicUUID, 'A00F');
      expect(receipt.operation, De1RawOperationType.write);
      expect(receipt.payload, '0102030405');
    });
  });
}
