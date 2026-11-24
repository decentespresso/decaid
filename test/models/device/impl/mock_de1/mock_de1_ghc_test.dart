import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/device/impl/mock_de1/mock_de1.dart';
import 'package:reaprime/src/models/device/machine.dart';

void main() {
  test('MockDe1 reports no GHC by default', () {
    expect(MockDe1().machineInfo.groupHeadControllerPresent, isFalse);
  });

  test('MockDe1 with GHC still accepts app-driven state changes', () async {
    final de1 = MockDe1(
      groupHeadControllerPresent: true,
      simulationTickInterval: const Duration(milliseconds: 10),
    );
    await de1.onConnect();
    expect(de1.machineInfo.groupHeadControllerPresent, isTrue);
    expect(de1.machineInfo.toJson()['GHC'], isTrue);

    for (final state in [
      MachineState.espresso,
      MachineState.steam,
      MachineState.hotWater,
      MachineState.flush,
      MachineState.idle,
      MachineState.sleeping,
    ]) {
      await de1.requestState(state);
      await de1.currentSnapshot
          .firstWhere((s) => s.state.state == state)
          .timeout(const Duration(seconds: 2));
    }
    await de1.onDisconnect();
  });
}
