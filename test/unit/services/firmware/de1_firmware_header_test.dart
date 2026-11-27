import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/services/firmware/de1_firmware_header.dart';

Uint8List _buildHeader({
  int checksum = 0x11223344,
  int boardMarker = 0xDE100001,
  int firmwareVersion = 1356,
  int bodyByteCount = 100000,
  int cpuByteCount = 20000,
  int decryptedChecksum = 0x55667788,
  int headerChecksum = 0x99AABBCC,
  int totalSize = 200,
}) {
  final bytes = Uint8List(totalSize);
  final view = ByteData.sublistView(bytes);
  view.setUint32(0, checksum, Endian.little);
  view.setUint32(4, boardMarker, Endian.little);
  view.setUint32(8, firmwareVersion, Endian.little);
  view.setUint32(12, bodyByteCount, Endian.little);
  view.setUint32(16, cpuByteCount, Endian.little);
  view.setUint32(24, decryptedChecksum, Endian.little);
  for (var i = 28; i < 60; i++) {
    bytes[i] = i;
  }
  view.setUint32(60, headerChecksum, Endian.little);
  return bytes;
}

void main() {
  group('De1FirmwareHeader', () {
    test('parses a valid DE1 firmware header', () {
      final image = _buildHeader();
      final header = De1FirmwareHeader.parse(image);

      expect(header.checksum, 0x11223344);
      expect(header.boardMarker, 0xDE100001);
      expect(header.firmwareVersion, 1356);
      expect(header.bodyByteCount, 100000);
      expect(header.cpuByteCount, 20000);
      expect(header.decryptedChecksum, 0x55667788);
      expect(header.initializationVector, hasLength(32));
      expect(header.headerChecksum, 0x99AABBCC);
      expect(header.isDe1Board, isTrue);
    });

    test('rejects image too short for a header', () {
      final image = Uint8List(63);
      expect(
        () => De1FirmwareHeader.parse(image),
        throwsA(isA<FormatException>()),
      );
    });

    test('detects non-DE1 board marker', () {
      final image = _buildHeader(boardMarker: 0x12345678);
      final header = De1FirmwareHeader.parse(image);

      expect(header.isDe1Board, isFalse);
    });

    test('reads varied firmware version', () {
      final image = _buildHeader(firmwareVersion: 1400);
      final header = De1FirmwareHeader.parse(image);

      expect(header.firmwareVersion, 1400);
    });

    test('classifies unrecognized images without assigning a family', () {
      expect(
        De1FirmwareHeader.validateUpload(Uint8List(16)),
        De1FirmwareImageClassification.unrecognizedShort,
      );
      expect(
        De1FirmwareHeader.validateUpload(Uint8List(64)),
        De1FirmwareImageClassification.unrecognizedAtLeastHeader,
      );
    });

    test('classifies and validates a canonical DE1 image', () {
      final image = _buildHeader(
        bodyByteCount: 100,
        cpuByteCount: 50,
        totalSize: 200,
      );
      expect(
        De1FirmwareHeader.validateUpload(image),
        De1FirmwareImageClassification.canonicalDe1,
      );
    });

    test('rejects an empty image before upload', () {
      expect(
        () => De1FirmwareHeader.validateUpload(Uint8List(0)),
        throwsA(isA<FormatException>()),
      );
    });

    test('rejects a DE1 header with an out-of-bounds body', () {
      final image = _buildHeader(bodyByteCount: 1000);
      expect(
        () => De1FirmwareHeader.validateUpload(image),
        throwsA(isA<FormatException>()),
      );
    });

    test('header fields decoded correctly end-to-end', () {
      final image = _buildHeader(
        boardMarker: 0xDE100001,
        firmwareVersion: 1356,
        bodyByteCount: 90000,
        cpuByteCount: 18000,
      );
      final header = De1FirmwareHeader.parse(image);

      expect(header.boardMarker, 0xDE100001);
      expect(header.firmwareVersion, 1356);
      expect(header.bodyByteCount, 90000);
      expect(header.cpuByteCount, 18000);
      expect(header.isDe1Board, isTrue);
    });
  });
}
