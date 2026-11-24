import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/scale_controller.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/scale.dart';

import '../helpers/test_scale.dart';

void main() {
  late TestScale scale;
  late ScaleController controller;
  late DateTime clockTime;
  final snapshots = <WeightSnapshot>[];

  setUp(() async {
    scale = TestScale();
    controller = ScaleController();
    snapshots.clear();
    clockTime = DateTime(2026);
    await controller.connectToScale(scale);
    await controller.connectionState.firstWhere(
      (s) => s == ConnectionState.connected,
    );
    controller.weightSnapshot.listen(snapshots.add);
  });

  tearDown(() {
    controller.dispose();
    scale.dispose();
  });

  Future<void> sample(double weight) async {
    scale.emitSnapshot(
      ScaleSnapshot(timestamp: clockTime, weight: weight, batteryLevel: 90),
    );
    await Future<void>.delayed(Duration.zero);
    clockTime = clockTime.add(const Duration(milliseconds: 100));
  }

  Future<void> cupOnScaleUntilTareLands() async {
    for (var i = 0; i < 30; i++) {
      await sample(170.7);
    }
    await controller.tare();
    for (var i = 0; i < 10; i++) {
      await sample(170.7);
    }
  }

  test(
    'a tare that lands late leaves a flow transient without a reset',
    () async {
      await cupOnScaleUntilTareLands();
      snapshots.clear();
      for (var i = 0; i < 20; i++) {
        await sample(0.0);
      }

      expect(
        snapshots
            .map((s) => s.controlWeightFlow.abs())
            .reduce((a, b) => a > b ? a : b),
        greaterThan(50),
      );
    },
  );

  test(
    'resetFlowEstimation after the tare lands removes the transient',
    () async {
      await cupOnScaleUntilTareLands();
      await sample(0.0);
      controller.resetFlowEstimation();
      snapshots.clear();
      for (var i = 0; i < 40; i++) {
        await sample(0.0);
      }

      for (final s in snapshots) {
        expect(s.controlWeightFlow.abs(), lessThan(0.5));
        expect(s.weightFlow.abs(), lessThan(0.5));
      }
    },
  );

  test('flow is measured normally after a reset', () async {
    await cupOnScaleUntilTareLands();
    await sample(0.0);
    controller.resetFlowEstimation();
    for (var i = 0; i < 10; i++) {
      await sample(0.0);
    }
    snapshots.clear();
    for (var i = 1; i <= 30; i++) {
      await sample(i * 0.2);
    }

    expect(snapshots.last.controlWeightFlow, closeTo(2.0, 0.6));
  });
}
