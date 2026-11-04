import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/services/serial/utils.dart';

void main() {
  group('isSensorBasket', () {
    test('detects a telemetry line with four finite fields', () {
      expect(
        isSensorBasket(['24 24.69 0.04 0.00 0.00 bat:4.28V chg:Y usb:Y 1 ms']),
        isTrue,
      );
    });

    test('detects a line with a non-finite field in any slot', () {
      for (final line in [
        '24 24.69 NaN 0.00 0.00 bat:4.28V chg:Y usb:Y 1 ms', // pressure
        '24 24.69 0.04 NaN 0.00 bat:4.28V chg:Y usb:Y 1 ms', // weight
        '24 24.69 0.04 0.00 NaN bat:4.28V chg:Y usb:Y 1 ms', // weightFlow
        '24 NaN 0.04 0.00 0.00 bat:4.28V chg:Y usb:Y 1 ms', // temperature
        '24 24.69 nan 0.04 0.00 bat:4.28V chg:Y usb:Y 1 ms', // lowercase
        '24 24.69 Infinity 0.04 0.00 bat:4.28V chg:Y usb:Y 1 ms',
        '24 24.69 -Infinity 0.04 0.00 bat:4.28V chg:Y usb:Y 1 ms',
      ]) {
        expect(isSensorBasket([line]), isTrue, reason: line);
      }
    });

    test('still needs a leading counter and four fields', () {
      for (final line in [
        '24 24.69 0.04 0.00 bat:4.28V chg:Y usb:Y 1 ms', // three fields
        'x 24.69 0.04 0.00 0.00', // no counter
        '24 24.69 -- 0.00 0.00', // display placeholder is not a value
      ]) {
        expect(isSensorBasket([line]), isFalse, reason: line);
      }
    });

    test('ignores unrelated serial traffic', () {
      expect(isSensorBasket(['<+M>', 'R 1234 5678']), isFalse);
    });
  });

  group('isDecentScale', () {
    test('claims a port that emits the text weight line', () {
      // ReaPrime checks isDecentScale before isSensorBasket, so a SensorBasket build
      // must not emit this line or it is detected as a scale instead.
      expect(isDecentScale(['1024 Weight: 0.00'], <Uint8List>[]), isTrue);
    });

    test('does not claim a telemetry line', () {
      expect(
        isDecentScale([
          '24 24.69 0.04 0.00 0.00 bat:4.28V chg:Y usb:Y 1 ms',
        ], <Uint8List>[]),
        isFalse,
      );
    });
  });
}
