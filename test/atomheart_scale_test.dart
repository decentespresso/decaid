import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/device/impl/atomheart/atomheart_scale.dart';

void main() {
  group('AtomheartScale timer parsing', () {
    test('parseFrame extracts timer from BLE frame', () {
      final payload = [0xDC, 0x05, 0x00, 0x00, 0x88, 0x13, 0x00, 0x00];
      var xor = 0;
      for (var b in payload) {
        xor ^= b;
      }
      final data = [0x57, ...payload, xor & 0xFF];

      final snapshot = AtomheartScale.parseFrame(data);
      expect(snapshot, isNotNull);
      expect(snapshot!.weight, closeTo(1.5, 0.001));
      expect(snapshot.timerValue, equals(Duration(milliseconds: 5000)));
    });

    test('parseFrame returns null timerValue when timer is 0', () {
      final payload = [0xD0, 0x07, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00];
      var xor = 0;
      for (var b in payload) {
        xor ^= b;
      }
      final data = [0x57, ...payload, xor & 0xFF];

      final snapshot = AtomheartScale.parseFrame(data);
      expect(snapshot, isNotNull);
      expect(snapshot!.timerValue, isNull);
    });

    test('parseFrame returns null for short data', () {
      expect(AtomheartScale.parseFrame([0x57, 0x01]), isNull);
    });

    test('parseFrame returns null for wrong header', () {
      final payload = [0xDC, 0x05, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00];
      var xor = 0;
      for (var b in payload) {
        xor ^= b;
      }
      final data = [0x42, ...payload, xor & 0xFF];
      expect(AtomheartScale.parseFrame(data), isNull);
    });

    test('parseFrame returns null for invalid XOR checksum', () {
      final data = [0x57, 0xDC, 0x05, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xFF];
      expect(AtomheartScale.parseFrame(data), isNull);
    });
  });
}
