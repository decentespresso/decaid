import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/device/impl/de1/de1.models.dart';
import 'package:reaprime/src/models/device/impl/de1/unified_de1/unified_de1_transport.dart';

import '../../../../../../helpers/fake_serial_transport.dart';

String _hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

/// Golden 0xA014 frame: R1 1.77, C 1.48, V_abs 21.5 (full byte breakdown in
/// `bengle_est_sample_test.dart`).
const List<int> _golden0xA014 = [
  0x01, 0x89, 0x00, 0xB1, 0x03, 0x52, 0x05, 0xC8, //
  0xCC, 0x06, 0x66, 0x0F, 0x00, 0xD7, 0x01, 0x40,
];

void main() {
  group('0xA014 estimator serial dispatch', () {
    late FakeSerialTransport serial;
    late UnifiedDe1Transport transport;

    setUp(() {
      serial = FakeSerialTransport();
      transport = UnifiedDe1Transport(transport: serial);
    });

    tearDown(() => transport.dispose());

    test('connect() enables the 0xA014 stream with <+T>', () async {
      await transport.connect();
      expect(
        serial.writes,
        contains('<+${Endpoint.estimator.representation}>'),
      );
    });

    test('an inbound [T] frame routes to the estimator subject', () async {
      await transport.connect();

      final frames = <ByteData>[];
      final sub = transport.estimator.listen(frames.add);
      await pumpEventQueue();
      final baseline = frames.length; // seeded zero-length frame

      serial.injectSerial('[T]${_hex(_golden0xA014)}\n');
      await pumpEventQueue();

      expect(
        frames.length,
        baseline + 1,
        reason: '[T] must route to the estimator notification handler',
      );
      final frame = frames.last;
      expect(frame.lengthInBytes, 16);
      // R1 is offset 2, big-endian ÷100.
      expect(frame.getUint16(2, Endian.big) / 100.0, closeTo(1.77, 1e-9));

      await sub.cancel();
    });

    test('a truncated [T] frame is dropped, not routed', () async {
      await transport.connect();

      final frames = <ByteData>[];
      final sub = transport.estimator.listen(frames.add);
      await pumpEventQueue();
      final baseline = frames.length;

      // 10 bytes (20 hex chars) < 16 — must be dropped.
      serial.injectSerial('[T]${_hex(List<int>.filled(10, 0))}\n');
      await pumpEventQueue();

      expect(frames.length, baseline, reason: 'short [T] frame dropped');

      await sub.cancel();
    });

    test(
      'read(estimator) serves the continuously-subscribed subject',
      () async {
        await transport.connect();
        serial.injectSerial('[T]${_hex(_golden0xA014)}\n');
        await pumpEventQueue();

        final latest = await transport.read(Endpoint.estimator);
        expect(latest.getUint16(2, Endian.big) / 100.0, closeTo(1.77, 1e-9));
      },
    );

    test('disconnect() unsubscribes the 0xA014 stream with <-T>', () async {
      await transport.connect();
      serial.writes.clear();
      await transport.disconnect();
      expect(
        serial.writes,
        contains('<-${Endpoint.estimator.representation}>'),
      );
    });
  });
}
