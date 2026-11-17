import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/device/impl/bengle/bengle_mmr.dart';

void main() {
  group('Bengle LED registers', () {
    test('the live pair carries the firmware addresses', () {
      expect(BengleMmr.frontLedColor.address, 0x00803890);
      expect(BengleMmr.rearLedColor.address, 0x00803894);
    });

    test('the stored palette is four different registers', () {
      expect(BengleMmr.frontLedAwake.address, 0x00803898);
      expect(BengleMmr.rearLedAwake.address, 0x0080389C);
      expect(BengleMmr.frontLedSleep.address, 0x008038A0);
      expect(BengleMmr.rearLedSleep.address, 0x008038A4);
    });

    test('no register is shared between showing a colour and storing one', () {
      final live = {
        BengleMmr.frontLedColor.address,
        BengleMmr.rearLedColor.address,
      };
      final stored = {
        BengleMmr.frontLedAwake.address,
        BengleMmr.rearLedAwake.address,
        BengleMmr.frontLedSleep.address,
        BengleMmr.rearLedSleep.address,
      };
      expect(live.intersection(stored), isEmpty);
      expect(live.length + stored.length, 6);
    });
  });
}
