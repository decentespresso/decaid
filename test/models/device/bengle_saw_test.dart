import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/device/impl/bengle/bengle.dart';
import 'package:reaprime/src/models/device/impl/de1/de1.models.dart';
import 'package:reaprime/src/models/device/impl/de1/unified_de1/unified_de1.dart';

import '../../helpers/fake_ble_transport.dart';

void main() {
  test('uses the firmware EndOfShotWeight MMR with x100 scaling', () async {
    final transport = FakeBleTransport()
      ..queueOnConnectResponses(v13Model: 128);
    final bengle = Bengle(transport: transport);
    await bengle.onConnect();
    addTearDown(bengle.dispose);
    transport.writes.clear();

    await bengle.setStopAtWeightTarget(30.0);

    expect(BengleScaleMmr.endOfShotWeight.address, 0x00803864);
    final write = transport.writes.singleWhere(
      (entry) => entry.characteristicUUID == Endpoint.writeToMMR.uuid,
    );
    expect(write.data.sublist(0, 8), [
      0x04,
      0x80,
      0x38,
      0x64,
      0xB8,
      0x0B,
      0x00,
      0x00,
    ]);

    transport.queueMmrResponseInt(BengleScaleMmr.endOfShotWeight, 4250);
    expect(await bengle.getStopAtWeightTarget(), 42.5);
  });
}
