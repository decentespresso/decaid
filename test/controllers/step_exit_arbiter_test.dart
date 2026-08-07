import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/step_exit_arbiter.dart';
import 'package:reaprime/src/models/data/profile.dart';

void main() {
  late StepExitArbiter arbiter;

  setUp(() {
    arbiter = StepExitArbiter();
  });

  // ---------------------------------------------------------------
  // ---------------------------------------------------------------

  group('pressure over exit', () {
    const exit = StepExitCondition(
      type: ExitType.pressure,
      condition: ExitCondition.over,
      value: 6.0,
    );

    test('far from threshold fires immediately', () {
      final verdict = arbiter.evaluate(
        profileFrame: 0,
        exit: exit,
        currentPressure: 2.0,
        currentFlow: 3.0,
      );
      expect(verdict, StepExitVerdict.fire);
    });

    test('near threshold and trending defers', () {
      final v1 = arbiter.evaluate(
        profileFrame: 0,
        exit: exit,
        currentPressure: 5.0,
        currentFlow: 3.0,
      );
      // First sample assumes trending → defer
      expect(v1, StepExitVerdict.defer);

      // Second sample still trending up
      final v2 = arbiter.evaluate(
        profileFrame: 0,
        exit: exit,
        currentPressure: 5.3,
        currentFlow: 3.0,
      );
      expect(v2, StepExitVerdict.defer);
    });

    test('near threshold trending hits max deferral then fires', () {
      for (var i = 0; i < StepExitArbiter.maxDeferralFrames - 1; i++) {
        final v = arbiter.evaluate(
          profileFrame: 0,
          exit: exit,
          currentPressure: 5.0 + i * 0.2,
          currentFlow: 3.0,
        );
        expect(v, StepExitVerdict.defer, reason: 'frame $i should defer');
      }

      final vFinal = arbiter.evaluate(
        profileFrame: 0,
        exit: exit,
        currentPressure: 5.6,
        currentFlow: 3.0,
      );
      expect(vFinal, StepExitVerdict.fire);
    });

    test('near threshold not trending fires on second frame', () {
      // First sample: assumes trending → defer
      final v1 = arbiter.evaluate(
        profileFrame: 0,
        exit: exit,
        currentPressure: 5.0,
        currentFlow: 3.0,
      );
      expect(v1, StepExitVerdict.defer);

      // Second sample: pressure dropped → not trending toward "over"
      final v2 = arbiter.evaluate(
        profileFrame: 0,
        exit: exit,
        currentPressure: 4.8,
        currentFlow: 3.0,
      );
      expect(v2, StepExitVerdict.fire);
    });

    test('sensor past threshold defers then fires at max', () {
      final v1 = arbiter.evaluate(
        profileFrame: 0,
        exit: exit,
        currentPressure: 7.0,
        currentFlow: 3.0,
      );
      expect(v1, StepExitVerdict.defer);

      final v2 = arbiter.evaluate(
        profileFrame: 0,
        exit: exit,
        currentPressure: 7.0,
        currentFlow: 3.0,
      );
      expect(v2, StepExitVerdict.defer);

      // Third frame hits maxDeferralFrames
      final v3 = arbiter.evaluate(
        profileFrame: 0,
        exit: exit,
        currentPressure: 7.0,
        currentFlow: 3.0,
      );
      expect(v3, StepExitVerdict.fire);
    });
  });

  // ---------------------------------------------------------------
  // ---------------------------------------------------------------

  group('flow under exit', () {
    const exit = StepExitCondition(
      type: ExitType.flow,
      condition: ExitCondition.under,
      value: 2.0,
    );

    test('far from threshold fires immediately', () {
      final verdict = arbiter.evaluate(
        profileFrame: 0,
        exit: exit,
        currentPressure: 5.0,
        currentFlow: 3.5,
      );
      expect(verdict, StepExitVerdict.fire);
    });

    test('near threshold defers', () {
      final verdict = arbiter.evaluate(
        profileFrame: 0,
        exit: exit,
        currentPressure: 5.0,
        currentFlow: 2.5,
      );
      expect(verdict, StepExitVerdict.defer);
    });

    test('near threshold trending down defers, not trending fires', () {
      // First: flow 2.5 → defer (assumes trending)
      arbiter.evaluate(
        profileFrame: 0,
        exit: exit,
        currentPressure: 5.0,
        currentFlow: 2.5,
      );

      // Second: flow 2.3 (dropping toward "under 2.0") → trending → defer
      final v2 = arbiter.evaluate(
        profileFrame: 0,
        exit: exit,
        currentPressure: 5.0,
        currentFlow: 2.3,
      );
      expect(v2, StepExitVerdict.defer);

      // Third: max deferral → fire
      final v3 = arbiter.evaluate(
        profileFrame: 0,
        exit: exit,
        currentPressure: 5.0,
        currentFlow: 2.1,
      );
      expect(v3, StepExitVerdict.fire);
    });

    test('near threshold flow rising fires on second frame', () {
      // First: defer (assumes trending)
      arbiter.evaluate(
        profileFrame: 0,
        exit: exit,
        currentPressure: 5.0,
        currentFlow: 2.5,
      );

      // Second: flow 2.8 — rising, not trending toward "under"
      final v2 = arbiter.evaluate(
        profileFrame: 0,
        exit: exit,
        currentPressure: 5.0,
        currentFlow: 2.8,
      );
      expect(v2, StepExitVerdict.fire);
    });
  });

  // ---------------------------------------------------------------
  // ---------------------------------------------------------------

  group('edge cases', () {
    test('exit value <= 0 fires immediately', () {
      const exit = StepExitCondition(
        type: ExitType.pressure,
        condition: ExitCondition.over,
        value: 0.0,
      );

      final verdict = arbiter.evaluate(
        profileFrame: 0,
        exit: exit,
        currentPressure: 1.0,
        currentFlow: 3.0,
      );
      expect(verdict, StepExitVerdict.fire);
    });

    test('negative exit value fires immediately', () {
      const exit = StepExitCondition(
        type: ExitType.flow,
        condition: ExitCondition.under,
        value: -1.0,
      );

      final verdict = arbiter.evaluate(
        profileFrame: 0,
        exit: exit,
        currentPressure: 5.0,
        currentFlow: 2.0,
      );
      expect(verdict, StepExitVerdict.fire);
    });

    test('onFrameAdvanced clears stale deferral state', () {
      const exit = StepExitCondition(
        type: ExitType.pressure,
        condition: ExitCondition.over,
        value: 6.0,
      );

      arbiter.evaluate(
        profileFrame: 0,
        exit: exit,
        currentPressure: 5.0,
        currentFlow: 3.0,
      );

      // Firmware advances to frame 1
      arbiter.onFrameAdvanced(1);

      // Evaluate frame 0 again — fresh state, first sample assumes trending
      final v = arbiter.evaluate(
        profileFrame: 0,
        exit: exit,
        currentPressure: 5.0,
        currentFlow: 3.0,
      );
      expect(v, StepExitVerdict.defer, reason: 'deferral state was cleared');
    });

    test('reset clears all deferral state', () {
      const exit = StepExitCondition(
        type: ExitType.pressure,
        condition: ExitCondition.over,
        value: 6.0,
      );

      arbiter.evaluate(
        profileFrame: 0,
        exit: exit,
        currentPressure: 5.0,
        currentFlow: 3.0,
      );
      arbiter.evaluate(
        profileFrame: 0,
        exit: exit,
        currentPressure: 5.2,
        currentFlow: 3.0,
      );

      arbiter.reset();

      // Same frame, same readings — should start fresh (first sample)
      final v = arbiter.evaluate(
        profileFrame: 0,
        exit: exit,
        currentPressure: 5.0,
        currentFlow: 3.0,
      );
      expect(v, StepExitVerdict.defer, reason: 'reset clears frame count');
    });

    test('independent deferral per frame', () {
      const exit0 = StepExitCondition(
        type: ExitType.pressure,
        condition: ExitCondition.over,
        value: 6.0,
      );
      const exit1 = StepExitCondition(
        type: ExitType.pressure,
        condition: ExitCondition.over,
        value: 8.0,
      );

      final v0 = arbiter.evaluate(
        profileFrame: 0,
        exit: exit0,
        currentPressure: 5.0,
        currentFlow: 3.0,
      );
      expect(v0, StepExitVerdict.defer);

      final v1 = arbiter.evaluate(
        profileFrame: 1,
        exit: exit1,
        currentPressure: 2.0,
        currentFlow: 3.0,
      );
      expect(v1, StepExitVerdict.fire);
    });

    test('pressure exactly at proximity boundary defers', () {
      const exit = StepExitCondition(
        type: ExitType.pressure,
        condition: ExitCondition.over,
        value: 6.0,
      );

      // proximity = 6.0 * 0.20 = 1.2 bar
      // distance = 6.0 - 4.8 = 1.2, which is NOT > 1.2 → near
      final vAt = arbiter.evaluate(
        profileFrame: 0,
        exit: exit,
        currentPressure: 4.8,
        currentFlow: 3.0,
      );
      expect(
        vAt,
        StepExitVerdict.defer,
        reason: 'distance == proximity is "near", not "far"',
      );

      arbiter.reset();
      final vBeyond = arbiter.evaluate(
        profileFrame: 0,
        exit: exit,
        currentPressure: 4.7,
        currentFlow: 3.0,
      );
      expect(vBeyond, StepExitVerdict.fire);
    });

    test('trend requires all pairwise comparisons to point toward exit', () {
      const exit = StepExitCondition(
        type: ExitType.pressure,
        condition: ExitCondition.over,
        value: 9.0,
      );

      // proximity = 9.0 * 0.20 = 1.8 bar.
      // Feed a zigzag near threshold: up, then down.
      // Frame 0: pressure 7.5 → distance 1.5 < 1.8, near, first → defer
      final v1 = arbiter.evaluate(
        profileFrame: 0,
        exit: exit,
        currentPressure: 7.5,
        currentFlow: 3.0,
      );
      expect(v1, StepExitVerdict.defer);

      final v2 = arbiter.evaluate(
        profileFrame: 0,
        exit: exit,
        currentPressure: 7.8,
        currentFlow: 3.0,
      );
      expect(v2, StepExitVerdict.defer);

      // Frame 0: pressure 7.6 (down from 7.8).
      // With 3 readings [7.5, 7.8, 7.6]: 7.8>7.5 ✓ but 7.6>7.8 ✗
      // All comparisons must agree → not trending → fire.
      // (maxDeferralFrames=3, so frameCount=3 ≥ max → max triggers first.
      //  On read: fires because max reached, not because trend flipped.)
      final v3 = arbiter.evaluate(
        profileFrame: 0,
        exit: exit,
        currentPressure: 7.6,
        currentFlow: 3.0,
      );
      expect(
        v3,
        StepExitVerdict.fire,
        reason: 'max deferral reached before trend check on frame 3',
      );
    });
  });

  // ---------------------------------------------------------------
  // Tight-margin — realistic DE1 firing behavior
  // DE1 firmware is precise: when exit is {pressure over 5 bar},
  // the machine crosses ~5.02 bar and advances the frame within
  // milliseconds. The tablet snapshot sees pressure barely past or
  // barely below the threshold. The arbiter's primary job is handling
  // these sub-0.1 bar / sub-0.2 ml/s margins, not the wide gaps the
  // logic-coverage tests above use.
  // ---------------------------------------------------------------

  group('tight-margin (real DE1 firing)', () {
    test('barely past pressure threshold defers', () {
      // Exit over 5.0 bar. Snapshot shows pressure 5.02 →
      // firmware very likely already advanced. Defer.
      const exit = StepExitCondition(
        type: ExitType.pressure,
        condition: ExitCondition.over,
        value: 5.0,
      );

      final v = arbiter.evaluate(
        profileFrame: 0,
        exit: exit,
        currentPressure: 5.02,
        currentFlow: 3.0,
      );
      expect(
        v,
        StepExitVerdict.defer,
        reason:
            'Pressure 0.02 bar past threshold — firmware likely '
            'already advanced. Defer to avoid double-skip.',
      );
    });

    test('barely past pressure, firmware advances, race avoided', () {
      // The primary race scenario: pressure crosses 5.0, firmware
      // advances frame 0→1. Tablet snapshot still shows frame 0
      // with pressure 5.02 and weight exit met. Arbiter defers.
      // Next snapshot: firmware already on frame 1.
      const exit = StepExitCondition(
        type: ExitType.pressure,
        condition: ExitCondition.over,
        value: 5.0,
      );

      final v0 = arbiter.evaluate(
        profileFrame: 0,
        exit: exit,
        currentPressure: 5.02,
        currentFlow: 3.0,
      );
      expect(v0, StepExitVerdict.defer);

      // Firmware advances to frame 1 (it handled the exit).
      arbiter.onFrameAdvanced(1);

      final v1 = arbiter.evaluate(
        profileFrame: 1,
        exit: const StepExitCondition(
          type: ExitType.pressure,
          condition: ExitCondition.over,
          value: 9.0,
        ),
        currentPressure: 5.1,
        currentFlow: 3.0,
      );
      expect(
        v1,
        StepExitVerdict.fire,
        reason: 'Frame 0 race avoided; frame 1 independent.',
      );
    });

    test('barely past pressure, no firmware advance, max deferral fires', () {
      // Firmware DIDN'T fire its exit (unlikely but possible if
      // communication glitch). After 3 frames of being past threshold,
      // tablet fires skipStep so the shot doesn't stall.
      const exit = StepExitCondition(
        type: ExitType.pressure,
        condition: ExitCondition.over,
        value: 5.0,
      );

      for (var i = 0; i < StepExitArbiter.maxDeferralFrames - 1; i++) {
        final v = arbiter.evaluate(
          profileFrame: 0,
          exit: exit,
          currentPressure: 5.02,
          currentFlow: 3.0,
        );
        expect(v, StepExitVerdict.defer, reason: 'frame $i: still past');
      }

      final vFire = arbiter.evaluate(
        profileFrame: 0,
        exit: exit,
        currentPressure: 5.02,
        currentFlow: 3.0,
      );
      expect(
        vFire,
        StepExitVerdict.fire,
        reason: 'Max deferral reached — fire as backstop.',
      );
    });

    // -- pressure over, near but not yet past -----------------------

    test('near pressure threshold, tiny margin, trending defers', () {
      // Exit over 5.0 bar. Pressure at 4.96, inching toward 5.0.
      // Firmware will fire within ~100ms. Defer.
      const exit = StepExitCondition(
        type: ExitType.pressure,
        condition: ExitCondition.over,
        value: 5.0,
      );

      final v1 = arbiter.evaluate(
        profileFrame: 0,
        exit: exit,
        currentPressure: 4.96,
        currentFlow: 3.0,
      );
      expect(
        v1,
        StepExitVerdict.defer,
        reason: '4.96 at exit 5.0 → distance 0.04 < 1.0, first → defer',
      );

      final v2 = arbiter.evaluate(
        profileFrame: 0,
        exit: exit,
        currentPressure: 4.98,
        currentFlow: 3.0,
      );
      expect(
        v2,
        StepExitVerdict.defer,
        reason: '4.96→4.98 trending toward 5.0 → defer',
      );
    });

    test('near pressure threshold, tiny margin, not trending fires', () {
      // Pressure was near threshold then drifted away.
      // Firmware unlikely to fire. Fire skipStep.
      const exit = StepExitCondition(
        type: ExitType.pressure,
        condition: ExitCondition.over,
        value: 5.0,
      );

      arbiter.evaluate(
        profileFrame: 0,
        exit: exit,
        currentPressure: 4.96,
        currentFlow: 3.0,
      );

      final v2 = arbiter.evaluate(
        profileFrame: 0,
        exit: exit,
        currentPressure: 4.93,
        currentFlow: 3.0,
      );
      expect(
        v2,
        StepExitVerdict.fire,
        reason: '4.96→4.93 away from exit 5.0 → fire',
      );
    });

    test('barely past flow threshold defers', () {
      // Exit under 2.0 ml/s. Snapshot shows flow 1.98 →
      // barely below threshold. Firmware likely already advanced.
      const exit = StepExitCondition(
        type: ExitType.flow,
        condition: ExitCondition.under,
        value: 2.0,
      );

      final v = arbiter.evaluate(
        profileFrame: 0,
        exit: exit,
        currentPressure: 5.0,
        currentFlow: 1.98,
      );
      expect(
        v,
        StepExitVerdict.defer,
        reason:
            'Flow 0.02 ml/s past under-2.0 — firmware likely '
            'already advanced.',
      );
    });

    test('near flow threshold, tiny margin defers', () {
      const exit = StepExitCondition(
        type: ExitType.flow,
        condition: ExitCondition.under,
        value: 2.0,
      );

      final v = arbiter.evaluate(
        profileFrame: 0,
        exit: exit,
        currentPressure: 5.0,
        currentFlow: 2.02,
      );
      expect(
        v,
        StepExitVerdict.defer,
        reason: 'Flow 0.02 above under-2.0 → near, first → defer',
      );
    });
  });
}
