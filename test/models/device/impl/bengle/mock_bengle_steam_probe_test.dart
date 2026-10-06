import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/device/impl/bengle/mock_bengle.dart';
import 'package:reaprime/src/models/device/machine.dart';

import '../../../../helpers/fake_time.dart';

void main() {
  group('MockBengle milk-probe surface', () {
    late MockBengle bengle;
    late FakeTime time;

    setUp(() async {
      time = FakeTime();
      await time.run(() {
        bengle = MockBengle();
        return bengle.onConnect();
      });
    });

    tearDown(() async {
      await bengle.onDisconnect();
      expect(time.pendingTimers, isEmpty);
    });

    test('stopAtTemperatureTarget round-trips set/get', () async {
      await bengle.setStopAtTemperatureTarget(60.0);
      expect(await bengle.getStopAtTemperatureTarget(), 60.0);
      final streamed = await bengle.stopAtTemperatureTarget.first;
      expect(streamed, 60.0);
    });

    test('setStopAtTemperatureTarget clamps to 0..85', () async {
      await bengle.setStopAtTemperatureTarget(120.0);
      expect(await bengle.getStopAtTemperatureTarget(), 85.0);
      await bengle.setStopAtTemperatureTarget(-5.0);
      expect(await bengle.getStopAtTemperatureTarget(), 0.0);
    });

    test('probeAttached defaults to true', () async {
      final value = await bengle.probeAttached.first;
      expect(value, isTrue);
    });

    test('probeAttached can be flipped via setProbeAttached', () async {
      bengle.setProbeAttached(false);
      final value = await bengle.probeAttached.first;
      expect(value, isFalse);
    });

    test('probeTemperature emits while machine state is steam', () async {
      final samples = <double>[];
      final sub = bengle.probeTemperature.listen(samples.add);
      await bengle.requestState(MachineState.steam);
      await bengle.setStopAtTemperatureTarget(0.0);
      await time.elapse(const Duration(seconds: 3));
      await sub.cancel();
      expect(samples, isNotEmpty);
      expect(samples.last, greaterThan(samples.first));
    });

    test('autonomous stop triggers idle when probe reaches target', () async {
      await bengle.setStopAtTemperatureTarget(20.0);
      final stateChanges = <MachineState>[];
      final sub = bengle.currentSnapshot
          .map((s) => s.state.state)
          .distinct()
          .listen(stateChanges.add);
      await bengle.requestState(MachineState.steam);
      await time.elapse(const Duration(seconds: 3));
      expect(stateChanges, contains(MachineState.steam));
      expect(stateChanges, isNot(contains(MachineState.idle)));
      await time.elapse(const Duration(seconds: 3));
      await sub.cancel();
      expect(stateChanges, contains(MachineState.steam));
      expect(
        stateChanges,
        contains(MachineState.idle),
        reason: 'autonomous stop should request idle when target reached',
      );
    });
  });
}
