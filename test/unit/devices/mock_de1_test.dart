import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/device/device.dart' as device;
import 'package:reaprime/src/models/device/impl/mock_de1/mock_de1.dart';

void main() {
  test(
    'setHeaterPhase2Timeout stores the value and does not change connection state',
    () async {
      final mock = MockDe1();
      final states = <device.ConnectionState>[];
      final sub = mock.connectionState.listen(states.add);

      await mock.setHeaterPhase2Timeout(7.5);

      expect(await mock.getHeaterPhase2Timeout(), 7.5);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(states, isNot(contains(device.ConnectionState.disconnected)));
      await sub.cancel();
    },
  );

  test('simulateDisconnect emits a disconnected state explicitly', () async {
    final mock = MockDe1();
    final states = <device.ConnectionState>[];
    final sub = mock.connectionState.listen(states.add);

    mock.simulateDisconnect();
    await Future<void>.delayed(Duration.zero);

    expect(states, contains(device.ConnectionState.disconnected));
    await sub.cancel();
  });
}
