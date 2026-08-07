import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/hot_water_stop.dart';
import 'package:reaprime/src/models/device/machine.dart';

void main() {
  HotWaterStopState armed({
    double target = 30,
    double configuredFlow = 2.0,
    double lookahead = 0.3,
    bool activeSeen = false,
    bool stopRequested = false,
  }) => HotWaterStopState(
    targetWeight: target,
    configuredFlow: configuredFlow,
    lookaheadSeconds: lookahead,
    activeSeen: activeSeen,
    stopRequested: stopRequested,
  );

  HotWaterStopInput input({
    MachineState? machineState = MachineState.hotWater,
    Duration sinceArmed = const Duration(seconds: 1),
    bool tareSettled = true,
    bool freshScale = true,
    double? weight = 0,
    double? weightFlow = 0,
  }) => HotWaterStopInput(
    machineState: machineState,
    sinceArmed: sinceArmed,
    tareSettled: tareSettled,
    freshScale: freshScale,
    weight: weight,
    weightFlow: weightFlow,
  );

  group('nextHotWaterStop', () {
    test('marks activeSeen once the machine is seen in hotWater', () {
      final d = nextHotWaterStop(armed(), input(weight: 5));
      expect(d.action, HotWaterStopAction.wait);
      expect(d.state!.activeSeen, isTrue);
    });

    test('waits (does not clear) before hotWater is seen, within timeout', () {
      final d = nextHotWaterStop(
        armed(),
        input(
          machineState: MachineState.heating,
          sinceArmed: const Duration(seconds: 2),
        ),
      );
      expect(d.action, HotWaterStopAction.wait);
      expect(d.state!.activeSeen, isFalse);
    });

    test('clears if hotWater is never seen within the arm timeout', () {
      final d = nextHotWaterStop(
        armed(),
        input(
          machineState: MachineState.idle,
          sinceArmed: const Duration(seconds: 11),
        ),
      );
      expect(d.action, HotWaterStopAction.clear);
      expect(d.state, isNull);
    });

    test('clears once the machine leaves hotWater after being active', () {
      final d = nextHotWaterStop(
        armed(activeSeen: true),
        input(machineState: MachineState.idle),
      );
      expect(d.action, HotWaterStopAction.clear);
    });

    test('waits while the tare has not settled, even above target', () {
      final d = nextHotWaterStop(
        armed(activeSeen: true),
        input(weight: 50, tareSettled: false),
      );
      expect(d.action, HotWaterStopAction.wait);
    });

    test('waits while the scale is not fresh', () {
      final d = nextHotWaterStop(
        armed(activeSeen: true),
        input(weight: 50, freshScale: false),
      );
      expect(d.action, HotWaterStopAction.wait);
    });

    test('waits while projected weight is below target', () {
      final d = nextHotWaterStop(
        armed(activeSeen: true, target: 30),
        input(weight: 20, weightFlow: 2),
      );
      expect(d.action, HotWaterStopAction.wait);
    });

    test('stops when actual weight reaches target', () {
      final d = nextHotWaterStop(
        armed(activeSeen: true, target: 30),
        input(weight: 30, weightFlow: 0),
      );
      expect(d.action, HotWaterStopAction.stop);
      expect(d.state!.stopRequested, isTrue);
      expect(d.weight, 30);
    });

    test(
      'stops early via flow lookahead before actual weight reaches target',
      () {
        final d = nextHotWaterStop(
          armed(activeSeen: true, target: 30, lookahead: 0.3),
          input(weight: 29, weightFlow: 4),
        );
        expect(d.action, HotWaterStopAction.stop);
        expect(d.projectedWeight, closeTo(30.2, 1e-9));
      },
    );

    test('falls back to configured flow when scale flow is not positive', () {
      final d = nextHotWaterStop(
        armed(
          activeSeen: true,
          target: 30,
          configuredFlow: 2.0,
          lookahead: 0.3,
        ),
        input(weight: 29.9, weightFlow: 0),
      );
      expect(d.action, HotWaterStopAction.stop);
    });

    test('does not stop twice once a stop is already requested', () {
      final d = nextHotWaterStop(
        armed(activeSeen: true, target: 30, stopRequested: true),
        input(weight: 50, weightFlow: 5),
      );
      expect(d.action, HotWaterStopAction.wait);
    });

    test('treats null weight as zero', () {
      final d = nextHotWaterStop(
        armed(activeSeen: true, target: 30, configuredFlow: 0),
        input(weight: null, weightFlow: null),
      );
      expect(d.action, HotWaterStopAction.wait);
    });
  });
}
