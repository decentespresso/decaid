import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/device/de1_interface.dart';
import 'package:reaprime/src/models/device/impl/de1/unified_de1/calibration_codec.dart';

Uint8List _packet({
  int writeKey = 0,
  int command = 0,
  int target = 0,
  int reportedRaw = 0,
  int measuredRaw = 0,
}) {
  final bytes = ByteData(De1CalibrationCodec.packetLength);
  bytes.setUint32(0, writeKey, Endian.big);
  bytes.setUint8(4, command);
  bytes.setUint8(5, target);
  bytes.setUint32(6, reportedRaw, Endian.big);
  bytes.setInt32(10, measuredRaw, Endian.big);
  return bytes.buffer.asUint8List();
}

void main() {
  group('De1CalibrationTarget', () {
    test('maps all three targets to DE1app wire values', () {
      expect(De1CalibrationTarget.flow.wireValue, 0);
      expect(De1CalibrationTarget.pressure.wireValue, 1);
      expect(De1CalibrationTarget.temperature.wireValue, 2);
      for (final target in De1CalibrationTarget.values) {
        expect(De1CalibrationTarget.fromWireValue(target.wireValue), target);
      }
    });

    test('fromWireValue returns null for unknown values', () {
      expect(De1CalibrationTarget.fromWireValue(9), isNull);
    });
  });

  group('encodeRead', () {
    test('current read matches the DE1app wire format', () {
      expect(
        De1CalibrationCodec.encodeRead(
          De1CalibrationTarget.flow,
          factory: false,
        ),
        [0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0, 0, 0, 0, 0, 0, 0, 0],
      );
    });

    test('factory read uses CalCommand 3', () {
      expect(
        De1CalibrationCodec.encodeRead(
          De1CalibrationTarget.pressure,
          factory: true,
        ),
        [0x00, 0x00, 0x00, 0x01, 0x03, 0x01, 0, 0, 0, 0, 0, 0, 0, 0],
      );
    });

    test('encodes every target', () {
      for (final target in De1CalibrationTarget.values) {
        final bytes = De1CalibrationCodec.encodeRead(target, factory: false);
        expect(bytes.length, De1CalibrationCodec.packetLength);
        expect(bytes[5], target.wireValue);
      }
    });
  });

  group('encodeWrite', () {
    test('matches the DE1app wire format for flow', () {
      expect(
        De1CalibrationCodec.encodeWrite(
          const De1Calibration(
            target: De1CalibrationTarget.flow,
            de1ReportedValue: 1.0,
            measuredValue: 1.0,
          ),
        ),
        [
          0xCA, 0xFE, 0xF0, 0x0D, 0x01, 0x00, //
          0x00, 0x01, 0x00, 0x00, //
          0x00, 0x01, 0x00, 0x00,
        ],
      );
    });

    test('encodes signed measured values as two-complement Q16.16', () {
      expect(
        De1CalibrationCodec.encodeWrite(
          const De1Calibration(
            target: De1CalibrationTarget.temperature,
            de1ReportedValue: 93.5,
            measuredValue: -0.5,
          ),
        ),
        [
          0xCA, 0xFE, 0xF0, 0x0D, 0x01, 0x02, //
          0x00, 0x5D, 0x80, 0x00, //
          0xFF, 0xFF, 0x80, 0x00,
        ],
      );
    });

    test('encodes negative reported values as signed Q16.16', () {
      final bytes = De1CalibrationCodec.encodeWrite(
        const De1Calibration(
          target: De1CalibrationTarget.temperature,
          de1ReportedValue: -0.5,
          measuredValue: -1.25,
        ),
      );
      expect(bytes[6], 0xFF);
      expect(bytes[7], 0xFF);
      expect(bytes[8], 0x80);
      expect(bytes[9], 0x00);
      final packet = De1CalibrationCodec.decode(bytes);
      expect(packet.de1ReportedValue, -0.5);
      expect(packet.measuredValue, -1.25);
    });

    test('rounds fixed-point values half away from zero', () {
      final bytes = De1CalibrationCodec.encodeWrite(
        const De1Calibration(
          target: De1CalibrationTarget.flow,
          de1ReportedValue: 1.0,
          measuredValue: -0.5,
        ),
      );
      expect(De1CalibrationCodec.decode(bytes).de1ReportedValue, 1.0);
      expect(De1CalibrationCodec.decode(bytes).measuredValue, -0.5);
    });

    test('rejects non-finite values', () {
      expect(
        () => De1CalibrationCodec.encodeWrite(
          const De1Calibration(
            target: De1CalibrationTarget.flow,
            de1ReportedValue: double.nan,
            measuredValue: 1.0,
          ),
        ),
        throwsArgumentError,
      );
      expect(
        () => De1CalibrationCodec.encodeWrite(
          De1Calibration(
            target: De1CalibrationTarget.flow,
            de1ReportedValue: 1.0,
            measuredValue: double.infinity,
          ),
        ),
        throwsArgumentError,
      );
    });

    test('rejects values outside the fixed-point ranges', () {
      expect(
        () => De1CalibrationCodec.encodeWrite(
          const De1Calibration(
            target: De1CalibrationTarget.flow,
            de1ReportedValue: 32768,
            measuredValue: 1.0,
          ),
        ),
        throwsArgumentError,
      );
      expect(
        () => De1CalibrationCodec.encodeWrite(
          const De1Calibration(
            target: De1CalibrationTarget.flow,
            de1ReportedValue: 1.0,
            measuredValue: -32768.5,
          ),
        ),
        throwsArgumentError,
      );
      expect(
        () => De1CalibrationCodec.encodeWrite(
          const De1Calibration(
            target: De1CalibrationTarget.flow,
            de1ReportedValue: 1.0,
            measuredValue: 32768,
          ),
        ),
        throwsArgumentError,
      );
    });
  });

  group('decode', () {
    test('decodes returned data for a current read', () {
      final packet = De1CalibrationCodec.decode(
        _packet(
          writeKey: 0,
          command: 0,
          target: 0,
          reportedRaw: 0x00010000,
          measuredRaw: 0xFFFF8000,
        ),
      );
      expect(packet.isReturnedData, isTrue);
      expect(packet.command, 0);
      expect(packet.target, De1CalibrationTarget.flow);
      expect(packet.de1ReportedValue, 1.0);
      expect(packet.measuredValue, -0.5);
    });

    test('decodes signed and fractional values', () {
      final packet = De1CalibrationCodec.decode(
        _packet(
          writeKey: 0,
          command: 3,
          target: 1,
          reportedRaw: 0x00094000,
          measuredRaw: 0xFFFEC000,
        ),
      );
      expect(packet.command, 3);
      expect(packet.target, De1CalibrationTarget.pressure);
      expect(packet.de1ReportedValue, 9.25);
      expect(packet.measuredValue, -1.25);
    });

    test('distinguishes a write acknowledgement from returned data', () {
      final ack = De1CalibrationCodec.decode(
        _packet(writeKey: 0xCAFEF00D, command: 1, target: 2),
      );
      expect(ack.isReturnedData, isFalse);
      expect(ack.matches(De1CalibrationCodec.writeCommand, ack.target), isTrue);
    });

    test('rejects short packets', () {
      expect(
        () => De1CalibrationCodec.decode(Uint8List(13)),
        throwsFormatException,
      );
    });

    test('rejects unknown targets', () {
      expect(
        () => De1CalibrationCodec.decode(_packet(target: 9)),
        throwsFormatException,
      );
    });

    test('tryDecode returns null instead of throwing', () {
      expect(De1CalibrationCodec.tryDecode(Uint8List(4)), isNull);
      expect(De1CalibrationCodec.tryDecode(_packet(target: 9)), isNull);
      expect(De1CalibrationCodec.tryDecode(_packet()), isNotNull);
    });
  });
}
