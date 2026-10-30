import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/device/bengle_interface.dart';
import 'package:reaprime/src/models/device/impl/bengle/bengle.dart';
import 'package:reaprime/src/models/device/impl/bengle/bengle_mmr.dart';
import 'package:reaprime/src/models/device/impl/de1/de1.models.dart';
import 'package:reaprime/src/models/device/led_strip.dart';

import '../../../../../../helpers/fake_ble_transport.dart';

class _RawWriteBengle extends Bengle {
  _RawWriteBengle({required super.transport});

  Future<void> rawWrite(BengleMmr register, int rgb) =>
      writeMmrInt(register, rgb);
}

class _BlockingPreviewTransport extends FakeBleTransport {
  final int blockedAddress;
  final writeStarted = Completer<void>();
  final releaseWrite = Completer<void>();
  bool _blocked = false;

  _BlockingPreviewTransport(this.blockedAddress);

  @override
  Future<void> write(
    String serviceUUID,
    String characteristicUUID,
    Uint8List data, {
    bool withResponse = true,
    Duration? timeout,
  }) async {
    final address = data.length >= 4
        ? (data[1] << 16) | (data[2] << 8) | data[3]
        : null;
    if (characteristicUUID == Endpoint.writeToMMR.uuid &&
        address == blockedAddress &&
        !_blocked) {
      _blocked = true;
      writeStarted.complete();
      await releaseWrite.future;
    }
    await super.write(
      serviceUUID,
      characteristicUUID,
      data,
      withResponse: withResponse,
      timeout: timeout,
    );
  }
}

class _FlappingPhaseTransport extends FakeBleTransport {
  int restorePasses = 0;
  bool _asleep = true;

  @override
  Future<void> write(
    String serviceUUID,
    String characteristicUUID,
    Uint8List data, {
    bool withResponse = true,
    Duration? timeout,
  }) async {
    final address = data.length >= 4
        ? (data[1] << 16) | (data[2] << 8) | data[3]
        : null;
    if (characteristicUUID == Endpoint.writeToMMR.uuid &&
        address == BengleMmr.frontLedColor.address &&
        restorePasses >= 5) {
      throw StateError('restore exceeded five write pairs');
    }
    await super.write(
      serviceUUID,
      characteristicUUID,
      data,
      withResponse: withResponse,
      timeout: timeout,
    );
    if (characteristicUUID == Endpoint.writeToMMR.uuid &&
        address == BengleMmr.rearLedColor.address) {
      restorePasses++;
      _asleep = !_asleep;
      emitNotification(Endpoint.stateInfo, [_asleep ? 0x00 : 0x02, 0]);
      await pumpEventQueue();
    }
  }
}

class _UncertainPreviewTransport extends FakeBleTransport {
  final live = <int, int>{};
  int? failAfterWriteAddress;

  @override
  Future<void> write(
    String serviceUUID,
    String characteristicUUID,
    Uint8List data, {
    bool withResponse = true,
    Duration? timeout,
  }) async {
    await super.write(
      serviceUUID,
      characteristicUUID,
      data,
      withResponse: withResponse,
      timeout: timeout,
    );
    if (characteristicUUID == Endpoint.writeToMMR.uuid && data.length >= 8) {
      final address = (data[1] << 16) | (data[2] << 8) | data[3];
      if (address == 0x00803890 || address == 0x00803894) {
        live[address] = ByteData.sublistView(
          data,
          4,
          8,
        ).getUint32(0, Endian.little);
        if (address == failAfterWriteAddress) {
          throw TimeoutException('live write applied but acknowledgement lost');
        }
      }
    }
  }
}

class _PaletteTransport extends FakeBleTransport {
  final palette = <int, int>{};

  @override
  Future<void> write(
    String serviceUUID,
    String characteristicUUID,
    Uint8List data, {
    bool withResponse = true,
    Duration? timeout,
  }) async {
    if (characteristicUUID == Endpoint.writeToMMR.uuid && data.length >= 8) {
      final address = (data[1] << 16) | (data[2] << 8) | data[3];
      if ([0x00803898, 0x0080389C, 0x008038A0, 0x008038A4].contains(address)) {
        palette[address] = ByteData.sublistView(
          data,
          4,
          8,
        ).getUint32(0, Endian.little);
      }
    }
    await super.write(
      serviceUUID,
      characteristicUUID,
      data,
      withResponse: withResponse,
      timeout: timeout,
    );
  }
}

