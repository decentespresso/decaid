import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/data/profile.dart';
import 'package:reaprime/src/models/device/machine.dart';
import 'package:reaprime/src/models/device/scale.dart';
import 'package:reaprime/src/models/device/impl/bengle/mock_bengle.dart';

Profile _pourProfile() => Profile(
  version: '1.0',
  title: 'pour',
  notes: '',
  author: 'test',
  beverageType: BeverageType.espresso,
  targetVolumeCountStart: 0,
  tankTemperature: 92.0,
  steps: [
    ProfileStepFlow(
      name: 'pour',
      flow: 4.0,
      seconds: 40,
      temperature: 92,
      sensor: TemperatureSensor.coffee,
      transition: TransitionType.fast,
      volume: 0,
    ),
  ],
);

// A preinfusion + pour profile: weight must stay ~0 through preinfusion and the
// first-drops lag, then climb without ever going backwards.
Profile _preinfusionThenPourProfile() => Profile(
  version: '1.0',
  title: 'preinf+pour',
  notes: '',
  author: 'test',
  beverageType: BeverageType.espresso,
  targetVolumeCountStart: 1,
  tankTemperature: 92.0,
  steps: [
    ProfileStepFlow(
      name: 'preinfusion',
      flow: 8.0,
      seconds: 2,
      temperature: 92,
      sensor: TemperatureSensor.coffee,
      transition: TransitionType.fast,
      volume: 0,
    ),
    ProfileStepPressure(
      name: 'pour',
      pressure: 6.0,
      seconds: 40,
      temperature: 92,
      sensor: TemperatureSensor.coffee,
      transition: TransitionType.fast,
      volume: 0,
    ),
  ],
);

void main() {
  group('MockBengle integrated scale', () {
    late MockBengle bengle;

    setUp(() async {
      bengle = MockBengle();
      await bengle.onConnect();
    });

    tearDown(() async {
      await bengle.onDisconnect();
    });

    test('emits weightSnapshot after connect', () async {
      final snapshot = await bengle.weightSnapshot.first.timeout(
        const Duration(seconds: 2),
      );
      expect(snapshot.batteryLevel, 100);
      expect(snapshot.weight, isA<double>());
    });

    test('weight rises during simulated espresso shot', () async {
      await bengle.setProfile(_pourProfile());
      final pre = await bengle.weightSnapshot.first.timeout(
        const Duration(seconds: 2),
      );

      await bengle.requestState(MachineState.espresso);
      await Future.delayed(const Duration(seconds: 5));
      await bengle.requestState(MachineState.idle);

      final post = await bengle.weightSnapshot.first.timeout(
        const Duration(seconds: 2),
      );
      expect(post.weight, greaterThan(pre.weight));
    });

    test(
      'weight lags the pour start, then rises smoothly and monotonically',
      () async {
        await bengle.setProfile(_preinfusionThenPourProfile());

        final samples = <double>[];
        final sub = bengle.weightSnapshot.listen((w) => samples.add(w.weight));

        await bengle.requestState(MachineState.espresso);
        await Future.delayed(const Duration(milliseconds: 8000));
        await bengle.requestState(MachineState.idle);
        await sub.cancel();

        final early = samples.take(25);
        for (final w in early) {
          expect(
            w,
            lessThan(0.5),
            reason: 'no weight through preinfusion + first drops',
          );
        }

        expect(
          samples.last,
          greaterThan(5.0),
          reason: 'weight builds to a real dose',
        );
        var prev = -1.0;
        for (final w in samples) {
          expect(
            w,
            greaterThanOrEqualTo(prev - 0.001),
            reason: 'weight is monotonic',
          );
          prev = w;
        }
      },
    );

    test('tareIntegratedScale zeroes the next emit', () async {
      await bengle.requestState(MachineState.espresso);
      await Future.delayed(const Duration(seconds: 1));
      await bengle.requestState(MachineState.idle);

      await bengle.weightSnapshot.first;
      await bengle.tareIntegratedScale();
      final next = await bengle.weightSnapshot.first.timeout(
        const Duration(seconds: 2),
      );
      expect(next.weight.abs(), lessThan(0.01));
    });

    test('disconnect closes the snapshot stream', () async {
      await bengle.onDisconnect();
      final all = await bengle.weightSnapshot.toList().timeout(
        const Duration(seconds: 1),
      );
      expect(all, isA<List<ScaleSnapshot>>());
    });
  });
}
