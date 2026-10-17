import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/device/impl/bengle/bengle_mmr.dart';

/// The firmware keeps the LIVE strip colour apart from the stored palette.
///
/// `F_LEDStripColor` lights the strip the moment `FrontLEDColor` / `RearLEDColor`
/// are written, and `applyLEDsForGivenState` recomputes them from the stored
/// awake/sleep pair at the next sleep or wake transition. `F_LEDStoreColor`, on the
/// stored registers, applies a colour only when the machine is already in the state
/// that colour belongs to — which is why an asleep colour cannot be shown to someone
/// editing it on an awake machine without the live pair.
///
/// These are the firmware's own addresses. A preview written to a stored register
/// would decide the palette instead of showing a colour, so the two must not be
/// confused.
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