void main() {
  group('LedStripCapability', () {
    late FakeBleTransport transport;
    late _RawWriteBengle bengle;

    void queueStoredPalette() {
      transport.queueMmrResponseInt(BengleMmr.frontLedAwake, 0xFF8000);
      transport.queueMmrResponseInt(BengleMmr.frontLedSleep, 0x302010);
      transport.queueMmrResponseInt(BengleMmr.rearLedAwake, 0x00FF00);
      transport.queueMmrResponseInt(BengleMmr.rearLedSleep, 0x0000FF);
    }

    Future<void> connect({
      bool queuePalette = true,
      FakeBleTransport? deviceTransport,
    }) async {
      transport = deviceTransport ?? FakeBleTransport();
      bengle = _RawWriteBengle(transport: transport);
      transport.queueOnConnectResponses(v13Model: 128);
      if (queuePalette) {
        queueStoredPalette();
      }
      await bengle.onConnect();
      if (queuePalette) {
        queueStoredPalette();
      }
    }

    tearDown(() async {
      await bengle.disposeLedStrip();
      await transport.dispose();
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
        bengle = _RawWriteBengle(transport: transport);
        transport.queueOnConnectResponses(v13Model: 128);
        transport.queueMmrResponseInt(BengleMmr.frontLedAwake, 0x000000);
        transport.queueMmrResponseInt(BengleMmr.frontLedSleep, 0x000000);
        transport.queueMmrResponseInt(BengleMmr.rearLedAwake, 0xFFFFFF);
        transport.queueMmrResponseInt(BengleMmr.rearLedSleep, 0x000000);
        await bengle.onConnect();

        final state = (await bengle.getLedStripState())!;
        expect(state.frontSwitch.awake, const Color16(0xFF00, 0xF000, 0xC800));
        expect(
          state.frontSwitch.sleeping,
          const Color16(0x5500, 0x5000, 0x4300),
        );
      },
    );

    test(
      'failed hydration leaves the state null (no fabricated black)',
      () async {
        transport = FakeBleTransport();
        bengle = _RawWriteBengle(transport: transport);
        transport.queueOnConnectResponses(v13Model: 128);
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

    test('setLedStrip writes all four stored colours with 8-bit RGB', () async {
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

      final state = (await bengle.getLedStripState())!;
      expect(state.frontStrip.awake, const Color16(0xFF00, 0x8000, 0x0000));
      expect(state.frontSwitch.awake, const Color16(0xFF00, 0x8000, 0x0000));
    });

    List<FakeBleWrite> mmrWrites() => transport.writes
        .where((w) => w.characteristicUUID == Endpoint.writeToMMR.uuid)
        .toList();

    test(
      'saving restores every stored zone despite a stale palette cache',
      () async {
        final firmware = _PaletteTransport();
        await connect(deviceTransport: firmware);
        final held = (await bengle.getLedStripState())!;
        firmware.palette.addAll({
          0x00803898: 0x123456,
          0x008038A0: 0x234567,
          0x0080389C: 0x345678,
          0x008038A4: 0x456789,
        });
        transport.writes.clear();

        await bengle.setLedStrip(held);

        expect(firmware.palette, {
          0x00803898: 0xFF8000,
          0x008038A0: 0x302010,
          0x0080389C: 0x00FF00,
          0x008038A4: 0x0000FF,
        });
        final writes = mmrWrites();
        expect(writes, hasLength(4));
        expect(
          writes.map(
            (w) => (
              (w.data[1] << 16) | (w.data[2] << 8) | w.data[3],
              ByteData.sublistView(w.data, 4, 8).getUint32(0, Endian.little),
            ),
          ),
          [
            (0x00803898, 0xFF8000),
            (0x008038A0, 0x302010),
            (0x0080389C, 0x00FF00),
            (0x008038A4, 0x0000FF),
          ],
        );
      },
    );

    test('clear refreshes a cached palette after raw stored writes', () async {
      await connect();
      await bengle.previewLedStrip(
        front: const Color16(0x1100, 0x2200, 0x3300),
      );
      await bengle.rawWrite(BengleMmr.frontLedSleep, 0x123456);
      await bengle.rawWrite(BengleMmr.rearLedSleep, 0xABCDEF);
      transport.queueMmrResponseInt(BengleMmr.frontLedSleep, 0x123456);
      transport.queueMmrResponseInt(BengleMmr.rearLedSleep, 0xABCDEF);
      transport.writes.clear();

      await bengle.clearLedStripPreview();

      expect(
        mmrWrites().map(
          (w) => ByteData.sublistView(w.data, 4, 8).getUint32(0, Endian.little),
        ),
        [0x123456, 0xABCDEF],
      );
      expect(
        (await bengle.getLedStripState())!.frontStrip.sleeping,
        const Color16(0x1200, 0x3400, 0x5600),
      );
    });

    test(
      'clear writes both live registers despite a stale preview cache',
      () async {
        await connect();
        await bengle.previewLedStrip(
          front: const Color16(0x3000, 0x2000, 0x1000),
          back: const Color16(0, 0, 0xFF00),
        );
        await bengle.rawWrite(BengleMmr.frontLedColor, 0x123456);
        await bengle.rawWrite(BengleMmr.rearLedColor, 0xABCDEF);
        transport.writes.clear();

        await bengle.clearLedStripPreview();

        expect(
          mmrWrites().map(
            (w) => (
              (w.data[1] << 16) | (w.data[2] << 8) | w.data[3],
              ByteData.sublistView(w.data, 4, 8).getUint32(0, Endian.little),
            ),
          ),
          [(0x00803890, 0x302010), (0x00803894, 0x0000FF)],
        );
      },
    );

    for (final blockedAddress in [0x00803890, 0x00803894]) {
      for (final phases in [(0x02, 0x00), (0x00, 0x02)]) {
        test('clear reconciles phase ${phases.$1} to ${phases.$2} during '
            'write $blockedAddress', () async {
          final blocking = _BlockingPreviewTransport(blockedAddress);
          await connect(deviceTransport: blocking);
          transport.emitNotification(Endpoint.stateInfo, [phases.$1, 0]);
          await pumpEventQueue();
          transport.writes.clear();

          final clear = bengle.clearLedStripPreview();
          await blocking.writeStarted.future;
          transport.emitNotification(Endpoint.stateInfo, [phases.$2, 0]);
          await pumpEventQueue();
          blocking.releaseWrite.complete();
          await clear;

          final asleep = phases.$2 == 0x00;
          expect(
            mmrWrites().map(
              (w) => ByteData.sublistView(
                w.data,
                4,
                8,
              ).getUint32(0, Endian.little),
            ),
            [
              asleep ? 0xFF8000 : 0x302010,
              asleep ? 0x00FF00 : 0x0000FF,
              asleep ? 0x302010 : 0xFF8000,
              asleep ? 0x0000FF : 0x00FF00,
            ],
          );
        });
      }
    }

    test(
      'clear fails after five passes when the phase never settles',
      () async {
        final flapping = _FlappingPhaseTransport();
        await connect(deviceTransport: flapping);
        transport.emitNotification(Endpoint.stateInfo, [0x00, 0]);
        await pumpEventQueue();
        transport.writes.clear();

        await expectLater(
          bengle.clearLedStripPreview(),
          throwsA(
            isA<LedStripStateUnavailableException>().having(
              (error) => error.message,
              'message',
              contains('phase did not settle'),
            ),
          ),
        );

        expect(flapping.restorePasses, 5);
        expect(
          mmrWrites().map(
            (w) => (
              (w.data[1] << 16) | (w.data[2] << 8) | w.data[3],
              ByteData.sublistView(w.data, 4, 8).getUint32(0, Endian.little),
            ),
          ),
          List.generate(
            5,
            (pass) => [
              (
                BengleMmr.frontLedColor.address,
                pass.isEven ? 0x302010 : 0xFF8000,
              ),
              (
                BengleMmr.rearLedColor.address,
                pass.isEven ? 0x0000FF : 0x00FF00,
              ),
            ],
          ).expand((pair) => pair),
        );
      },
    );

    test('clear rejects failed refresh even with a cached palette', () async {
      await connect();
      transport.failMmrReadsForAddresses.add(BengleMmr.frontLedAwake.address);
      transport.writes.clear();

      await expectLater(
        bengle.clearLedStripPreview(),
        throwsA(isA<LedStripStateUnavailableException>()),
      );

      expect(mmrWrites(), isEmpty);
      expect(await bengle.getLedStripState(), isNull);
    });

    for (final front in [true, false]) {
      test('uncertain ${front ? 'front' : 'rear'} preview failure invalidates '
          'the previous colour', () async {
        final uncertain = _UncertainPreviewTransport();
        await connect(deviceTransport: uncertain);
        const original = Color16(0x1100, 0x2200, 0x3300);
        const changed = Color16(0x4400, 0x5500, 0x6600);
        Future<void> preview(Color16 color) => bengle.previewLedStrip(
          front: front ? color : null,
          back: front ? null : color,
        );
        final address = front ? 0x00803890 : 0x00803894;
        await preview(original);
        uncertain.failAfterWriteAddress = address;

        await expectLater(preview(changed), throwsA(isA<TimeoutException>()));
        expect(uncertain.live[address], 0x445566);
        uncertain.failAfterWriteAddress = null;
        transport.writes.clear();
        await preview(original);

        expect(mmrWrites(), hasLength(1));
        expect(uncertain.live[address], 0x112233);
      });
    }

    test('clear rehydrates a missing palette before restoring it', () async {
      final failing = FakeBleTransport();
      failing.failMmrReadsForAddresses.addAll([
        BengleMmr.frontLedAwake.address,
        BengleMmr.frontLedSleep.address,
        BengleMmr.rearLedAwake.address,
        BengleMmr.rearLedSleep.address,
      ]);
      await connect(queuePalette: false, deviceTransport: failing);
      failing.failMmrReadsForAddresses.clear();
      failing.queueMmrResponseInt(BengleMmr.frontLedAwake, 0xFF8000);
      failing.queueMmrResponseInt(BengleMmr.frontLedSleep, 0x302010);
      failing.queueMmrResponseInt(BengleMmr.rearLedAwake, 0x00FF00);
      failing.queueMmrResponseInt(BengleMmr.rearLedSleep, 0x0000FF);
      failing.writes.clear();

      await bengle.clearLedStripPreview();

      expect(
        mmrWrites().map(
          (w) => ByteData.sublistView(w.data, 4, 8).getUint32(0, Endian.little),
        ),
        [0x302010, 0x0000FF],
      );
      expect(await bengle.getLedStripState(), isNotNull);
    });

    test('clear uses stateInfo after a sleep without a new shot', () async {
      await connect();
      final snapshotSubscription = bengle.currentSnapshot.listen((_) {});
      addTearDown(snapshotSubscription.cancel);
      transport.emitNotification(Endpoint.stateInfo, [0x02, 0]);
      await pumpEventQueue();
      transport.emitNotification(Endpoint.bengleShotSample, Uint8List(28));
      await pumpEventQueue();
      transport.writes.clear();

      transport.emitNotification(Endpoint.stateInfo, [0x00, 0]);
      await pumpEventQueue();
      await bengle.clearLedStripPreview();

      expect(
        mmrWrites().map(
          (w) => ByteData.sublistView(w.data, 4, 8).getUint32(0, Endian.little),
        ),
        [0x302010, 0x0000FF],
      );
    });

    test(
      'clear rejects an unavailable palette instead of succeeding',
      () async {
        final failing = FakeBleTransport();
        failing.failMmrReadsForAddresses.addAll([
          BengleMmr.frontLedAwake.address,
          BengleMmr.frontLedSleep.address,
          BengleMmr.rearLedAwake.address,
          BengleMmr.rearLedSleep.address,
        ]);
        await connect(queuePalette: false, deviceTransport: failing);

        await expectLater(
          bengle.clearLedStripPreview(),
          throwsA(isA<LedStripStateUnavailableException>()),
        );
      },
    );

    test(
      'a preview frame that repeats the shown colour writes nothing',
      () async {
        await connect();
        const colour = Color16(0x1100, 0x2200, 0x3300);
        await bengle.previewLedStrip(front: colour);
        transport.writes.clear();

        await bengle.previewLedStrip(front: colour);

        expect(
          mmrWrites(),
          isEmpty,
          reason: 'a finger resting on one colour must stop writing',
        );
      },
    );

    test('a preview frame that moves is written', () async {
      await connect();
      await bengle.previewLedStrip(
        front: const Color16(0x1100, 0x2200, 0x3300),
      );
      transport.writes.clear();

      await bengle.previewLedStrip(
        front: const Color16(0x4400, 0x5500, 0x6600),
      );

      expect(mmrWrites().length, 1);
    });

    test('a save forgets what the strips were showing', () async {
      await connect();
      const colour = Color16(0x1100, 0x2200, 0x3300);
      await bengle.previewLedStrip(front: colour);
      await bengle.setLedStrip(
        LedStripState(
          frontStrip: ZoneLedState(
            awake: const Color16(0x9900, 0x9900, 0x9900),
            sleeping: Color16.off,
          ),
        ),
      );
      transport.writes.clear();

      await bengle.previewLedStrip(front: colour);

      expect(mmrWrites().length, 1);
    });

    Future<void> showPreviewPair() => bengle.previewLedStrip(
      front: const Color16(0x1100, 0x2200, 0x3300),
      back: const Color16(0x4400, 0x5500, 0x6600),
    );

    void expectPreviewPair() {
      expect(
        mmrWrites().map(
          (w) => (
            (w.data[1] << 16) | (w.data[2] << 8) | w.data[3],
            ByteData.sublistView(w.data, 4, 8).getUint32(0, Endian.little),
          ),
        ),
        [(0x00803890, 0x112233), (0x00803894, 0x445566)],
      );
    }

    for (final states in [
      [0x02, 0x00],
      [0x00, 0x02],
    ]) {
      test(
        'preview is resent after state transition ${states.join(' to ')}',
        () async {
          await connect();
          transport.writes.clear();
          transport.emitNotification(Endpoint.stateInfo, [states.first, 0]);
          await pumpEventQueue();
          await showPreviewPair();
          expectPreviewPair();
          transport.writes.clear();
          transport.emitNotification(Endpoint.stateInfo, [states.last, 0]);
          await pumpEventQueue();

          await showPreviewPair();

          expectPreviewPair();
        },
      );
    }

    test('unchanged awake phase keeps preview deduplication', () async {
      await connect();
      transport.writes.clear();
      transport.emitNotification(Endpoint.stateInfo, [0x02, 0]);
      await pumpEventQueue();
      await showPreviewPair();
      expectPreviewPair();
      transport.writes.clear();
      transport.emitNotification(Endpoint.stateInfo, [0x02, 0]);
      await pumpEventQueue();
      transport.emitNotification(Endpoint.stateInfo, [0x04, 0]);
      await pumpEventQueue();

      await showPreviewPair();

      expect(mmrWrites(), isEmpty);
    });

    test(
      'front preview completion cannot restore an invalidated cache',
      () async {
        final blocking = _BlockingPreviewTransport(0x00803890);
        await connect(deviceTransport: blocking);
        transport.writes.clear();
        const colour = Color16(0x1100, 0x2200, 0x3300);
        final preview = bengle.previewLedStrip(front: colour);
        await blocking.writeStarted.future;
        transport.emitNotification(Endpoint.stateInfo, [0x02, 0]);
        await pumpEventQueue();
        blocking.releaseWrite.complete();
        await preview;
        transport.writes.clear();

        await bengle.previewLedStrip(front: colour);

        expect(mmrWrites(), hasLength(1));
      },
    );

    test(
      'rear preview completion cannot restore an invalidated cache',
      () async {
        final blocking = _BlockingPreviewTransport(0x00803894);
        await connect(deviceTransport: blocking);
        transport.writes.clear();
        const colour = Color16(0x1100, 0x2200, 0x3300);
        final preview = bengle.previewLedStrip(back: colour);
        await blocking.writeStarted.future;
        transport.emitNotification(Endpoint.stateInfo, [0x02, 0]);
        await pumpEventQueue();
        blocking.releaseWrite.complete();
        await preview;
        transport.writes.clear();

        await bengle.previewLedStrip(back: colour);

        expect(mmrWrites(), hasLength(1));
      },
    );

    test('preview is resent after a partially failed stored save', () async {
      await connect();
      transport.writes.clear();
      await showPreviewPair();
      transport.failMmrWritesForAddresses.add(BengleMmr.rearLedAwake.address);
      await expectLater(
        bengle.setLedStrip(LedStripState()),
        throwsA(isA<StateError>()),
      );
      transport.failMmrWritesForAddresses.clear();
      transport.writes.clear();

      await showPreviewPair();

      expectPreviewPair();
    });

    test('preview is resent after LED capability reinitialization', () async {
      await connect();
      transport.writes.clear();
      await showPreviewPair();
      await bengle.disposeLedStrip();
      transport.queuePaletteHydrationResponses();
      await bengle.initLedStrip();
      transport.writes.clear();

      await showPreviewPair();

      expectPreviewPair();
    });

    test('non-byte-aligned 16-bit input is quantized in the cache', () async {
      await connect();
      transport.writes.clear();
      await bengle.setLedStrip(
        LedStripState(
          frontStrip: ZoneLedState(
            awake: const Color16(0x12FF, 0x3456, 0x78AB),
            sleeping: Color16.off,
          ),
          backStrip: ZoneLedState(awake: Color16.off, sleeping: Color16.off),
        ),
      );

      final state = (await bengle.getLedStripState())!;
      expect(
        state.frontStrip.awake,
        const Color16(0x1200, 0x3400, 0x7800),
        reason: 'low bytes are discarded exactly as the wire truncates them',
      );
    });

    test('failure at any palette write marks the state unknown', () async {
      await connect();
      expect(await bengle.getLedStripState(), isNotNull);

      const zones = [
        (BengleMmr.frontLedAwake, Color16(0xFF00, 0x0000, 0x0000)),
        (BengleMmr.frontLedSleep, Color16(0x0000, 0xFF00, 0x0000)),
        (BengleMmr.rearLedAwake, Color16(0x0000, 0x0000, 0xFF00)),
        (BengleMmr.rearLedSleep, Color16(0xFFFF, 0xFFFF, 0xFFFF)),
      ];
      for (final (mmr, color) in zones) {
        transport.failMmrWritesForAddresses.add(mmr.address);
        await expectLater(
          bengle.setLedStrip(
            LedStripState(
              frontStrip: ZoneLedState(awake: color, sleeping: color),
              backStrip: ZoneLedState(awake: color, sleeping: color),
            ),
          ),
          throwsA(isA<StateError>()),
        );
        transport.failMmrWritesForAddresses.clear();
        expect(
          await bengle.getLedStripState(),
          isNull,
          reason:
              'a partial palette write must not leave stale state '
              'served as authoritative',
        );
      }
    });

    test(
      'reset after a failed reload returns null (stale cache is not served)',
      () async {
        await connect();
        expect(await bengle.getLedStripState(), isNotNull);

        transport.failMmrReadsForAddresses.addAll([
          BengleMmr.frontLedAwake.address,
          BengleMmr.frontLedSleep.address,
          BengleMmr.rearLedAwake.address,
          BengleMmr.rearLedSleep.address,
        ]);
        final state = await bengle.resetLedStrip();
        expect(
          state,
          isNull,
          reason:
              'a failed reload must be distinguishable from success '
              'even when an older cached value exists',
        );
        expect(await bengle.getLedStripState(), isNull);
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
      transport.queueMmrResponseInt(BengleMmr.frontLedAwake, 0x0000FF);
      transport.queueMmrResponseInt(BengleMmr.frontLedSleep, 0x000000);
      transport.queueMmrResponseInt(BengleMmr.rearLedAwake, 0xFF0000);
      transport.queueMmrResponseInt(BengleMmr.rearLedSleep, 0x00FF00);

      final state = (await bengle.resetLedStrip())!;
      expect(state.frontStrip.awake, const Color16(0x0000, 0x0000, 0xFF00));
      expect(state.backStrip.awake, const Color16(0xFF00, 0x0000, 0x0000));
      expect(state.frontSwitch.sleeping, const Color16(0x5500, 0x5000, 0x4300));
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
