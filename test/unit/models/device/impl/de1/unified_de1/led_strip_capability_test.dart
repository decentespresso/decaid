import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/device/impl/bengle/bengle.dart';
import 'package:reaprime/src/models/device/impl/bengle/bengle_mmr.dart';
import 'package:reaprime/src/models/device/impl/de1/de1.models.dart';
import 'package:reaprime/src/models/device/led_strip.dart';

import '../../../../../../helpers/fake_ble_transport.dart';

void main() {
  group('LedStripCapability', () {
    late FakeBleTransport transport;
    late Bengle bengle;

    Future<void> connect({bool queuePalette = true}) async {
      transport = FakeBleTransport();
      bengle = Bengle(transport: transport);
      transport.queueOnConnectResponses(v13Model: 128);
      transport.queueMmrResponseRaw(
        BengleMmr.scaleCalWeight,
        [0xD0, 0x07, 0x00, 0x00], // probe
      );
      if (queuePalette) {
        // Palette registers, wire values 0x00RRGGBB.
        transport.queueMmrResponseInt(BengleMmr.frontLedAwake, 0xFF8000);
        transport.queueMmrResponseInt(BengleMmr.frontLedSleep, 0x302010);
        transport.queueMmrResponseInt(BengleMmr.rearLedAwake, 0x00FF00);
        transport.queueMmrResponseInt(BengleMmr.rearLedSleep, 0x0000FF);
      }
      await bengle.onConnect();
    }

    tearDown(() {
      transport.dispose();
    });

    test('ledStripState returns a nullable stream', () async {
      await connect();
      expect(bengle.ledStripState, isA<Stream<LedStripState?>>());
    });

    test('hydration reads the palette registers once at connect', () async {
      await connect();
      final state = await bengle.getLedStripState();
      expect(state, isNotNull);
      expect(state!.frontStrip.awake, const Color16(0xFF00, 0x8000, 0x0000));
      expect(state.frontStrip.sleeping, const Color16(0x3000, 0x2000, 0x1000));
      expect(state.backStrip.awake, const Color16(0x0000, 0xFF00, 0x0000));
      expect(state.backStrip.sleeping, const Color16(0x0000, 0x0000, 0xFF00));
    });

    test(
      'hydrated frontSwitch is derived from the front strip palette',
      () async {
        await connect();
        final state = (await bengle.getLedStripState())!;
        expect(state.frontSwitch.awake, state.frontStrip.awake);
        expect(state.frontSwitch.sleeping, state.frontStrip.sleeping);
      },
    );

    test(
      'a black front strip derives product-default switch colours',
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
        // Front strip black, rear non-black.
        transport.queueMmrResponseInt(BengleMmr.frontLedAwake, 0x000000);
        transport.queueMmrResponseInt(BengleMmr.frontLedSleep, 0x000000);
        transport.queueMmrResponseInt(BengleMmr.rearLedAwake, 0xFFFFFF);
        transport.queueMmrResponseInt(BengleMmr.rearLedSleep, 0x000000);
        await bengle.onConnect();

        final state = (await bengle.getLedStripState())!;
        expect(
          state.frontSwitch.awake,
          const Color16(0xFF00, 0xF000, 0xC800), // kSwitchDefaultAwake
        );
        expect(
          state.frontSwitch.sleeping,
          const Color16(0x5500, 0x5000, 0x4300), // kSwitchDefaultAsleep
        );
      },
    );

    test(
      'failed hydration leaves the state null (no fabricated black)',
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
        transport.failMmrReadsForAddresses.addAll([
          BengleMmr.frontLedAwake.address,
          BengleMmr.frontLedSleep.address,
          BengleMmr.rearLedAwake.address,
          BengleMmr.rearLedSleep.address,
        ]);
        await bengle.onConnect();

        expect(await bengle.getLedStripState(), isNull);
      },
    );

    test(
      'setLedStrip writes the palette write-through with 8-bit RGB',
      () async {
        await connect();
        transport.writes.clear();
        await bengle.setLedStrip(
          LedStripState(
            frontStrip: ZoneLedState(
              awake: const Color16(0xFFFF, 0x8000, 0x0000),
              sleeping: const Color16(0x3000, 0x2000, 0x1000),
            ),
            backStrip: ZoneLedState(
              awake: const Color16(0x0000, 0xFF00, 0x0000),
              sleeping: Color16.off,
            ),
            // frontSwitch is not a hardware control; must be ignored.
            frontSwitch: const ZoneLedState(
              awake: Color16(0xFFFF, 0xFFFF, 0xFFFF),
              sleeping: Color16(0xFFFF, 0xFFFF, 0xFFFF),
            ),
          ),
        );

        final writes = transport.writes
            .where((w) => w.characteristicUUID == Endpoint.writeToMMR.uuid)
            .toList();
        expect(writes.length, 4);

        void expectWrite(BengleMmr mmr, int rgb) {
          final frame = writes.firstWhere(
            (w) =>
                w.data[1] ==
                    (ByteData(
                      4,
                    )..setInt32(0, mmr.address, Endian.big)).getUint8(1) &&
                w.data[2] ==
                    (ByteData(
                      4,
                    )..setInt32(0, mmr.address, Endian.big)).getUint8(2) &&
                w.data[3] ==
                    (ByteData(
                      4,
                    )..setInt32(0, mmr.address, Endian.big)).getUint8(3),
          );
          final payload = ByteData.sublistView(frame.data, 4, 8);
          expect(payload.getUint32(0, Endian.little), rgb);
        }

        expectWrite(BengleMmr.frontLedAwake, 0xFF8000);
        expectWrite(BengleMmr.frontLedSleep, 0x302010);
        expectWrite(BengleMmr.rearLedAwake, 0x00FF00);
        expectWrite(BengleMmr.rearLedSleep, 0x000000);

        // The local cache reflects the write (16-bit precision preserved;
        // only the wire truncates to 8-bit channels) with a derived switch
        // palette.
        final state = (await bengle.getLedStripState())!;
        expect(state.frontStrip.awake, const Color16(0xFFFF, 0x8000, 0x0000));
        expect(state.frontSwitch.awake, const Color16(0xFFFF, 0x8000, 0x0000));
      },
    );

    test('commitLedStrip is a no-op', () async {
      await connect();
      transport.writes.clear();
      await bengle.commitLedStrip();
      expect(transport.writes, isEmpty);
    });

    test('resetLedStrip re-reads the palette from the firmware', () async {
      await connect();
      // Firmware palette changed since hydration (e.g. another client).
      transport.queueMmrResponseInt(BengleMmr.frontLedAwake, 0x0000FF);
      transport.queueMmrResponseInt(BengleMmr.frontLedSleep, 0x000000);
      transport.queueMmrResponseInt(BengleMmr.rearLedAwake, 0xFF0000);
      transport.queueMmrResponseInt(BengleMmr.rearLedSleep, 0x00FF00);

      final state = (await bengle.resetLedStrip())!;
      expect(state.frontStrip.awake, const Color16(0x0000, 0x0000, 0xFF00));
      expect(state.backStrip.awake, const Color16(0xFF00, 0x0000, 0x0000));
      // Black front sleep derives the default switch colour again.
      expect(state.frontSwitch.sleeping, const Color16(0x5500, 0x5000, 0x4300));
    });

    test('old firmware (probe unsupported) never hydrates LED state', () async {
      transport = FakeBleTransport();
      bengle = Bengle(transport: transport);
      transport.queueOnConnectResponses(v13Model: 128);
      // No ScaleCalWeight response: probe times out, surface unsupported.
      await bengle.onConnect();

      expect(bengle.bengleFeatureSurfaceSupported, isFalse);
      expect(await bengle.getLedStripState(), isNull);
      final reads = transport.writes.where(
        (w) => w.characteristicUUID == Endpoint.readFromMMR.uuid,
      );
      expect(
        reads.any(
          (w) => w.data[1] == 0x80 && w.data[2] == 0x38 && w.data[3] >= 0x90,
        ),
        isFalse,
        reason: 'no LED palette reads on unsupported firmware',
      );
    });

    test('disposeLedStrip closes the subject', () async {
      await connect();
      await bengle.onDisconnect();
      await expectLater(
        bengle.ledStripState,
        emitsInOrder([isA<LedStripState?>(), emitsDone]),
      );
    });

    test('connect → disconnect → connect lifecycle is leak-free', () async {
      await connect();
      await bengle.disconnect();
      await expectLater(
        bengle.ledStripState,
        emitsInOrder([isA<LedStripState?>(), emitsDone]),
      );

      await connect();
      final state = await bengle.getLedStripState();
      expect(state, isNotNull);
    });
  });
}
