import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/device/impl/bengle/mock_bengle.dart';
import 'package:reaprime/src/models/device/led_strip.dart';

void main() {
  group('MockBengle LED strip', () {
    test('initial state is all-off', () async {
      final bengle = MockBengle();
      final state = await bengle.getLedStripState();
      expect(state.frontStrip.sleeping, Color16.off);
      expect(state.frontStrip.awake, Color16.off);
      expect(state.backStrip.sleeping, Color16.off);
      expect(state.backStrip.awake, Color16.off);
      expect(state.frontSwitch.sleeping, Color16.off);
      expect(state.frontSwitch.awake, Color16.off);
    });

    test(
      'setLedStrip stores and getLedStripState returns the same state',
      () async {
        final bengle = MockBengle();
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
        expect(read, state);
      },
    );

    test('ledStripState stream emits set values', () async {
      final bengle = MockBengle();
      final emitted = <LedStripState>[];
      final sub = bengle.ledStripState.listen(emitted.add);
      addTearDown(sub.cancel);

      // Seeded initial value delivered on first microtask.
      await Future(() {});
      expect(emitted, hasLength(1));
      expect(emitted[0].frontStrip.sleeping, Color16.off);

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
      expect(emitted, hasLength(2));
      expect(emitted[1].frontStrip.sleeping, const Color16(128, 0, 0));
      expect(emitted[1].backStrip.awake, const Color16(0, 255, 0));
    });

    test('commitLedStrip snapshots cache, resetLedStrip restores it', () async {
      final bengle = MockBengle();
      expect(await bengle.getLedStripState(), const LedStripState());

      final state1 = LedStripState(
        frontStrip: ZoneLedState(
          sleeping: const Color16(65535, 0, 0),
          awake: Color16.off,
        ),
      );
      await bengle.setLedStrip(state1);
      await bengle.commitLedStrip();

      await bengle.setLedStrip(const LedStripState());

      await bengle.resetLedStrip();
      final after = await bengle.getLedStripState();
      expect(after, state1);
    });

    test(
      'resetLedStrip without commit is a no-op (restores all-off)',
      () async {
        final bengle = MockBengle();
        await bengle.setLedStrip(
          LedStripState(
            frontStrip: ZoneLedState(
              sleeping: const Color16(65535, 0, 0),
              awake: Color16.off,
            ),
          ),
        );
        await bengle.resetLedStrip();
        final after = await bengle.getLedStripState();
        expect(after, const LedStripState());
      },
    );
  });
}
