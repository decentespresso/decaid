import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/device/impl/bengle/bengle.dart';
import 'package:reaprime/src/models/device/impl/de1/de1.models.dart';
import 'package:reaprime/src/models/device/impl/de1/unified_de1/unified_de1.dart';

import '../../helpers/fake_ble_transport.dart';

void main() {
  group('Bengle SAW wiring (FW slot stubbed)', () {
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
      expect(BengleScaleMmr.stopAtWeightTarget.address, 0x00000000);
    });

    test(
      'setStopAtWeightTarget caches locally and does not write MMR',
      () async {
        transport.writes.clear();
        await bengle.setStopAtWeightTarget(30.0);

        final mmrWrites = transport.writes
            .where((w) => w.characteristicUUID == Endpoint.writeToMMR.uuid)
            .toList();
        expect(
          mmrWrites,
          isEmpty,
          reason: 'FW slot is stubbed — no MMR write should hit the wire',
        );

        expect(await bengle.getStopAtWeightTarget(), closeTo(30.0, 1e-6));
      },
    );

    test('setStopAtWeightTarget clamps to 0..500', () async {
      await bengle.setStopAtWeightTarget(1000.0);
      expect(await bengle.getStopAtWeightTarget(), 500.0);

      await bengle.setStopAtWeightTarget(-5.0);
      expect(await bengle.getStopAtWeightTarget(), 0.0);
    });

    test(
      'stopAtWeightTarget stream emits cached value to subscribers',
      () async {
        await bengle.setStopAtWeightTarget(42.0);
        final value = await bengle.stopAtWeightTarget.first;
        expect(value, 42.0);
      },
    );
  });
}
