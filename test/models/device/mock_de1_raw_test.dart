import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/device/de1_rawmessage.dart';
import 'package:reaprime/src/models/device/impl/mock_de1/mock_de1.dart';
import 'package:reaprime/src/models/device/impl/de1/unified_de1/unified_de1.dart';

import '../../helpers/fake_ble_transport.dart';

De1RawMessage request(
  De1RawOperationType operation,
  String characteristicUUID, [
  String payload = '',
]) => De1RawMessage(
  type: De1RawMessageType.request,
  operation: operation,
  characteristicUUID: characteristicUUID,
  payload: payload,
);

Future<De1RawMessage> exchange(MockDe1 de1, De1RawMessage message) {
  final response = de1.rawOutStream.first.timeout(const Duration(seconds: 2));
  de1.sendRawMessage(message);
  return response;
}

void main() {
  late MockDe1 de1;

  setUp(() => de1 = MockDe1());
  tearDown(() => de1.dispose());

  test('write echoes its payload as uppercase hex in the raw schema', () async {
    final response = await exchange(
      de1,
      request(De1RawOperationType.write, 'A010', '00401ebaff000400'),
    );

    expect(response.toJson(), {
      'type': 'response',
      'operation': 'write',
      'characteristicUUID': 'A010',
      'payload': '00401EBAFF000400',
    });
  });

  test('two payloads on the same UUID have distinguishable receipts', () async {
    final first = await exchange(
      de1,
      request(De1RawOperationType.write, 'A010', '00401EBAFF000400'),
    );
    final second = await exchange(
      de1,
      request(De1RawOperationType.write, 'A010', '00401EBAFF000401'),
    );

    expect(first.payload, '00401EBAFF000400');
    expect(second.payload, '00401EBAFF000401');
    expect(second.characteristicUUID, 'A010');
  });

  test('raw responses are broadcast to simultaneous subscribers', () async {
    expect(de1.rawOutStream.isBroadcast, isTrue);
    final first = de1.rawOutStream.first;
    final second = de1.rawOutStream.first;
    de1.sendRawMessage(request(De1RawOperationType.write, 'A010', '00'));

    expect((await first).toJson(), (await second).toJson());
  });

  test('writes record the decoded bytes and characteristic', () async {
    await exchange(de1, request(De1RawOperationType.write, 'A010', '00abFF'));
    final second = await exchange(
      de1,
      request(De1RawOperationType.write, 'A00F', '0102'),
    );
    expect(second.characteristicUUID, 'A00F');
    expect(second.payload, '0102');

    expect(de1.rawWrites.map((write) => write.characteristicUUID), [
      'A010',
      'A00F',
    ]);
    expect(de1.rawWrites[0].data, [0x00, 0xAB, 0xFF]);
    expect(de1.rawWrites[1].data, [0x01, 0x02]);
  });

  test(
    'read returns configured bytes, independent of the request payload',
    () async {
      de1.rawReadResponses['A00B'] = [0x00, 0x0A, 0xFF];
      final response = await exchange(
        de1,
        request(De1RawOperationType.read, 'A00B', 'ignored'),
      );

      expect(response.toJson(), {
        'type': 'response',
        'operation': 'read',
        'characteristicUUID': 'A00B',
        'payload': '000AFF',
      });
      expect(de1.rawWrites, isEmpty);
    },
  );

  test('default read returns an empty payload', () async {
    final response = await exchange(
      de1,
      request(De1RawOperationType.read, 'A001'),
    );
    expect(response.payload, isEmpty);
  });

  test(
    'absent and unknown characteristics emit no frame, matching UnifiedDe1',
    () async {
      final transport = FakeBleTransport();
      final real = UnifiedDe1(transport: transport)..initRawStream();
      addTearDown(transport.dispose);
      transport.queueReadError(
        'A00B',
        StateError('characteristic not present'),
      );
      transport.queueRead('A001', Uint8List(0));
      de1.rawReadResponses['A00B'] = null;
      final mockResponses = <De1RawMessage>[];
      final realResponses = <De1RawMessage>[];
      final mockSubscription = de1.rawOutStream.listen(mockResponses.add);
      final realSubscription = real.rawOutStream.listen(realResponses.add);
      addTearDown(mockSubscription.cancel);
      addTearDown(realSubscription.cancel);
      final mockResponse = de1.rawOutStream.first;
      final realResponse = real.rawOutStream.first;

      for (final machine in [de1, real]) {
        machine.sendRawMessage(request(De1RawOperationType.read, 'FFFF'));
        machine.sendRawMessage(request(De1RawOperationType.read, 'A00B'));
        machine.sendRawMessage(request(De1RawOperationType.notify, 'A001'));
        machine.sendRawMessage(request(De1RawOperationType.read, 'A001'));
      }
      await Future.wait([
        mockResponse,
        realResponse,
      ]).timeout(const Duration(seconds: 2));
      // An absent characteristic suppresses writes as well as reads.
      de1.sendRawMessage(request(De1RawOperationType.write, 'A00B', '0102'));
      await Future<void>.delayed(Duration.zero);
      expect(de1.rawWrites, isEmpty);

      expect(mockResponses.map((response) => response.toJson()).toList(), [
        {
          'type': 'response',
          'operation': 'read',
          'characteristicUUID': 'A001',
          'payload': '',
        },
      ]);
      expect(
        realResponses.map((response) => response.toJson()).toList(),
        mockResponses.map((response) => response.toJson()).toList(),
      );
    },
  );

  test(
    'invalid write emits no receipt and does not stop later requests',
    () async {
      final responses = <De1RawMessage>[];
      final subscription = de1.rawOutStream.listen(responses.add);
      addTearDown(subscription.cancel);
      de1.sendRawMessage(request(De1RawOperationType.write, 'A010', 'xyz'));
      await exchange(de1, request(De1RawOperationType.write, 'A010', '01'));
      expect(responses.map((response) => response.payload), ['01']);
      expect(de1.rawWrites, hasLength(1));
    },
  );

  test('dispose closes the owned raw stream', () async {
    final done = expectLater(de1.rawOutStream, emitsDone);
    await de1.dispose();
    await done;
  });
}
