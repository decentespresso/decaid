import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

Uint8List hexToBytes(String hex) {
  hex = hex.replaceAll(RegExp(r'\s+'), '');
  if (hex.length.isOdd) {
    throw FormatException('Invalid input length, must be even', hex);
  }
  final result = Uint8List(hex.length ~/ 2);
  for (var i = 0; i < hex.length; i += 2) {
    final byteStr = hex.substring(i, i + 2);
    result[i ~/ 2] = int.parse(byteStr, radix: 16);
  }
  return result;
}

final messagePattern = RegExp(r'(\[[A-Z]\][0-9A-Fa-f\s]*?)(?=\[|\n)');

void main() {
  group('messagePattern regex', () {
    test('complete message terminated by newline matches', () {
      const buffer = '[M]0A0B0C\n';
      final matches = messagePattern.allMatches(buffer).toList();
      expect(matches, hasLength(1));
      expect(matches[0].group(1), equals('[M]0A0B0C'));
    });

    test('multiple messages separated by [ prefix match', () {
      const buffer = '[M]0A0B[N]0C0D\n';
      final matches = messagePattern.allMatches(buffer).toList();
      expect(matches, hasLength(2));
      expect(matches[0].group(1), equals('[M]0A0B'));
      expect(matches[1].group(1), equals('[N]0C0D'));
    });

    test('incomplete message at end of buffer does NOT match', () {
      const buffer = '[M]0A0';
      final matches = messagePattern.allMatches(buffer).toList();
      expect(
        matches,
        isEmpty,
        reason: 'Partial message with no terminator should not match',
      );
    });

    test('complete message followed by partial does not match the partial', () {
      const buffer = '[M]0A0B0C\n[N]0C0';
      final matches = messagePattern.allMatches(buffer).toList();
      expect(matches, hasLength(1));
      expect(matches[0].group(1), equals('[M]0A0B0C'));
    });

    test(
      'complete message followed by partial separated by [ does not match the partial',
      () {
        const buffer = '[M]0A0B0C[N]0C0';
        final matches = messagePattern.allMatches(buffer).toList();
        expect(matches, hasLength(1));
        expect(matches[0].group(1), equals('[M]0A0B0C'));
      },
    );
  });

  group('hexToBytes', () {
    test('parses valid even-length hex string', () {
      final result = hexToBytes('0A0B0C');
      expect(result, equals(Uint8List.fromList([0x0A, 0x0B, 0x0C])));
    });

    test('throws FormatException on odd-length hex string', () {
      expect(() => hexToBytes('0A0B0'), throwsA(isA<FormatException>()));
    });

    test('strips whitespace before parsing', () {
      final result = hexToBytes('0A 0B 0C');
      expect(result, equals(Uint8List.fromList([0x0A, 0x0B, 0x0C])));
    });
  });
}
