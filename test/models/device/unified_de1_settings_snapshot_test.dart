import 'dart:async';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/de1_interface.dart';
import 'package:reaprime/src/models/device/impl/de1/de1.models.dart';
import 'package:reaprime/src/models/device/impl/de1/unified_de1/unified_de1.dart';
import 'package:reaprime/src/models/device/transport/serial_port.dart';
import 'package:reaprime/src/models/errors.dart';

import '../../helpers/fake_ble_transport.dart';
import '../../helpers/fake_serial_transport.dart';

const _fanWords = [42, -7];
const _steamWords = [150];
const _flushWords = [123, 955, 100, 250];
const _purgeWords = [2, 1];
const _heaterWords = [25, 60, 980];
const _heaterTimeoutWords = [45];

int _mmrAddress(FakeBleWrite write) =>
    (write.data[1] << 16) | (write.data[2] << 8) | write.data[3];

List<FakeBleWrite> _mmrReads(FakeBleTransport transport) => transport.writes
    .where((w) => w.characteristicUUID == Endpoint.readFromMMR.uuid)
    .toList();

class _SilentSerialTransport extends SerialTransport {
  @override
  String get id => 'silent-serial-de1';

  @override
  String get name => 'SilentSerialDe1';

  @override
  Stream<ConnectionState> get connectionState => Stream.multi((controller) {
    controller.add(ConnectionState.connected);
    controller.close();
  });

  @override
  Future<void> connect() async {}

  @override
  Future<void> disconnect() async {}

  @override
  Stream<String> get readStream => const Stream.empty();

  @override
  Stream<Uint8List> get rawStream => const Stream.empty();

  @override
  Future<void> writeHexCommand(Uint8List command) async {}

  @override
  Future<void> writeCommand(String command) async {}

  @override
  Future<void> dispose() async {}
}

void _queueSettingsStubs(FakeBleTransport transport) {
  transport.queueMmrResponseWords(MMRItem.fanThreshold, _fanWords);
  transport.queueMmrResponseWords(MMRItem.targetSteamFlow, _steamWords);
  transport.queueMmrResponseWords(MMRItem.flushFlowRate, _flushWords);
  transport.queueMmrResponseInt(MMRItem.steamPurgeMode, _purgeWords[0]);
  transport.queueMmrResponseInt(MMRItem.allowUSBCharging, _purgeWords[1]);
  transport.queueMmrResponseWords(MMRItem.heaterUp1Flow, _heaterWords);
  transport.queueMmrResponseWords(
    MMRItem.heaterUp2Timeout,
    _heaterTimeoutWords,
  );
}

Future<UnifiedDe1> _connectedDe1(FakeBleTransport transport) async {
  final de1 = UnifiedDe1(transport: transport);
  transport.queueOnConnectResponses();
  await de1.onConnect();
  return de1;
}

Uint8List _mmrResponse(int address, List<int> words) {
  final data = ByteData(20)..setInt32(0, address, Endian.big);
  data.setUint8(0, switch (words.length) {
    1 => 0x04,
    2 => 0x08,
    3 => 0x0C,
    _ => 0x0A,
  });
  for (var i = 0; i < words.length; i++) {
    data.setInt32(4 + 4 * i, words[i], Endian.little);
  }
  return data.buffer.asUint8List();
}

String _hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

