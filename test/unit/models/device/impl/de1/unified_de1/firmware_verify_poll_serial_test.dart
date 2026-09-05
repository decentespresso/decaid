import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/device/impl/de1/de1.models.dart';
import 'package:reaprime/src/models/device/impl/de1/unified_de1/unified_de1_transport.dart';

import '../../../../../../helpers/fake_serial_transport.dart';

String _hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

void main() {
  group('readFwMapRequestFresh over serial', () {
    late FakeSerialTransport serial;
    late UnifiedDe1Transport transport;

    setUp(() {
      serial = FakeSerialTransport();
      transport = UnifiedDe1Transport(transport: serial);
    });

    tearDown(() => transport.dispose());

    test(
      'reprovokes with <+I> and resolves with the next fresh [I] frame',
      () async {
        await transport.connect();
        serial.writes.clear();

        // Start the fresh read: it arms for the NEXT [I] then re-sends <+I>. Do
        // not await yet — the fresh frame has not arrived.
        final pending = transport.readFwMapRequestFresh();
        await pumpEventQueue();

        // The reprovoke went out (no matching <-I> — the continuous notify sub
        // must survive).
        expect(
          serial.writes,
          contains('<+${Endpoint.fwMapRequest.representation}>'),
          reason: 'serial fresh-read reprovokes the fwMapRequest notify',
        );
        expect(
          serial.writes,
          isNot(contains('<-${Endpoint.fwMapRequest.representation}>')),
          reason: 'the continuous subscription must not be dropped mid-update',
        );

        // The firmware now pushes a fresh [I] frame.
        serial.injectSerial(
          '[I]${_hex(const [0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07])}\n',
        );
        await pumpEventQueue();

        final fresh = await pending;
        expect(fresh.lengthInBytes, 7);
        expect(fresh.getUint8(0), 0x01);
      },
    );
  });
}
