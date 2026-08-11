import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/data/profile.dart';
import 'package:reaprime/src/models/device/impl/replay/mock_replay_de1.dart';
import 'package:reaprime/src/models/device/impl/replay/mock_replay_scale.dart';
import 'package:reaprime/src/models/device/machine.dart';
import 'package:reaprime/src/services/simulated_shot_library.dart';

Profile _profile(String title) => Profile(
  version: '2',
  title: title,
  notes: '',
  author: '',
  beverageType: BeverageType.espresso,
  steps: const [],
  targetVolumeCountStart: 0,
  tankTemperature: 0,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('MockReplayDe1', () {
    late SimulatedShotLibrary library;

    setUp(() async {
      library = SimulatedShotLibrary();
      await library.ensureLoaded();
    });

    test('replays the shot recorded with the selected profile', () async {
      final expected = library.forProfileTitle('Adaptive v2')!;
      final recordedPressures = expected.measurements
          .map((m) => m.machine.pressure)
          .toSet();

      final machine = MockReplayDe1(library: library);
      await machine.setProfile(_profile('Adaptive v2'));
      await machine.onConnect();
      await machine.requestState(MachineState.espresso);

      final snapshots = await machine.currentSnapshot
          .where((s) => s.state.state == MachineState.espresso)
          .take(15)
          .toList()
          .timeout(const Duration(seconds: 5));
      await machine.disconnect();

      expect(snapshots, isNotEmpty);
      for (final s in snapshots) {
        expect(
          recordedPressures.contains(s.pressure),
          isTrue,
          reason: '${s.pressure} is not from the Adaptive v2 recording',
        );
      }
    });

    test('falls back to a generic shot for an unmatched profile', () async {
      final machine = MockReplayDe1(library: library);
      await machine.setProfile(_profile('No Such Profile 999'));
      await machine.onConnect();
      await machine.requestState(MachineState.espresso);

      final snapshots = await machine.currentSnapshot
          .where((s) => s.state.state == MachineState.espresso)
          .take(5)
          .toList()
          .timeout(const Duration(seconds: 5));
      await machine.disconnect();

      expect(
        snapshots,
        isNotEmpty,
        reason: 'fallback shot should still replay',
      );
    });

    test('the replay scale reports the recorded weight', () async {
      final expected = library.forProfileTitle('Adaptive v2')!;
      final recordedWeights = expected.measurements
          .map((m) => m.scale?.weight ?? 0.0)
          .toSet();

      final machine = MockReplayDe1(library: library);
      final scale = MockReplayScale()..attachMachine(machine);
      await machine.setProfile(_profile('Adaptive v2'));
      await machine.onConnect();
      await scale.onConnect();
      await machine.requestState(MachineState.espresso);

      final snapshots = await scale.currentSnapshot
          .take(15)
          .toList()
          .timeout(const Duration(seconds: 5));
      await scale.disconnect();
      await machine.disconnect();

      for (final s in snapshots) {
        expect(
          recordedWeights.any((w) => (w - s.weight).abs() < 1e-6),
          isTrue,
          reason: '${s.weight}g is not a recorded weight sample',
        );
      }
    });
  });
}
