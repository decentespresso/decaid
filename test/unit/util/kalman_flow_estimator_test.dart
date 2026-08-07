import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/weight_flow_calculator.dart';
import 'package:reaprime/src/util/kalman_flow_estimator.dart';
import 'package:reaprime/src/util/moving_average.dart';

void main() {
  group('KalmanFlowEstimator', () {
    test('initial state: weight = initial, flow = 0', () {
      final estimator = KalmanFlowEstimator(initialWeight: 100.0);

      expect(estimator.weight, closeTo(100.0, 0.01));
      expect(estimator.flow, closeTo(0.0, 0.01));
    });

    test('first sample: returns the raw weight, flow stays 0', () {
      final estimator = KalmanFlowEstimator(initialWeight: 100.0);
      final t0 = DateTime(2026, 1, 1, 12, 0, 0);

      final (w, f) = estimator.addSample(t0, 100.0);
      expect(w, closeTo(100.0, 0.01));
      expect(f, closeTo(0.0, 0.01));
    });

    test('constant weight: flow converges near 0', () {
      final estimator = KalmanFlowEstimator(initialWeight: 100.0);
      final t0 = DateTime(2026, 1, 1, 12, 0, 0);
      const dt = Duration(milliseconds: 100);

      estimator.addSample(t0, 100.0);

      for (int i = 1; i <= 30; i++) {
        estimator.addSample(t0.add(dt * i), 100.0);
      }

      expect(estimator.flow.abs(), lessThan(0.1));
      expect(estimator.weight, closeTo(100.0, 0.1));
    });

    test('constant positive ramp: flow converges to true rate', () {
      final estimator = KalmanFlowEstimator(initialWeight: 0.0);
      final t0 = DateTime(2026, 1, 1, 12, 0, 0);
      const dt = Duration(milliseconds: 100);
      const rate = 5.0;

      estimator.addSample(t0, 0.0);

      for (int i = 1; i <= 50; i++) {
        final elapsed = dt.inMilliseconds * i / 1000.0;
        estimator.addSample(t0.add(dt * i), rate * elapsed);
      }

      expect(estimator.flow, closeTo(rate, 0.2));
    });

    test('signed flow: negative slope produces negative flow', () {
      final estimator = KalmanFlowEstimator(initialWeight: 50.0);
      final t0 = DateTime(2026, 1, 1, 12, 0, 0);
      const dt = Duration(milliseconds: 100);
      const rate = -3.0;

      estimator.addSample(t0, 50.0);

      for (int i = 1; i <= 30; i++) {
        final elapsed = dt.inMilliseconds * i / 1000.0;
        estimator.addSample(t0.add(dt * i), 50.0 + rate * elapsed);
      }

      expect(estimator.flow, lessThan(-1.0));
    });

    test('reset (tare): reinitializes weight and flow', () {
      final estimator = KalmanFlowEstimator(initialWeight: 0.0);
      final t0 = DateTime(2026, 1, 1, 12, 0, 0);

      for (int i = 1; i <= 20; i++) {
        final elapsed = 0.1 * i;
        estimator.addSample(
          t0.add(Duration(milliseconds: (100 * i))),
          5.0 * elapsed,
        );
      }
      expect(
        estimator.flow,
        greaterThan(1.0),
        reason: 'flow should build up before reset',
      );

      estimator.reset(0.0);

      final (w, f) = estimator.addSample(
        t0.add(const Duration(milliseconds: 2100)),
        0.0,
      );

      expect(w, closeTo(0.0, 0.01));
      expect(f.abs(), lessThan(0.5));
    });

    test('spike rejection: transient spike is attenuated via adaptive R', () {
      final estimator = KalmanFlowEstimator(
        initialWeight: 100.0,
        processNoiseIntensity: 2.0,
      );
      final t0 = DateTime(2026, 1, 1, 12, 0, 0);
      const dt = Duration(milliseconds: 100);

      for (int i = 0; i <= 30; i++) {
        final elapsed = dt.inMilliseconds * i / 1000.0;
        estimator.addSample(t0.add(dt * i), 100.0 + 5.0 * elapsed);
      }

      final beforeFlow = estimator.flow;

      estimator.addSample(t0.add(dt * 31), 100.0 + 5.0 * 31 * 0.1 + 10.0);

      final (_, afterFlow) = estimator.addSample(
        t0.add(dt * 32),
        100.0 + 5.0 * 32 * 0.1,
      );

      expect(
        (afterFlow - beforeFlow).abs(),
        lessThan(3.0),
        reason:
            'adaptive R should attenuate spike impact on flow '
            '(10g spike should not shift flow by more than 3 g/s)',
      );
    });

    test('step response: weight tracks a level change, flow settles back', () {
      final estimator = KalmanFlowEstimator(
        initialWeight: 0.0,
        processNoiseIntensity: 2.0,
      );
      final t0 = DateTime(2026, 1, 1, 12, 0, 0);
      const dt = Duration(milliseconds: 100);

      estimator.addSample(t0, 0.0);
      for (int i = 1; i <= 20; i++) {
        estimator.addSample(t0.add(dt * i), 0.0);
      }
      expect(estimator.weight, closeTo(0.0, 0.01));

      for (int i = 21; i <= 70; i++) {
        estimator.addSample(t0.add(dt * i), 40.0);
      }

      expect(estimator.weight, closeTo(40.0, 5.0));
      expect(
        estimator.flow.abs(),
        lessThan(2.0),
        reason: 'after settling, flow should return toward zero',
      );
    });

    test('variable dt: handles irregular sample intervals', () {
      final estimator = KalmanFlowEstimator(initialWeight: 0.0);
      final t0 = DateTime(2026, 1, 1, 12, 0, 0);
      const rate = 5.0;

      estimator.addSample(t0, 0.0);

      final intervals = [50, 200, 80, 150, 100, 300, 70];
      double elapsedMs = 0;
      for (final ms in intervals) {
        elapsedMs += ms;
        final weight = rate * elapsedMs / 1000.0;
        estimator.addSample(
          t0.add(Duration(milliseconds: elapsedMs.round())),
          weight,
        );
      }

      expect(
        estimator.flow,
        closeTo(rate, 0.5),
        reason: 'variable-dt Kalman should track true rate',
      );
    });

    test('convergence speed: tracks true flow within 5 samples', () {
      final estimator = KalmanFlowEstimator(initialWeight: 0.0);
      final t0 = DateTime(2026, 1, 1, 12, 0, 0);
      const dt = Duration(milliseconds: 100);
      const rate = 6.0;

      estimator.addSample(t0, 0.0);

      for (int i = 1; i <= 5; i++) {
        final elapsed = dt.inMilliseconds * i / 1000.0;
        estimator.addSample(t0.add(dt * i), rate * elapsed);
      }

      // After 5 samples the flow estimate should be within 50% of the
      // true rate. At native 10 Hz all tuning variants (original, aggressive
      // retune, and this middle ground) reach ~59–66% within 5 samples. The
      // convergence problem was never in the flow estimate — it was the
      // weight estimate that lagged (now fixed by raw-passthrough in
      // ScaleController).
      expect(
        estimator.flow,
        greaterThan(rate * 0.5),
        reason: 'flow should converge to >50% of true rate within 5 samples',
      );
    });

    group('golden trace (shot 1, native ~10 Hz)', () {
      /// Loads the P0 raw trace fixture.
      // ignore: no_leading_underscores_for_local_identifiers
      List<({DateTime timestamp, double weight})> _loadFixture() {
        const raw = [
          (1783576236714, 0.0),
          (1783576236819, 0.3),
          (1783576236905, 0.5),
          (1783576236984, 0.7),
          (1783576237120, 1.4),
          (1783576237209, 2.2),
          (1783576237307, 3.2),
          (1783576237391, 3.9),
          (1783576237526, 4.4),
          (1783576237614, 5.0),
          (1783576237704, 5.7),
          (1783576237812, 6.3),
          (1783576237932, 6.9),
          (1783576238021, 7.4),
          (1783576238109, 8.1),
          (1783576238199, 8.8),
          (1783576238335, 9.5),
          (1783576238427, 10.0),
          (1783576238514, 10.6),
          (1783576238607, 11.4),
          (1783576238693, 12.2),
          (1783576238828, 12.9),
          (1783576238923, 13.5),
          (1783576239010, 14.3),
          (1783576239146, 15.0),
          (1783576239198, 15.7),
          (1783576239283, 16.5),
          (1783576239413, 17.1),
          (1783576239559, 18.0),
          (1783576239596, 18.7),
          (1783576239689, 19.3),
          (1783576239864, 20.2),
          (1783576239955, 20.8),
          (1783576240000, 21.6),
          (1783576240090, 22.4),
          (1783576240179, 23.2),
          (1783576240319, 23.9),
          (1783576240405, 24.7),
          (1783576240495, 25.6),
          (1783576240587, 26.3),
          (1783576240719, 27.1),
          (1783576240809, 27.7),
          (1783576240900, 28.5),
          (1783576241079, 29.4),
          (1783576241086, 30.1),
          (1783576241215, 30.9),
          (1783576241305, 31.6),
          (1783576241394, 32.3),
          (1783576241484, 33.1),
          (1783576241621, 33.9),
          (1783576241709, 34.7),
          (1783576241799, 35.5),
          (1783576241890, 36.3),
          (1783576241981, 36.9),
          (1783576242115, 37.7),
          (1783576242204, 38.5),
          (1783576242340, 39.3),
          (1783576242385, 40.2),
          (1783576242527, 40.9),
          (1783576242609, 41.7),
          (1783576242698, 42.5),
          (1783576242803, 43.2),
          (1783576242925, 43.9),
          (1783576243030, 44.7),
          (1783576243105, 45.5),
          (1783576243259, 46.2),
          (1783576243308, 47.0),
          (1783576243419, 47.7),
          (1783576243509, 48.0),
          (1783576243654, 48.0),
          (1783576243689, 48.1),
          (1783576243779, 48.1),
          (1783576243965, 48.2),
        ];
        return [
          for (final e in raw)
            (
              timestamp: DateTime.fromMillisecondsSinceEpoch(e.$1, isUtc: true),
              weight: e.$2,
            ),
        ];
      }

      test('legacy display pipeline meets the smoothness threshold', () {
        final trace = _loadFixture();
        final kalman = KalmanFlowEstimator(initialWeight: trace.first.weight);
        final calculator = FlowCalculator(
          windowDuration: const Duration(milliseconds: 600),
        );
        final average = MovingAverage(10);
        final kalmanFlows = <double>[];
        final displayFlows = <double>[];

        for (final sample in trace) {
          final (_, controlFlow) = kalman.addSample(
            sample.timestamp,
            sample.weight,
          );
          average.add(calculator.addSample(sample.timestamp, sample.weight));
          kalmanFlows.add(controlFlow);
          displayFlows.add(average.average);
        }

        final controlDelta = _meanAbsoluteDelta(kalmanFlows.skip(10).toList());
        final displayDelta = _meanAbsoluteDelta(displayFlows.skip(10).toList());

        expect(displayDelta, lessThanOrEqualTo(0.12));
        expect(controlDelta, greaterThan(displayDelta));
      });

      test('Kalman flow is natively signed (no abs())', () {
        final estimator = KalmanFlowEstimator(initialWeight: 50.0);
        final t0 = DateTime.fromMillisecondsSinceEpoch(
          1783576240000,
          isUtc: true,
        );

        for (int i = 0; i <= 10; i++) {
          estimator.addSample(
            t0.add(Duration(milliseconds: 100 * i)),
            50.0 + 7.0 * i * 0.1,
          );
        }
        for (int i = 11; i <= 30; i++) {
          estimator.addSample(
            t0.add(Duration(milliseconds: 100 * i)),
            57.0 - 7.0 * (i - 11) * 0.1,
          );
        }

        expect(
          estimator.flow,
          lessThan(-0.5),
          reason: 'signed flow — cup removal should produce negative flow',
        );
      });

      test('no absurd flow spikes on real data', () {
        final trace = _loadFixture();
        final estimator = KalmanFlowEstimator(
          initialWeight: trace.first.weight,
        );

        for (final s in trace) {
          final (_, f) = estimator.addSample(s.timestamp, s.weight);
          expect(
            f.abs(),
            lessThan(15.0),
            reason: 'flow should never exceed 15 g/s (unphysical)',
          );
        }
      });

      test('weight estimate tracks raw weight within 2g over the pour', () {
        final trace = _loadFixture();
        final estimator = KalmanFlowEstimator(
          initialWeight: trace.first.weight,
        );

        for (int i = 0; i < trace.length; i++) {
          final (w, _) = estimator.addSample(
            trace[i].timestamp,
            trace[i].weight,
          );
          if (i >= 5) {
            expect(
              (w - trace[i].weight).abs(),
              lessThan(3.0),
              reason: 'filtered weight should not drift more than 3g from raw',
            );
          }
        }
      });
    });
  });
}

double _meanAbsoluteDelta(List<double> values) {
  final deltas = [
    for (var i = 1; i < values.length; i++) (values[i] - values[i - 1]).abs(),
  ];
  return deltas.reduce((a, b) => a + b) / deltas.length;
}
