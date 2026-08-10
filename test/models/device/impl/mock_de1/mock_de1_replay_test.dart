import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/device/impl/mock_de1/mock_de1.dart';
import 'package:reaprime/src/models/device/impl/mock_scale/mock_scale.dart';
import 'package:reaprime/src/models/device/machine.dart';
import 'package:reaprime/src/services/simulated_shot_library.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('MockDe1 historical-shot replay', () {
    late SimulatedShotLibrary library;

    setUp(() async {
      library = SimulatedShotLibrary();
      await library.ensureLoaded();
    });

    test('emitted samples are drawn from the replayed recording', () async {
      // MockDe1 and the test share the same seed, so both pick the same shot.
      final expected = library.pickRandom(Random(42))!;
      final recordedPressures = expected.measurements
          .map((m) => m.machine.pressure)
          .toSet();
      final recordedFlows = expected.measurements
          .map((m) => m.machine.flow)
          .toSet();

      final machine = MockDe1(
        replayLibrary: library,
        replayHistoricalShots: true,
        random: Random(42),
      );
      await machine.onConnect();
      await machine.requestState(MachineState.espresso);

      final snapshots = await machine.currentSnapshot
          .take(12)
          .toList()
          .timeout(const Duration(seconds: 4));
      await machine.onDisconnect();

      final pouring = snapshots
          .where((s) => s.state.state == MachineState.espresso)
          .toList();
      expect(pouring, isNotEmpty, reason: 'replay should emit espresso frames');

      for (final s in pouring) {
        expect(
          recordedPressures.contains(s.pressure),
          isTrue,
          reason: '${s.pressure} is not a recorded pressure sample',
        );
        expect(
          recordedFlows.contains(s.flow),
          isTrue,
          reason: '${s.flow} is not a recorded flow sample',
        );
      }
    });

    test('the simulated scale reports the recorded weight, not flow '
        'integration', () async {
      final expected = library.pickRandom(Random(7))!;
      final recordedWeights = expected.measurements
          .map((m) => m.scale?.weight ?? 0.0)
          .toSet();

      final machine = MockDe1(
        replayLibrary: library,
        replayHistoricalShots: true,
        random: Random(7),
      );
      final scale = MockScale()..attachMachine(machine);
      await machine.onConnect();
      await scale.onConnect();
      await machine.requestState(MachineState.espresso);

      // Early in these recordings the real weight is still 0; a flow
      // integration would already read several grams. Sample here so the two
      // sources are distinguishable, then require exact recorded values.
      await Future.delayed(const Duration(seconds: 4));
      final snapshots = await scale.currentSnapshot
          .take(12)
          .toList()
          .timeout(const Duration(seconds: 6));
      scale.simulateDisconnect();
      await machine.onDisconnect();

      for (final s in snapshots) {
        expect(
          recordedWeights.any((w) => (w - s.weight).abs() < 1e-6),
          isTrue,
          reason: '${s.weight}g is not a recorded weight sample',
        );
      }
    });

    test('with no library injected, falls back to synthetic data', () async {
      final machine = MockDe1();
      await machine.onConnect();
      await machine.requestState(MachineState.espresso);

      await Future.delayed(const Duration(milliseconds: 600));
      final snapshots = await machine.currentSnapshot
          .take(8)
          .toList()
          .timeout(const Duration(seconds: 3));
      await machine.onDisconnect();

      // Synthetic fallback ramps pressure up smoothly from ~0.
      expect(snapshots.last.pressure, greaterThan(snapshots.first.pressure));
    });

    test('replayHistoricalShots=false forces the synthetic path', () async {
      final machine = MockDe1(
        replayLibrary: library,
        replayHistoricalShots: false,
        random: Random(42),
      );
      await machine.onConnect();
      await machine.requestState(MachineState.espresso);

      await Future.delayed(const Duration(milliseconds: 600));
      final snapshots = await machine.currentSnapshot
          .take(8)
          .toList()
          .timeout(const Duration(seconds: 3));
      await machine.onDisconnect();

      expect(snapshots.last.pressure, greaterThan(snapshots.first.pressure));
    });
  });
}
