import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/device/impl/bengle/mock_bengle.dart';
import 'package:reaprime/src/models/device/led_strip.dart';

void main() {
  group('MockBengle LED strip', () {
    test('state is null before connection (no fabricated black)', () async {
      final bengle = MockBengle();
      expect(await bengle.getLedStripState(), isNull);
    });

    test('onConnect hydrates a deterministic non-black palette', () async {
      final bengle = MockBengle();
      await bengle.onConnect();
      final state = await bengle.getLedStripState();
      expect(state, isNotNull);
      expect(state!.frontStrip.awake, const Color16(0xFF00, 0xF000, 0x8000));
      expect(state.frontStrip.sleeping, const Color16(0x3000, 0x2000, 0x1000));
    });

    test(
      'setLedStrip stores and getLedStripState returns the same state',
      () async {
        final bengle = MockBengle();
        await bengle.onConnect();
        final state = LedStripState(
          frontStrip: ZoneLedState(
            sleeping: const Color16(65535, 32768, 0),
            awake: const Color16(0, 65535, 32768),
          ),
          backStrip: ZoneLedState(
            sleeping: const Color16(10, 20, 30),
            awake: Color16.off,
          ),
        );
        await bengle.setLedStrip(state);
        final read = await bengle.getLedStripState();
        expect(read!.frontStrip.sleeping, const Color16(65280, 32768, 0));
        expect(read.frontStrip.awake, const Color16(0, 65280, 32768));
        expect(read.backStrip.sleeping, Color16.off);
        expect(read.backStrip.awake, Color16.off);
        expect(read.frontSwitch, read.frontStrip);
      },
    );

    test('ledStripState stream emits set values', () async {
      final bengle = MockBengle();
      final emitted = <LedStripState?>[];
      final sub = bengle.ledStripState.listen(emitted.add);
      addTearDown(sub.cancel);

      await bengle.onConnect();
      expect(emitted, isNotEmpty);
      final hydrated = emitted.last;
      expect(hydrated!.frontStrip.awake, isNot(Color16.off));

      await bengle.setLedStrip(
        const LedStripState(
          frontStrip: ZoneLedState(
            sleeping: Color16(128, 0, 0),
            awake: Color16.off,
          ),
          backStrip: ZoneLedState(
            sleeping: Color16.off,
            awake: Color16(0, 255, 0),
          ),
        ),
      );
      expect(emitted.last!.frontStrip.sleeping, Color16.off);
      expect(emitted.last!.backStrip.awake, Color16.off);
    });

    test(
      'commitLedStrip is a no-op and resetLedStrip keeps the state',
      () async {
        final bengle = MockBengle();
        await bengle.onConnect();

        final state1 = LedStripState(
          frontStrip: ZoneLedState(
            sleeping: const Color16(65535, 0, 0),
            awake: Color16.off,
          ),
        );
        await bengle.setLedStrip(state1);
        await bengle.commitLedStrip();

        final after = await bengle.resetLedStrip();
        expect(
          after!.frontStrip,
          ZoneLedState(
            sleeping: const Color16(65280, 0, 0),
            awake: Color16.off,
          ),
        );
        expect(after.frontSwitch.awake, const Color16(0xFF00, 0xF000, 0xC800));
      },
    );
  });
}