void main() {
  group('coalesced DE1 settings snapshots', () {
    late FakeBleTransport transport;
    late UnifiedDe1 de1;

    setUp(() async {
      transport = FakeBleTransport();
      de1 = await _connectedDe1(transport);
      transport.writes.clear();
    });

    tearDown(() {
      transport.dispose();
    });

    test('normal settings decode every word with its own scale', () async {
      _queueSettingsStubs(transport);

      final settings = await de1.getCoalescedMachineSettings();

      expect(settings.fanThreshold, 42);
      expect(settings.tankTempThreshold, -7);
      expect(settings.steamFlow, 150 * 0.01);
      expect(settings.flushFlow, 123 * 0.1);
      expect(settings.flushTemperature, 955 * 0.1);
      expect(settings.flushTimeout, 100 * 0.1);
      expect(settings.hotWaterFlow, 250 * 0.1);
      expect(settings.steamPurgeMode, 2);
      expect(settings.usbChargerMode, isTrue);
    });

    test(
      'normal settings use 2 multi-word plus 3 single-word requests',
      () async {
        _queueSettingsStubs(transport);

        await de1.getCoalescedMachineSettings();

        final reads = _mmrReads(transport);
        expect(reads, hasLength(5));
        expect(reads.map(_mmrAddress).toList(), [
          MMRItem.fanThreshold.address,
          MMRItem.targetSteamFlow.address,
          MMRItem.flushFlowRate.address,
          MMRItem.steamPurgeMode.address,
          MMRItem.allowUSBCharging.address,
        ]);
        expect(reads.map((w) => w.data[0]).toList(), [1, 0, 3, 0, 0]);
      },
    );

    test(
      'overlapping single and two-word reads keep their own responses',
      () async {
        transport.queueMmrResponseWords(MMRItem.targetSteamFlow, _steamWords);
        transport.queueMmrResponseWords(MMRItem.flushFlowRate, _flushWords);
        transport.queueMmrResponseInt(MMRItem.steamPurgeMode, 2);
        transport.queueMmrResponseInt(MMRItem.allowUSBCharging, 1);

        final single = de1.getFanThreshhold();
        final snapshot = de1.getCoalescedMachineSettings();
        await pumpEventQueue();
        transport.emitNotification(
          Endpoint.readFromMMR,
          _mmrResponse(MMRItem.fanThreshold.address, [51]),
        );
        expect(await single, 51);
        await pumpEventQueue();
        transport.emitNotification(
          Endpoint.readFromMMR,
          _mmrResponse(MMRItem.fanThreshold.address, [42, -7]),
        );

        final settings = await snapshot;
        expect(settings.tankTempThreshold, -7);
        expect(settings.fanThreshold, 42);
        expect(_mmrReads(transport).map((w) => w.data[0]), [0, 1, 0, 3, 0, 0]);
      },
    );

    test(
      'overlapping coalesced settings requests keep distinct snapshots',
      () async {
        final first = de1.getCoalescedMachineSettings();
        final second = de1.getCoalescedMachineSettings();
        final values = {
          MMRItem.fanThreshold.address: [42, -7],
          MMRItem.targetSteamFlow.address: [150],
          MMRItem.flushFlowRate.address: [123, 955, 100, 250],
          MMRItem.steamPurgeMode.address: [2],
          MMRItem.allowUSBCharging.address: [1],
        };
        final seen = <int, int>{};
        for (var i = 0; i < 10; i++) {
          await pumpEventQueue();
          final reads = _mmrReads(transport);
          expect(reads.length, greaterThan(i));
          final address = _mmrAddress(reads[i]);
          final ordinal = seen.update(address, (v) => v + 1, ifAbsent: () => 0);
          transport.emitNotification(
            Endpoint.readFromMMR,
            _mmrResponse(
              address,
              values[address]!.map((v) => v + ordinal).toList(),
            ),
          );
        }

        final a = await first;
        final b = await second;
        expect(b.tankTempThreshold, -6);
        expect(a.tankTempThreshold, -7);
        expect([a.fanThreshold, b.fanThreshold], [42, 43]);
        expect([a.steamFlow, b.steamFlow], [150 * 0.01, 151 * 0.01]);
        expect([a.flushFlow, b.flushFlow], [123 * 0.1, 124 * 0.1]);
        expect(
          [a.flushTemperature, b.flushTemperature],
          [955 * 0.1, 956 * 0.1],
        );
        expect([a.flushTimeout, b.flushTimeout], [100 * 0.1, 101 * 0.1]);
        expect([a.hotWaterFlow, b.hotWaterFlow], [250 * 0.1, 251 * 0.1]);
        expect([a.steamPurgeMode, b.steamPurgeMode], [2, 3]);
        expect([a.usbChargerMode, b.usbChargerMode], [true, false]);
        expect(_mmrReads(transport), hasLength(10));
        expect(_mmrReads(transport).map((w) => w.data[0]), [
          1,
          1,
          0,
          0,
          3,
          3,
          0,
          0,
          0,
          0,
        ]);
      },
    );

    test(
      'serial settings decode complete multi-word frames and frame requests',
      () async {
        final serial = FakeSerialTransport();
        final serialDe1 = UnifiedDe1(transport: serial);
        addTearDown(serialDe1.dispose);
        final connected = serialDe1.onConnect();
        for (final entry in {
          MMRItem.v13Model: 1,
          MMRItem.ghcInfo: 0,
          MMRItem.serialN: 12345,
          MMRItem.cpuFirmwareBuild: 1358,
          MMRItem.heaterV: 230,
          MMRItem.refillKitPresent: 0,
          MMRItem.calFlowEst: 1000,
        }.entries) {
          await pumpEventQueue();
          serial.injectSerial(
            '[E]${_hex(_mmrResponse(entry.key.address, [entry.value]))}\n',
          );
        }
        await connected;
        serial.writes.clear();
        final pending = serialDe1.getCoalescedMachineSettings();
        final exchanges = [
          (
            '<E>0180380800000000000000000000000000000000',
            '[E]088038082a000000f9ffffff0000000000000000\n',
          ),
          (
            '<E>0080382800000000000000000000000000000000',
            '[E]0480382896000000000000000000000000000000\n',
          ),
          (
            '<E>0380384000000000000000000000000000000000',
            '[E]0a8038407b000000bb03000064000000fa000000\n',
          ),
          (
            '<E>0080385000000000000000000000000000000000',
            '[E]0480385002000000000000000000000000000000\n',
          ),
          (
            '<E>0080385400000000000000000000000000000000',
            '[E]0480385401000000000000000000000000000000\n',
          ),
        ];
        for (var i = 0; i < exchanges.length; i++) {
          await pumpEventQueue();
          expect(
            serial.writes,
            exchanges.take(i + 1).map((e) => e.$1).toList(),
          );
          serial.injectSerial(exchanges[i].$2);
        }
        final settings = await pending;
        expect(settings.fanThreshold, 42);
        expect(settings.tankTempThreshold, -7);
        expect(settings.steamFlow, 150 * 0.01);
        expect(settings.flushFlow, 123 * 0.1);
        expect(settings.flushTemperature, 955 * 0.1);
        expect(settings.flushTimeout, 100 * 0.1);
        expect(settings.hotWaterFlow, 250 * 0.1);
        expect(settings.steamPurgeMode, 2);
        expect(settings.usbChargerMode, isTrue);
      },
    );

    test('advanced settings decode every word with its own scale', () async {
      _queueSettingsStubs(transport);

      final settings = await de1.getCoalescedAdvancedMachineSettings();

      expect(settings.heaterPhase1Flow, 25 * 0.1);
      expect(settings.heaterPhase2Flow, 60 * 0.1);
      expect(settings.heaterIdleTemp, 980 * 0.1);
      expect(settings.heaterPhase2Timeout, 45 * 0.1);
    });

    test(
      'advanced settings use 1 multi-word plus 1 single-word request',
      () async {
        _queueSettingsStubs(transport);

        await de1.getCoalescedAdvancedMachineSettings();

        final reads = _mmrReads(transport);
        expect(reads, hasLength(2));
        expect(reads.map(_mmrAddress).toList(), [
          MMRItem.heaterUp1Flow.address,
          MMRItem.heaterUp2Timeout.address,
        ]);
        expect(reads.map((w) => w.data[0]).toList(), [2, 0]);
      },
    );

    test('usb charger mode is false when the word is not 1', () async {
      transport.queueMmrResponseWords(MMRItem.fanThreshold, _fanWords);
      transport.queueMmrResponseWords(MMRItem.targetSteamFlow, _steamWords);
      transport.queueMmrResponseWords(MMRItem.flushFlowRate, _flushWords);
      transport.queueMmrResponseInt(MMRItem.steamPurgeMode, 2);
      transport.queueMmrResponseInt(MMRItem.allowUSBCharging, 2);

      final settings = await de1.getCoalescedMachineSettings();

      expect(settings.steamPurgeMode, 2);
      expect(settings.usbChargerMode, isFalse);
    });

    test('truncated multi-word notification throws, not zero-filled', () async {
      final pending = de1.getCoalescedMachineSettings();
      while (_mmrReads(transport).isEmpty) {
        await Future<void>.delayed(Duration.zero);
      }
      transport.emitNotification(Endpoint.readFromMMR, [
        0x01,
        0x80,
        0x38,
        0x08,
        0x2A,
        0x00,
        0x00,
        0x00,
      ]);

      await expectLater(pending, throwsA(isA<StateError>()));
    });

    test('missing multi-word response times out after retries', () {
      fakeAsync((async) {
        final serialDe1 = UnifiedDe1(transport: _SilentSerialTransport());
        Object? caught;
        captureSettingsError(serialDe1.getCoalescedMachineSettings(), (e) {
          caught = e;
        });
        async.elapse(const Duration(seconds: 30));
        expect(caught, isA<MmrTimeoutException>());
      });
    });

    test('single-word reads still return the first word only', () async {
      transport.queueMmrResponseInt(MMRItem.fanThreshold, 52);

      expect(await de1.getFanThreshhold(), 52);

      final reads = _mmrReads(transport);
      expect(reads, hasLength(1));
      expect(_mmrAddress(reads.single), MMRItem.fanThreshold.address);
      expect(reads.single.data[0], 0);
    });

    test('single-word reads tolerate oversized frames', () async {
      final pending = de1.getFanThreshhold();
      while (_mmrReads(transport).isEmpty) {
        await Future<void>.delayed(Duration.zero);
      }
      transport.emitNotification(Endpoint.readFromMMR, [
        0x04,
        0x80,
        0x38,
        0x08,
        0x34,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
      ]);

      expect(await pending, 52);
    });

    test('single-word reads reject short frames', () async {
      final pending = de1.getFanThreshhold();
      while (_mmrReads(transport).isEmpty) {
        await Future<void>.delayed(Duration.zero);
      }
      transport.emitNotification(Endpoint.readFromMMR, [
        0x04,
        0x80,
        0x38,
        0x08,
        0x34,
        0x00,
        0x00,
        0x00,
      ]);

      await expectLater(pending, throwsA(isA<StateError>()));
    });

    test('fake emits hardware-observed response headers per length', () async {
      final captured = <Uint8List>[];
      await transport.subscribe(
        de1ServiceUUID,
        Endpoint.readFromMMR.uuid,
        captured.add,
      );

      Future<int> headerForLength(int length, List<int> words) async {
        captured.clear();
        transport.queueMmrResponseWords(MMRItem.fanThreshold, words);
        final request = Uint8List(20);
        final view = ByteData.sublistView(request);
        view.setUint8(0, length);
        view.setUint8(1, 0x80);
        view.setUint8(2, 0x38);
        view.setUint8(3, 0x08);
        await transport.write(
          de1ServiceUUID,
          Endpoint.readFromMMR.uuid,
          request,
        );
        for (var i = 0; i < 10; i++) {
          await Future<void>.delayed(Duration.zero);
        }
        expect(captured, hasLength(1));
        return captured.single[0];
      }

      expect(await headerForLength(0, [42]), 0x04);
      expect(await headerForLength(1, [42, 43]), 0x08);
      expect(await headerForLength(2, [42, 43, 44]), 0x0C);
      expect(await headerForLength(3, [42, 43, 44, 45]), 0x0A);
    });
  });
}

Future<void> captureSettingsError(
  Future<De1MachineSettings> future,
  void Function(Object) onError,
) async {
  try {
    await future;
  } catch (e) {
    onError(e);
  }
}
