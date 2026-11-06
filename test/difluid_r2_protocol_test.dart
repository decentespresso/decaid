import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/device/impl/difluid/difluid_r2_protocol.dart';

void main() {
  group('DifluidR2Protocol', () {
    test('builds known setup and single-test commands', () {
      expect(
        DifluidR2Protocol.setCelsiusCommand(),
        Uint8List.fromList([0xDF, 0xDF, 0x01, 0x00, 0x01, 0x00, 0xC0]),
      );
      expect(
        DifluidR2Protocol.singleTestCommand(),
        Uint8List.fromList([0xDF, 0xDF, 0x03, 0x00, 0x00, 0xC1]),
      );
    });

    test('parses a TDS result packet with refractive index', () {
      final packet = Uint8List.fromList([
        0xDF,
        0xDF,
        0x03,
        0x00,
        0x07,
        0x02,
        0x03,
        0xCA,
        0x00,
        0x02,
        0x09,
        0x14,
        0xB6,
      ]);

      final event = DifluidR2Protocol.parse(packet);

      expect(event.kind, DifluidR2EventKind.reading);
      expect(event.tds, closeTo(9.7, 0.001));
      expect(event.refractiveIndex, closeTo(1.33396, 0.00001));
      expect(event.measuring, isFalse);
    });

    test('parses a negative TDS result packet', () {
      final packet = Uint8List.fromList([
        0xDF,
        0xDF,
        0x03,
        0x00,
        0x03,
        0x02,
        0xFF,
        0xF9,
        0xBE,
      ]);

      final event = DifluidR2Protocol.parse(packet);

      expect(event.tds, closeTo(-0.07, 0.001));
    });

    test('rejects packets with an invalid checksum', () {
      final packet = Uint8List.fromList([
        0xDF,
        0xDF,
        0x03,
        0x00,
        0x03,
        0x02,
        0x00,
        0x0C,
        0x00,
      ]);

      expect(
        () => DifluidR2Protocol.parse(packet),
        throwsA(isA<DifluidR2ProtocolException>()),
      );
    });
  });
}
