import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/device/impl/bengle/bengle.dart';
import 'package:reaprime/src/models/device/impl/de1/de1.models.dart';
import 'package:reaprime/src/models/device/impl/de1/unified_de1/unified_de1.dart';

import '../../helpers/fake_ble_transport.dart';

void main() {
  test('uses the firmware EndOfShotWeight MMR with x100 scaling', () async {
    final transport = FakeBleTransport()
      ..queueOnConnectResponses(v13Model: 128)
      ..queuePaletteHydrationResponses();
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

  test('clamps to the firmware EndOfShotWeight range 0..10000 g', () async {
    final transport = FakeBleTransport()
      ..queueOnConnectResponses(v13Model: 128)
      ..queuePaletteHydrationResponses();
    final bengle = Bengle(transport: transport);
    await bengle.onConnect();
    addTearDown(bengle.dispose);
    transport.writes.clear();

    expect(BengleScaleMmr.endOfShotWeight.max, 1000000);

    await bengle.setStopAtWeightTarget(10000.0);
    final upperWrite = transport.writes.singleWhere(
      (entry) => entry.characteristicUUID == Endpoint.writeToMMR.uuid,
    );
    expect(upperWrite.data.sublist(0, 8), [
      0x04,
      0x80,
      0x38,
      0x64,
      0x40,
      0x42,
      0x0F,
      0x00,
    ]);

    transport.writes.clear();
    await bengle.setStopAtWeightTarget(20000.0);
    final clampedWrite = transport.writes.singleWhere(
      (entry) => entry.characteristicUUID == Endpoint.writeToMMR.uuid,
    );
    expect(
      clampedWrite.data.sublist(0, 8),
      upperWrite.data.sublist(0, 8),
      reason: 'over-range targets clamp to 10000 g before hitting the wire',
    );
  });
}
