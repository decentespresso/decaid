import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/util/rot13.dart';

void main() {
  group('rot13', () {
    test('empty string returns empty', () {
      expect(rot13(''), '');
    });

    test('non-alpha characters pass through unchanged', () {
      expect(rot13('123_!@#'), '123_!@#');
    });

    test('encoding lower-case', () {
      expect(rot13('abc'), 'nop');
      expect(rot13('nop'), 'abc');
    });

    test('encoding upper-case', () {
      expect(rot13('ABC'), 'NOP');
      expect(rot13('NOP'), 'ABC');
    });

    test('encoding mixed case and symbols', () {
      expect(rot13('Hello World!'), 'Uryyb Jbeyq!');
    });

    test('self-inverse: double-encode returns original', () {
      expect(rot13(rot13('Hello World!')), 'Hello World!');
    });

    test('github_pat token round-trip', () {
      const token =
          'github_pat_11ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz';
      final encoded = rot13(token);
      expect(encoded, isNot(token));
      expect(rot13(encoded), token);
    });

    test('string without alpha chars is unchanged', () {
      expect(rot13('12345'), '12345');
      expect(rot13('_-.@'), '_-.@');
    });
  });
}
