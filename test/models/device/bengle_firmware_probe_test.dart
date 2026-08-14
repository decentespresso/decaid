import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/device/impl/bengle/bengle.dart';
import 'package:reaprime/src/models/device/impl/bengle/bengle_mmr.dart';
import 'package:reaprime/src/models/device/impl/de1/de1.models.dart';

import '../../helpers/fake_ble_transport.dart';

void main() {
  group('Bengle firmware surface probe', () {
    late FakeBleTransport transport;
    late Bengle bengle;

    tearDown(() {
      transport.dispose();
    });

    test('probe runs once at connect and reports supported', () async {
      transport = FakeBleTransport();
      bengle = Bengle(transport: transport);
      transport.queueOnConnectResponses(v13Model: 128);
      transport.queueMmrResponseRaw(
        BengleMmr.scaleCalWeight,
        [0xD0, 0x07, 0x00, 0x00], // 2000 little-endian = default 200.0 g
      );
      transport.queuePaletteHydrationResponses();
      await bengle.onConnect();

      expect(bengle.supportsCurrentBengleFirmwareSurface, isTrue);
      final addr = ByteData(4)
        ..setInt32(0, BengleMmr.scaleCalWeight.address, Endian.big);
      final reads = transport.writes.where(
        (w) =>
            w.characteristicUUID == Endpoint.readFromMMR.uuid &&
            w.data[1] == addr.getUint8(1) &&
            w.data[2] == addr.getUint8(2) &&
            w.data[3] == addr.getUint8(3),
      );
      expect(reads.length, 1, reason: 'probe must read exactly once');
      final frame = reads.single;
      expect(frame.data[1], addr.getUint8(1));
      expect(frame.data[2], addr.getUint8(2));
      expect(frame.data[3], addr.getUint8(3));

      transport.writes.clear();
      await bengle.probeBengleFirmwareSurface();
      expect(bengle.supportsCurrentBengleFirmwareSurface, isTrue);
      expect(
        transport.writes.where(
          (w) =>
              w.characteristicUUID == Endpoint.readFromMMR.uuid &&
              w.data[1] == addr.getUint8(1) &&
              w.data[2] == addr.getUint8(2) &&
              w.data[3] == addr.getUint8(3),
        ),
        isEmpty,
      );
    });

    test(
      'probe accepts a zero response as supported (register exists)',
      () async {
        transport = FakeBleTransport();
        bengle = Bengle(transport: transport);
        transport.queueOnConnectResponses(v13Model: 128);
        transport.queueMmrResponseRaw(BengleMmr.scaleCalWeight, [
          0x00,
          0x00,
          0x00,
          0x00,
        ]);
        transport.queuePaletteHydrationResponses();
        await bengle.onConnect();

        expect(bengle.supportsCurrentBengleFirmwareSurface, isTrue);
      },
    );

    test('probe reports unsupported when every attempt times out', () async {
      transport = FakeBleTransport();
      bengle = Bengle(transport: transport);
      transport.queueOnConnectResponses(v13Model: 128);
      await bengle.onConnect();

      expect(bengle.supportsCurrentBengleFirmwareSurface, isFalse);

      final addr = ByteData(4)
        ..setInt32(0, BengleMmr.scaleCalWeight.address, Endian.big);
      final reads = transport.writes.where(
        (w) =>
            w.characteristicUUID == Endpoint.readFromMMR.uuid &&
            w.data[1] == addr.getUint8(1) &&
            w.data[2] == addr.getUint8(2) &&
            w.data[3] == addr.getUint8(3),
      );
      expect(reads.length, 2);
    });

    test(
      'a single dropped response does not disable the surface; retry reads',
      () async {
        transport = FakeBleTransport();
        bengle = Bengle(transport: transport);
        transport.queueOnConnectResponses(v13Model: 128);
        transport.queueMmrResponseRaw(BengleMmr.scaleCalWeight, [
          0xD0,
          0x07,
          0x00,
          0x00,
        ]);
        transport.queuePaletteHydrationResponses();
        transport.dropNextMmrResponseForAddresses.add(
          BengleMmr.scaleCalWeight.address,
        );
        await bengle.onConnect();

        expect(
          bengle.supportsCurrentBengleFirmwareSurface,
          isTrue,
          reason:
              'one dropped BLE response must not latch the surface as '
              'unsupported for the whole connection',
        );

        final addr = ByteData(4)
          ..setInt32(0, BengleMmr.scaleCalWeight.address, Endian.big);
        final reads = transport.writes.where(
          (w) =>
              w.characteristicUUID == Endpoint.readFromMMR.uuid &&
              w.data[1] == addr.getUint8(1) &&
              w.data[2] == addr.getUint8(2) &&
              w.data[3] == addr.getUint8(3),
        );
        expect(reads.length, 2);
      },
    );
  });
}
