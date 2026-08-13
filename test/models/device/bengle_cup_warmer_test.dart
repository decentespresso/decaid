import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/device/impl/bengle/bengle.dart';
import 'package:reaprime/src/models/device/impl/bengle/bengle_mmr.dart';
import 'package:reaprime/src/models/device/impl/de1/de1.models.dart';

import '../../helpers/fake_ble_transport.dart';

void main() {
  group('Bengle cup warmer wiring', () {
    late FakeBleTransport transport;
    late Bengle bengle;

    setUp(() async {
      transport = FakeBleTransport();
      bengle = Bengle(transport: transport);
      transport.queueOnConnectResponses(v13Model: 128);
      transport.queueMmrResponseRaw(
        BengleMmr.scaleCalWeight,
        [0xD0, 0x07, 0x00, 0x00], // probe
      );
      transport.queuePaletteHydrationResponses();
      await bengle.onConnect();
    });

    tearDown(() {
      transport.dispose();
    });

    test(
      'setCupWarmerTemperature writes whole degrees to BengleMmr.matSetPoint',
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
        expect(payload.getUint32(0, Endian.little), equals(60));
      },
    );

    test(
      'getCupWarmerTemperature reads whole degrees back from the wire',
      () async {
        final bytes = ByteData(4)..setUint32(0, 50, Endian.little);
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
      expect(payload.getUint32(0, Endian.little), equals(80));
    });
  });

  group('Bengle cup warmer mode + temperature wiring', () {
    late FakeBleTransport transport;
    late Bengle bengle;

    setUp(() async {
      transport = FakeBleTransport();
      bengle = Bengle(transport: transport);
      transport.queueOnConnectResponses(v13Model: 128);
      transport.queueMmrResponseRaw(
        BengleMmr.scaleCalWeight,
        [0xD0, 0x07, 0x00, 0x00], // probe
      );
      transport.queuePaletteHydrationResponses();
      await bengle.onConnect();
    });

    test('setCupWarmerEnabled writes 1/0 to CupWarmerMode (0x38AC)', () async {
      transport.writes.clear();
      await bengle.setCupWarmerEnabled(true);
      await bengle.setCupWarmerEnabled(false);

      final addr = ByteData(4)
        ..setInt32(0, BengleMmr.cupWarmerMode.address, Endian.big);
      final frames = transport.writes
          .where((w) => w.characteristicUUID == Endpoint.writeToMMR.uuid)
          .toList();
      expect(frames.length, 2);
      for (final frame in frames) {
        expect(frame.data[1], addr.getUint8(1));
        expect(frame.data[2], addr.getUint8(2));
        expect(frame.data[3], addr.getUint8(3));
      }
      final on = ByteData.sublistView(frames[0].data, 4, 8);
      final off = ByteData.sublistView(frames[1].data, 4, 8);
      expect(on.getUint32(0, Endian.little), 1);
      expect(off.getUint32(0, Endian.little), 0);
    });

    test('getCupWarmerEnabled reads CupWarmerMode', () async {
      transport.queueMmrResponseInt(BengleMmr.cupWarmerMode, 1);
      expect(await bengle.getCupWarmerEnabled(), isTrue);
    });

    test(
      'getCupWarmerCurrentTemperature scales x10 and nulls on raw zero',
      () async {
        transport.queueMmrResponseInt(BengleMmr.matCurrentTemp, 425);
        expect(
          await bengle.getCupWarmerCurrentTemperature(),
          closeTo(42.5, 1e-9),
        );

        transport.queueMmrResponseInt(BengleMmr.matCurrentTemp, 0);
        expect(await bengle.getCupWarmerCurrentTemperature(), isNull);
      },
    );

    test(
      'setCupWarmerPreheat writes enable then lead, clamping lead to 0..120',
      () async {
        transport.writes.clear();
        await bengle.setCupWarmerPreheat(enabled: true, leadMinutes: 45);
        await bengle.setCupWarmerPreheat(enabled: false, leadMinutes: 999);

        final enableAddr = ByteData(4)
          ..setInt32(0, BengleMmr.matPreheatEnable.address, Endian.big);
        final leadAddr = ByteData(4)
          ..setInt32(0, BengleMmr.matPreheatLeadMin.address, Endian.big);
        final frames = transport.writes
            .where((w) => w.characteristicUUID == Endpoint.writeToMMR.uuid)
            .toList();
        expect(frames.length, 4);

        void expectFrame(int index, BengleMmr mmr, int value) {
          final frame = frames[index];
          final addr = ByteData(4)..setInt32(0, mmr.address, Endian.big);
          expect(frame.data[1], addr.getUint8(1));
          expect(frame.data[2], addr.getUint8(2));
          expect(frame.data[3], addr.getUint8(3));
          final payload = ByteData.sublistView(frame.data, 4, 8);
          expect(payload.getUint32(0, Endian.little), value);
        }

        expectFrame(0, BengleMmr.matPreheatEnable, 1);
        expectFrame(1, BengleMmr.matPreheatLeadMin, 45);
        expectFrame(2, BengleMmr.matPreheatEnable, 0);
        expectFrame(3, BengleMmr.matPreheatLeadMin, 120);
        expect(enableAddr, isNotNull);
        expect(leadAddr, isNotNull);
      },
    );

    test('getCupWarmerPreheatState reads all three registers', () async {
      transport.queueMmrResponseInt(BengleMmr.matPreheatEnable, 1);
      transport.queueMmrResponseInt(BengleMmr.matPreheatLeadMin, 60);
      transport.queueMmrResponseInt(BengleMmr.matPreheatActive, 1);

      final state = await bengle.getCupWarmerPreheatState();
      expect(state.enabled, isTrue);
      expect(state.leadMinutes, 60);
      expect(state.active, isTrue);
    });
  });
}
