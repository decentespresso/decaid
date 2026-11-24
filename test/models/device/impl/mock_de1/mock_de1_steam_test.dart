import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/device/impl/mock_de1/mock_de1.dart';
import 'package:reaprime/src/models/device/machine.dart';

void main() {
  late MockDe1 de1;

  setUp(() async {
    de1 = MockDe1(simulationTickInterval: const Duration(milliseconds: 5));
    await de1.onConnect();
    final settings = await de1.shotSettings.first;
    await de1.updateShotSettings(settings.copyWith(targetSteamDuration: 2));
  });

  tearDown(() async => de1.onDisconnect());

  test('steam flows, puffs, then returns to idle on duration', () async {
    final seen = <MachineSnapshot>[];
    final sub = de1.currentSnapshot.listen(seen.add);

    await de1.requestState(MachineState.steam);
    await de1.currentSnapshot
        .firstWhere((s) => s.state.state == MachineState.idle)
        .timeout(const Duration(seconds: 5));
    await sub.cancel();

    final steaming = seen.where(
      (s) =>
          s.state.state == MachineState.steam &&
          s.state.substate == MachineSubstate.pouring,
    );
    expect(steaming, isNotEmpty);
    expect(
      steaming.map((s) => s.flow).reduce((a, b) => a > b ? a : b),
      greaterThan(0.5),
    );
    expect(steaming.last.pressure, greaterThan(0));
    expect(
      steaming.last.steamTemperature,
      greaterThan(steaming.first.steamTemperature),
    );
    expect(
      seen.any(
        (s) =>
            s.state.state == MachineState.steam &&
            s.state.substate == MachineSubstate.puffing,
      ),
      isTrue,
    );
  });

  test('requesting idle stops steam immediately', () async {
    await de1.requestState(MachineState.steam);
    await de1.currentSnapshot
        .firstWhere((s) => s.state.substate == MachineSubstate.pouring)
        .timeout(const Duration(seconds: 2));
    await de1.requestState(MachineState.idle);
    await de1.currentSnapshot
        .firstWhere((s) => s.state.state == MachineState.idle)
        .timeout(const Duration(seconds: 2));
  });
}
