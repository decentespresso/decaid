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
  int unused = 0,
  Uint8List? initializationVector,
  int totalSize = 200,
}) {
  final bytes = Uint8List(totalSize);
  final view = ByteData.sublistView(bytes);
  view.setUint32(0, checksum, Endian.little);
  view.setUint32(4, boardMarker, Endian.little);
  view.setUint32(8, firmwareVersion, Endian.little);
  view.setUint32(12, bodyByteCount, Endian.little);
  view.setUint32(16, cpuByteCount, Endian.little);
  view.setUint32(20, unused, Endian.little);
  view.setUint32(24, decryptedChecksum, Endian.little);
  for (var i = 28; i < 60; i++) {
    bytes[i] = initializationVector?[i - 28] ?? i;
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

    test('publishes the approved route and body safety limits', () {
      expect(De1FirmwareHeader.maxDe1FirmwareImageByteLength, 512 * 1024);
      expect(De1FirmwareHeader.maxCanonicalBodyByteLength, 504 * 1024);
      expect(De1FirmwareHeader.maxBengleFirmwareImageByteLength, 960 * 1024);
    });

    test('accepts an unrecognized DE1 image at the full-image boundary', () {
      expect(
        De1FirmwareHeader.validateUpload(
          Uint8List(De1FirmwareHeader.maxDe1FirmwareImageByteLength),
        ),
        De1FirmwareImageClassification.unrecognizedAtLeastHeader,
      );
    });

    test('rejects an unrecognized DE1 image above the full-image boundary', () {
      expect(
        () => De1FirmwareHeader.validateUpload(
          Uint8List(De1FirmwareHeader.maxDe1FirmwareImageByteLength + 1),
        ),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            'Firmware image exceeds 524288 bytes for DE1/legacy target',
          ),
        ),
      );
    });

    test('accepts and rejects the recognized DE1 full-image boundary', () {
      final image = _buildHeader(
        bodyByteCount: 100,
        cpuByteCount: 50,
        totalSize: De1FirmwareHeader.maxDe1FirmwareImageByteLength,
      );
      expect(
        De1FirmwareHeader.validateUpload(image),
        De1FirmwareImageClassification.canonicalDe1,
      );
      expect(
        () =>
            De1FirmwareHeader.validateUpload(Uint8List.fromList([...image, 0])),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            'Firmware image exceeds 524288 bytes for DE1/legacy target',
          ),
        ),
      );
    });

    test('accepts and rejects the Bengle full-image boundary explicitly', () {
      final image = _buildHeader(
        bodyByteCount: 100,
        cpuByteCount: 50,
        totalSize: De1FirmwareHeader.maxBengleFirmwareImageByteLength,
      );
      expect(
        De1FirmwareHeader.validateUpload(
          image,
          target: De1FirmwareTarget.bengle,
        ),
        De1FirmwareImageClassification.canonicalDe1,
      );
      expect(
        () => De1FirmwareHeader.validateUpload(
          Uint8List.fromList([...image, 0]),
          target: De1FirmwareTarget.bengle,
        ),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            'Firmware image exceeds 983040 bytes for Bengle target',
          ),
        ),
      );
    });

    test('unrecognized Bengle bounds require an explicit Bengle route', () {
      final image = Uint8List(
        De1FirmwareHeader.maxBengleFirmwareImageByteLength,
      );
      expect(
        De1FirmwareHeader.validateUpload(
          image,
          target: De1FirmwareTarget.bengle,
        ),
        De1FirmwareImageClassification.unrecognizedAtLeastHeader,
      );
      expect(
        () => De1FirmwareHeader.validateUpload(image),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            'Firmware image exceeds 524288 bytes for DE1/legacy target',
          ),
        ),
      );
      expect(
        () => De1FirmwareHeader.validateUpload(
          Uint8List(De1FirmwareHeader.maxBengleFirmwareImageByteLength + 1),
          target: De1FirmwareTarget.bengle,
        ),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            'Firmware image exceeds 983040 bytes for Bengle target',
          ),
        ),
      );
    });

    test('rejects an empty image before upload', () {
      expect(
        () => De1FirmwareHeader.validateUpload(Uint8List(0)),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            'Firmware image is empty',
          ),
        ),
      );
    });

    test('accepts the canonical body boundary', () {
      final image = _buildHeader(
        bodyByteCount: De1FirmwareHeader.maxCanonicalBodyByteLength,
        cpuByteCount: 100,
        totalSize: De1FirmwareHeader.maxCanonicalBodyByteLength + 64,
      );
      expect(
        De1FirmwareHeader.validateUpload(image),
        De1FirmwareImageClassification.canonicalDe1,
      );
    });

    test('rejects a zero DE1 body before checking CPU length', () {
      final image = _buildHeader(bodyByteCount: 0, cpuByteCount: 1);
      expect(
        () => De1FirmwareHeader.validateUpload(image),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            'Firmware body length is out of bounds',
          ),
        ),
      );
    });

    test('rejects a DE1 body above the canonical body boundary', () {
      final image = _buildHeader(
        bodyByteCount: De1FirmwareHeader.maxCanonicalBodyByteLength + 1,
        cpuByteCount: 100,
        totalSize: De1FirmwareHeader.maxCanonicalBodyByteLength + 65,
      );
      expect(
        () => De1FirmwareHeader.validateUpload(image),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            'Firmware body length exceeds 516096 bytes',
          ),
        ),
      );
    });

    test('rejects a body that is incomplete for the declared image', () {
      final image = _buildHeader(
        bodyByteCount: 100,
        cpuByteCount: 50,
        totalSize: 150,
      );
      expect(
        () => De1FirmwareHeader.validateUpload(image),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            'Firmware image is incomplete for its declared body',
          ),
        ),
      );
    });

    test('accepts a body that fits the declared image', () {
      final image = _buildHeader(
        bodyByteCount: 100,
        cpuByteCount: 50,
        totalSize: 164,
      );
      expect(
        De1FirmwareHeader.validateUpload(image),
        De1FirmwareImageClassification.canonicalDe1,
      );
    });

    test('isolates the CPU length bound', () {
      for (final cpuByteCount in [0, 101]) {
        final image = _buildHeader(
          bodyByteCount: 100,
          cpuByteCount: cpuByteCount,
        );
        expect(
          () => De1FirmwareHeader.validateUpload(image),
          throwsA(
            isA<FormatException>().having(
              (error) => error.message,
              'message',
              'Firmware CPU length is out of bounds',
            ),
          ),
        );
      }
    });

    test('isolates the reserved header field', () {
      final image = _buildHeader(
        unused: 1,
        bodyByteCount: 100,
        cpuByteCount: 50,
      );
      expect(
        () => De1FirmwareHeader.validateUpload(image),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            'Firmware header reserved field is non-zero',
          ),
        ),
      );
    });

    test('isolates each checksum and IV condition', () {
      final cases = <({String reason, Uint8List image})>[
        (
          reason: 'Firmware checksum is zero',
          image: _buildHeader(
            checksum: 0,
            bodyByteCount: 100,
            cpuByteCount: 50,
          ),
        ),
        (
          reason: 'Firmware decrypted checksum is zero',
          image: _buildHeader(
            decryptedChecksum: 0,
            bodyByteCount: 100,
            cpuByteCount: 50,
          ),
        ),
        (
          reason: 'Firmware header checksum is zero',
          image: _buildHeader(
            headerChecksum: 0,
            bodyByteCount: 100,
            cpuByteCount: 50,
          ),
        ),
        (
          reason: 'Firmware initialization vector is zero',
          image: _buildHeader(
            initializationVector: Uint8List(32),
            bodyByteCount: 100,
            cpuByteCount: 50,
          ),
        ),
      ];
      for (final testCase in cases) {
        expect(
          () => De1FirmwareHeader.validateUpload(testCase.image),
          throwsA(
            isA<FormatException>().having(
              (error) => error.message,
              'message',
              testCase.reason,
            ),
          ),
        );
      }
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
