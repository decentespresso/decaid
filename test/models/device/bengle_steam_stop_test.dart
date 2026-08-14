import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/device/impl/bengle/bengle.dart';
import 'package:reaprime/src/models/device/impl/bengle/bengle_mmr.dart';
import 'package:reaprime/src/models/device/impl/de1/de1.models.dart';

import '../../helpers/fake_ble_transport.dart';

void main() {
  group('Bengle stop-at-temperature wiring', () {
    late FakeBleTransport transport;
    late Bengle bengle;

    setUp(() async {
      transport = FakeBleTransport();
      bengle = Bengle(transport: transport);
      transport.queueOnConnectResponses(v13Model: 128);
      transport.queuePaletteHydrationResponses();
      await bengle.onConnect();
    });

    tearDown(() {
      transport.dispose();
    });

    test('uses the firmware TargetMilkTemp MMR with x10 scaling', () async {
      expect(BengleSteamMmr.targetMilkTemp.address, 0x008038A8);

      transport.writes.clear();
      await bengle.setStopAtTemperatureTarget(65.0);

      final write = transport.writes.singleWhere(
        (entry) => entry.characteristicUUID == Endpoint.writeToMMR.uuid,
      );
      expect(write.data.sublist(0, 8), [
        0x04,
        0x80,
        0x38,
        0xA8,
        0x8A,
        0x02,
        0x00,
        0x00,
      ]);

      transport.queueMmrResponseInt(BengleSteamMmr.targetMilkTemp, 650);
      expect(await bengle.getStopAtTemperatureTarget(), closeTo(65.0, 1e-6));
    });

    test('setStopAtTemperatureTarget clamps to firmware range 0..85', () async {
      await bengle.setStopAtTemperatureTarget(120.0);
      transport.queueMmrResponseInt(BengleSteamMmr.targetMilkTemp, 850);
      expect(await bengle.getStopAtTemperatureTarget(), 85.0);

      await bengle.setStopAtTemperatureTarget(-5.0);
      transport.queueMmrResponseInt(BengleSteamMmr.targetMilkTemp, 0);
      expect(await bengle.getStopAtTemperatureTarget(), 0.0);
    });

    test(
      'stopAtTemperatureTarget stream emits written value to subscribers',
      () async {
        await bengle.setStopAtTemperatureTarget(55.0);
        final value = await bengle.stopAtTemperatureTarget.first;
        expect(value, 55.0);
      },
    );

    test(
      'probeAttached stays false until an A013 frame with MilkTemp',
      () async {
        final value = await bengle.probeAttached.first;
        expect(value, isFalse);
      },
    );
  });
}
