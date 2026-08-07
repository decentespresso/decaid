import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/device/impl/bengle/bengle.dart';
import 'package:reaprime/src/models/device/impl/bengle/bengle_mmr.dart';
import 'package:reaprime/src/models/device/impl/de1/de1.models.dart';

import '../../helpers/fake_ble_transport.dart';

/// Wires the real `Bengle` class through `FakeBleTransport` to confirm the
/// public cup-warmer API (setCupWarmerTemperature / getCupWarmerTemperature)
/// rides the scaledFloat MMR helpers and the `BengleMmr.matSetPoint` address.
///
/// This is the integration point between `BengleInterface`,
/// `Bengle`'s extension on `UnifiedDe1`'s `@protected` MMR helpers, and the
/// `MmrValueKind.scaledFloat` plumbing. The unit-level mechanics
/// (clamping, packing, kind-mismatch errors) live in
/// `test/unit/models/device/impl/de1/unified_de1/protected_surface_test.dart`.
void main() {
  group('Bengle cup warmer wiring', () {
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

    test(
      'setCupWarmerTemperature writes a scaled uint32 to BengleMmr.matSetPoint',
      () async {
        transport.writes.clear();
        await bengle.setCupWarmerTemperature(60.0);

        final frame = transport.writes.firstWhere(
          (w) => w.characteristicUUID == Endpoint.writeToMMR.uuid,
        );

        final addr = ByteData(4)
          ..setInt32(0, BengleMmr.matSetPoint.address, Endian.big);
        expect(frame.data[1], addr.getUint8(1));
        expect(frame.data[2], addr.getUint8(2));
        expect(frame.data[3], addr.getUint8(3));

        final payload = ByteData.sublistView(frame.data, 4, 8);
        expect(payload.getUint32(0, Endian.little), equals(600));
      },
    );

    test(
      'getCupWarmerTemperature reads a scaled uint32 back from the wire',
      () async {
        final bytes = ByteData(4)..setUint32(0, 500, Endian.little);
        transport.queueMmrResponseRaw(
          BengleMmr.matSetPoint,
          List<int>.generate(4, (i) => bytes.getUint8(i)),
        );

        final result = await bengle.getCupWarmerTemperature();
        expect(result, closeTo(50.0, 1e-6));
      },
    );

    test('setCupWarmerTemperature clamps over-range writes', () async {
      transport.writes.clear();
      await bengle.setCupWarmerTemperature(120.0);

      final frame = transport.writes.firstWhere(
        (w) => w.characteristicUUID == Endpoint.writeToMMR.uuid,
      );
      final payload = ByteData.sublistView(frame.data, 4, 8);
      expect(payload.getUint32(0, Endian.little), equals(800));
    });
  });
}
