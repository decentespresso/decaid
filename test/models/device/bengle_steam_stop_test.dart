import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/device/impl/bengle/bengle.dart';
import 'package:reaprime/src/models/device/impl/bengle/bengle_mmr.dart';
import 'package:reaprime/src/models/device/impl/de1/de1.models.dart';

import '../../helpers/fake_ble_transport.dart';

/// Pins the real-`Bengle` stop-at-temperature stub contract. FW slot
/// for `BengleSteamMmr.stopAtTemperatureTarget` is still `0x00000000`,
/// so writes cache locally and never hit the MMR endpoint. When FW
/// publishes the real slot, the pin test flips and the rest of the
/// group needs the assertions inverted.
void main() {
  group('Bengle stop-at-temperature wiring (FW slot stubbed)', () {
    late FakeBleTransport transport;
    late Bengle bengle;

    setUp(() async {
      transport = FakeBleTransport();
      bengle = Bengle(transport: transport);
      transport.queueOnConnectResponses(v13Model: 128);
      await bengle.onConnect();
    });

    tearDown(() {
      transport.dispose();
    });

    test('FW slot address is still TBD', () {
      expect(BengleSteamMmr.stopAtTemperatureTarget.address, 0x00000000);
    });

    test(
      'setStopAtTemperatureTarget caches locally and does not write MMR',
      () async {
        transport.writes.clear();
        await bengle.setStopAtTemperatureTarget(65.0);

        final mmrWrites = transport.writes
            .where((w) => w.characteristicUUID == Endpoint.writeToMMR.uuid)
            .toList();
        expect(
          mmrWrites,
          isEmpty,
          reason: 'FW slot is stubbed — no MMR write should hit the wire',
        );

        expect(await bengle.getStopAtTemperatureTarget(), closeTo(65.0, 1e-6));
      },
    );

    test('setStopAtTemperatureTarget clamps to 0..80', () async {
      await bengle.setStopAtTemperatureTarget(120.0);
      expect(await bengle.getStopAtTemperatureTarget(), 80.0);

      await bengle.setStopAtTemperatureTarget(-5.0);
      expect(await bengle.getStopAtTemperatureTarget(), 0.0);
    });

    test(
      'stopAtTemperatureTarget stream emits cached value to subscribers',
      () async {
        await bengle.setStopAtTemperatureTarget(55.0);
        final value = await bengle.stopAtTemperatureTarget.first;
        expect(value, 55.0);
      },
    );

    test('probeAttached stays false on real Bengle (FW signal TBD)', () async {
      final value = await bengle.probeAttached.first;
      expect(value, isFalse);
    });
  });
}
