import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/services/serial/mmr_codec.dart';

void main() {
  group('buildMmrReadRequest', () {
    test('encodes v13Model address (0x0080000C, length 4)', () {
      final req = buildMmrReadRequest(address: 0x0080000C, length: 4);

      expect(req, hasLength(20));
      expect(req[0], equals(4));
      expect(req[1], equals(0x80));
      expect(req[2], equals(0x00));
      expect(req[3], equals(0x0C));
      expect(req.sublist(4), everyElement(equals(0)));
    });
  });

  group('decodeMmrInt32Response', () {
    test('returns the int32 value when the address triplet matches', () {
      final payload = [
        0x04,
        0x80,
        0x00,
        0x0C,
        0x05,
        0x00,
        0x00,
        0x00,
        ...List.filled(12, 0),
      ];
      final hex = payload
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join();
      final line = '[E]$hex';

      final result = decodeMmrInt32Response(
        line,
        expectedAddr: (0x80, 0x00, 0x0C),
      );

      expect(result, equals(5));
    });

    test('returns the int32 value for a Bengle-range model (>= 128)', () {
      // Real Bengle reply observed on hardware: [4, 80, 0, c, 80, 0, 0, 0, ...]
      // Value bytes [4..7] = [0x80, 0x00, 0x00, 0x00] little-endian = 128.
      final payload = [
        0x04,
        0x80,
        0x00,
        0x0C,
        0x80,
        0x00,
        0x00,
        0x00,
        ...List.filled(12, 0),
      ];
      final hex = payload
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join();
      final result = decodeMmrInt32Response(
        '[E]$hex',
        expectedAddr: (0x80, 0x00, 0x0C),
      );
      expect(result, equals(128));
    });

    test('returns null when the address triplet does not match', () {
      final payload = [
        0x04,
        0x99,
        0x99,
        0x99,
        0x00,
        0x00,
        0x00,
        0x05,
        ...List.filled(12, 0),
      ];
      final hex = payload
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join();
      final result = decodeMmrInt32Response(
        '[E]$hex',
        expectedAddr: (0x80, 0x00, 0x0C),
      );
      expect(result, isNull);
    });

    test('returns null for a non-[E] line', () {
      expect(
        decodeMmrInt32Response('[M]00112233', expectedAddr: (0x80, 0x00, 0x0C)),
        isNull,
      );
    });

    test('returns null for malformed hex', () {
      expect(
        decodeMmrInt32Response('[E]xyz', expectedAddr: (0x80, 0x00, 0x0C)),
        isNull,
      );
    });

    test('returns null for too-short payload', () {
      final hex = '040000000000';
      expect(
        decodeMmrInt32Response('[E]$hex', expectedAddr: (0x00, 0x00, 0x00)),
        isNull,
      );
    });
  });
}
