import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/de1_controller.dart';
import 'package:reaprime/src/controllers/device_controller.dart';
import 'package:reaprime/src/controllers/workflow_controller.dart';
import 'package:reaprime/src/models/device/impl/de1/de1.models.dart';
import 'package:reaprime/src/models/device/impl/bengle/bengle.dart';
import 'package:reaprime/src/models/device/impl/bengle/mock_bengle.dart';
import 'package:reaprime/src/models/device/impl/de1/unified_de1/unified_de1.dart';
import 'package:reaprime/src/models/device/impl/mock_de1/mock_de1.dart';
import 'package:reaprime/src/services/webserver_service.dart';
import 'package:reaprime/src/settings/settings_controller.dart';
import 'package:shelf_plus/shelf_plus.dart';

import '../../helpers/fake_ble_transport.dart';
import '../../helpers/fake_serial_transport.dart';
import '../../helpers/mock_device_discovery_service.dart';
import '../../helpers/mock_settings_service.dart';
import '../../helpers/test_scale.dart';
import '../../helpers/test_scale_controller.dart';
import '../../helpers/memory_machine_settings_store.dart';

Uint8List _serialMmrResponse(int address, List<int> values) {
  final data = ByteData(20)..setInt32(0, address, Endian.big);
  data.setUint8(0, values.length * 4);
  for (var i = 0; i < values.length; i++) {
    data.setInt32(4 + i * 4, values[i], Endian.little);
  }
  return data.buffer.asUint8List();
}

String _hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

void main() {
  late Handler handler;
  late De1Controller controller;
  late FakeBleTransport transport;
  late FakeSerialTransport serialTransport;

  Future<void> wireWithUnifiedDe1({
    bool bengle = false,
    String? bengleCoalescedSettings,
  }) async {
    final deviceController = DeviceController([MockDeviceDiscoveryService()]);
    await deviceController.initialize();
    controller = De1Controller(
      controller: deviceController,
      machineSettings: MemoryMachineSettingsStore(),
    );
    transport = FakeBleTransport();
    transport.queueOnConnectResponses(
      v13Model: bengle ? 128 : 1,
      cpuFirmwareBuild: bengle ? 472 : 1358,
    );
    transport.queuePaletteHydrationResponses();
    await controller.connectToDe1(
      bengle ? Bengle(transport: transport) : UnifiedDe1(transport: transport),
    );

    final settingsController = SettingsController(MockSettingsService());
    await settingsController.loadSettings();

    final testScale = TestScale();
    final scaleController = TestScaleController(testScale);
    final de1Handler = bengleCoalescedSettings == null
        ? De1Handler(
            controller: controller,
            settingsController: settingsController,
            scaleController: scaleController,
            workflowController: WorkflowController(),
          )
        : De1Handler(
            controller: controller,
            settingsController: settingsController,
            scaleController: scaleController,
            workflowController: WorkflowController(),
            bengleCoalescedSettings: bengleCoalescedSettings,
          );
    final app = Router().plus;
    de1Handler.addRoutes(app);
    handler = app.call;
  }

  Future<void> wireWithSerialBengle({String? bengleCoalescedSettings}) async {
    final deviceController = DeviceController([MockDeviceDiscoveryService()]);
    await deviceController.initialize();
    controller = De1Controller(
      controller: deviceController,
      machineSettings: MemoryMachineSettingsStore(),
    );
    serialTransport = FakeSerialTransport();
    addTearDown(serialTransport.dispose);
    final connecting = controller.connectToDe1(
      Bengle(transport: serialTransport),
    );

    Future<void> respondToMmr(int address, int value) async {
      final expectedWrites = serialTransport.writes.length + 1;
      for (
        var i = 0;
        i < 100 && serialTransport.writes.length < expectedWrites;
        i++
      ) {
        await pumpEventQueue();
      }
      expect(
        serialTransport.writes.length,
        greaterThanOrEqualTo(expectedWrites),
      );
      serialTransport.injectSerial(
        '[E]${_hex(_serialMmrResponse(address, [value]))}\n',
      );
    }

    for (final entry in {
      MMRItem.v13Model: 128,
      MMRItem.ghcInfo: 0,
      MMRItem.serialN: 12345,
      MMRItem.cpuFirmwareBuild: 472,
      MMRItem.heaterV: 230,
      MMRItem.refillKitPresent: 0,
      MMRItem.calFlowEst: 1000,
    }.entries) {
      await respondToMmr(entry.key.address, entry.value);
    }
    for (final address in [0x00803898, 0x008038A0, 0x0080389C, 0x008038A4]) {
      await respondToMmr(address, 0);
    }
    await connecting;

    final settingsController = SettingsController(MockSettingsService());
    await settingsController.loadSettings();
    final de1Handler = bengleCoalescedSettings == null
        ? De1Handler(
            controller: controller,
            settingsController: settingsController,
            scaleController: TestScaleController(TestScale()),
            workflowController: WorkflowController(),
          )
        : De1Handler(
            controller: controller,
            settingsController: settingsController,
            scaleController: TestScaleController(TestScale()),
            workflowController: WorkflowController(),
            bengleCoalescedSettings: bengleCoalescedSettings,
          );
    final app = Router().plus;
    de1Handler.addRoutes(app);
    handler = app.call;
    serialTransport.writes.clear();
  }

  Future<Response> get(String path) async =>
      await handler(Request('GET', Uri.parse('http://localhost$path')));

  List<FakeBleWrite> mmrReads() => transport.writes
      .where((w) => w.characteristicUUID == Endpoint.readFromMMR.uuid)
      .toList();

  int mmrAddress(FakeBleWrite write) =>
      (write.data[1] << 16) | (write.data[2] << 8) | write.data[3];

  Future<void> waitForSerialWrites(int count) async {
    for (var i = 0; i < 100 && serialTransport.writes.length < count; i++) {
      await pumpEventQueue();
    }
    expect(serialTransport.writes.length, greaterThanOrEqualTo(count));
  }

  Future<void> completeSerialReads(
    List<(MMRItem, int, List<int>)> expected,
  ) async {
    for (var i = 0; i < expected.length; i++) {
      await waitForSerialWrites(i + 1);
      final command = serialTransport.writes[i];
      expect(int.parse(command.substring(3, 5), radix: 16), expected[i].$2);
      expect(
        int.parse(command.substring(5, 11), radix: 16),
        expected[i].$1.address,
      );
      serialTransport.injectSerial(
        '[E]${_hex(_serialMmrResponse(expected[i].$1.address, expected[i].$3))}\n',
      );
    }
  }

  group('GET /api/v1/machine/settings over coalesced MMR reads', () {
    test('returns the same keys and values with 5 requests', () async {
      await wireWithUnifiedDe1();
      transport.queueMmrResponseWords(MMRItem.fanThreshold, [42, -7]);
      transport.queueMmrResponseWords(MMRItem.targetSteamFlow, [150]);
      transport.queueMmrResponseWords(MMRItem.flushFlowRate, [
        123,
        955,
        100,
        250,
      ]);
      transport.queueMmrResponseInt(MMRItem.steamPurgeMode, 2);
      transport.queueMmrResponseInt(MMRItem.allowUSBCharging, 1);
      transport.writes.clear();

      final res = await get('/api/v1/machine/settings');

      expect(res.statusCode, 200);
      final body = jsonDecode(await res.readAsString()) as Map<String, dynamic>;
      expect(body, {
        'fan': 42,
        'usb': true,
        'flushTemp': 955 * 0.1,
        'flushTimeout': 100 * 0.1,
        'flushFlow': 123 * 0.1,
        'hotWaterFlow': 250 * 0.1,
        'steamFlow': 150 * 0.01,
        'tankTemp': -7,
        'steamPurgeMode': 2,
      });

      final reads = mmrReads();
      expect(reads, hasLength(5));
      expect(reads.map(mmrAddress).toList(), [
        0x00803808,
        0x00803828,
        0x00803840,
        0x00803850,
        0x00803854,
      ]);
      expect(reads.map((w) => w.data[0]).toList(), [1, 0, 3, 0, 0]);
    });

    test('Bengle BLE omitted selector defaults to 5 normal reads', () async {
      await wireWithUnifiedDe1(bengle: true);
      transport.queueMmrResponseWords(MMRItem.fanThreshold, [42, -7]);
      transport.queueMmrResponseInt(MMRItem.tankTemp, -7);
      transport.queueMmrResponseInt(MMRItem.flushTemp, 955);
      transport.queueMmrResponseInt(MMRItem.flushTimeout, 100);
      transport.queueMmrResponseInt(MMRItem.hotWaterFlowRate, 250);
      transport.queueMmrResponseWords(MMRItem.targetSteamFlow, [150]);
      transport.queueMmrResponseWords(MMRItem.flushFlowRate, [
        123,
        955,
        100,
        250,
      ]);
      transport.queueMmrResponseInt(MMRItem.steamPurgeMode, 2);
      transport.queueMmrResponseInt(MMRItem.allowUSBCharging, 1);
      transport.writes.clear();

      final res = await get('/api/v1/machine/settings');

      expect(res.statusCode, 200);
      expect(jsonDecode(await res.readAsString()), {
        'fan': 42,
        'usb': true,
        'flushTemp': 955 * 0.1,
        'flushTimeout': 100 * 0.1,
        'flushFlow': 123 * 0.1,
        'hotWaterFlow': 250 * 0.1,
        'steamFlow': 150 * 0.01,
        'tankTemp': -7,
        'steamPurgeMode': 2,
      });
      expect(mmrReads().map((w) => w.data[0]), [1, 0, 3, 0, 0]);
      expect(mmrReads().map(mmrAddress), [
        MMRItem.fanThreshold.address,
        MMRItem.targetSteamFlow.address,
        MMRItem.flushFlowRate.address,
        MMRItem.steamPurgeMode.address,
        MMRItem.allowUSBCharging.address,
      ]);
    });

    test(
      'Bengle BLE empty selector keeps normal settings sequential',
      () async {
        await wireWithUnifiedDe1(bengle: true, bengleCoalescedSettings: '');
        transport.queueMmrResponseInt(MMRItem.fanThreshold, 42);
        transport.queueMmrResponseInt(MMRItem.allowUSBCharging, 1);
        transport.queueMmrResponseInt(MMRItem.flushTemp, 955);
        transport.queueMmrResponseInt(MMRItem.flushTimeout, 100);
        transport.queueMmrResponseInt(MMRItem.flushFlowRate, 123);
        transport.queueMmrResponseInt(MMRItem.hotWaterFlowRate, 250);
        transport.queueMmrResponseInt(MMRItem.targetSteamFlow, 150);
        transport.queueMmrResponseInt(MMRItem.tankTemp, -7);
        transport.queueMmrResponseInt(MMRItem.steamPurgeMode, 2);
        transport.writes.clear();

        final res = await get('/api/v1/machine/settings');

        expect(res.statusCode, 200);
        expect(jsonDecode(await res.readAsString()), {
          'fan': 42,
          'usb': true,
          'flushTemp': 955 * 0.1,
          'flushTimeout': 100 * 0.1,
          'flushFlow': 123 * 0.1,
          'hotWaterFlow': 250 * 0.1,
          'steamFlow': 150 * 0.01,
          'tankTemp': -7,
          'steamPurgeMode': 2,
        });
        expect(mmrReads().map((w) => w.data[0]), List.filled(9, 0));
        expect(mmrReads().map(mmrAddress), [
          MMRItem.fanThreshold.address,
          MMRItem.allowUSBCharging.address,
          MMRItem.flushTemp.address,
          MMRItem.flushTimeout.address,
          MMRItem.flushFlowRate.address,
          MMRItem.hotWaterFlowRate.address,
          MMRItem.targetSteamFlow.address,
          MMRItem.tankTemp.address,
          MMRItem.steamPurgeMode.address,
        ]);
      },
    );

    for (final device in [MockDe1(), MockBengle()]) {
      test('falls back to individual getters on ${device.name}', () async {
        final deviceController = DeviceController([
          MockDeviceDiscoveryService(),
        ]);
        await deviceController.initialize();
        controller = De1Controller(
          controller: deviceController,
          machineSettings: MemoryMachineSettingsStore(),
        );
        await controller.connectToDe1(device);
        final settingsController = SettingsController(MockSettingsService());
        await settingsController.loadSettings();
        final de1Handler = De1Handler(
          controller: controller,
          settingsController: settingsController,
          scaleController: TestScaleController(TestScale()),
          workflowController: WorkflowController(),
          bengleCoalescedSettings: 'fanTank,flush,heater,purgeUsb',
        );
        final app = Router().plus;
        de1Handler.addRoutes(app);
        handler = app.call;

        final res = await get('/api/v1/machine/settings');

        expect(res.statusCode, 200);
        final body =
            jsonDecode(await res.readAsString()) as Map<String, dynamic>;
        expect(body.keys.toSet(), {
          'fan',
          'usb',
          'flushTemp',
          'flushTimeout',
          'flushFlow',
          'hotWaterFlow',
          'steamFlow',
          'tankTemp',
          'steamPurgeMode',
        });
        expect(body['fan'], isA<int>());
        expect(body['usb'], false);
      });
    }
  });

  test(
    'serial Bengle omitted selector coalesces the measured normal groups',
    () async {
      await wireWithSerialBengle();
      final pending = get('/api/v1/machine/settings');
      await completeSerialReads([
        (MMRItem.fanThreshold, 1, [42, -7]),
        (MMRItem.targetSteamFlow, 0, [150]),
        (MMRItem.flushFlowRate, 3, [123, 955, 100, 250]),
        (MMRItem.steamPurgeMode, 0, [2]),
        (MMRItem.allowUSBCharging, 0, [1]),
      ]);
      final res = await pending;

      expect(serialTransport.writes, hasLength(5));
      expect(res.statusCode, 200);
      expect(jsonDecode(await res.readAsString()), {
        'fan': 42,
        'usb': true,
        'flushTemp': 955 * 0.1,
        'flushTimeout': 100 * 0.1,
        'flushFlow': 123 * 0.1,
        'hotWaterFlow': 250 * 0.1,
        'steamFlow': 150 * 0.01,
        'tankTemp': -7,
        'steamPurgeMode': 2,
      });
    },
  );

  for (final selector in [
    'fanTank',
    ' fanTank , purgeUsb , unknown, fanTank , ',
  ]) {
    test(
      'serial Bengle $selector selector keeps other groups sequential',
      () async {
        await wireWithSerialBengle(bengleCoalescedSettings: selector);
        final pending = get('/api/v1/machine/settings');
        await completeSerialReads([
          (MMRItem.fanThreshold, 1, [42, -7]),
          (MMRItem.targetSteamFlow, 0, [150]),
          (MMRItem.flushFlowRate, 0, [123]),
          (MMRItem.flushTemp, 0, [955]),
          (MMRItem.flushTimeout, 0, [100]),
          (MMRItem.hotWaterFlowRate, 0, [250]),
          (MMRItem.steamPurgeMode, 0, [2]),
          (MMRItem.allowUSBCharging, 0, [1]),
        ]);
        final res = await pending;

        expect(res.statusCode, 200);
        expect(serialTransport.writes, hasLength(8));
        expect(jsonDecode(await res.readAsString()), containsPair('usb', true));
      },
    );
  }

  test(
    'serial Bengle heater-only selector leaves normal reads sequential',
    () async {
      await wireWithSerialBengle(bengleCoalescedSettings: 'heater');
      final normal = get('/api/v1/machine/settings');
      await completeSerialReads([
        (MMRItem.fanThreshold, 0, [42]),
        (MMRItem.allowUSBCharging, 0, [1]),
        (MMRItem.flushTemp, 0, [955]),
        (MMRItem.flushTimeout, 0, [100]),
        (MMRItem.flushFlowRate, 0, [123]),
        (MMRItem.hotWaterFlowRate, 0, [250]),
        (MMRItem.targetSteamFlow, 0, [150]),
        (MMRItem.tankTemp, 0, [-7]),
        (MMRItem.steamPurgeMode, 0, [2]),
      ]);
      expect((await normal).statusCode, 200);

      serialTransport.writes.clear();
      final advanced = get('/api/v1/machine/settings/advanced');
      await completeSerialReads([
        (MMRItem.heaterUp1Flow, 2, [25, 60, 980]),
        (MMRItem.heaterUp2Timeout, 0, [45]),
      ]);
      final res = await advanced;

      expect(res.statusCode, 200);
      expect(serialTransport.writes, hasLength(2));
      expect(
        jsonDecode(await res.readAsString()),
        containsPair('heaterPh1Flow', 2.5),
      );
    },
  );

  for (final selector in ['', 'unknown', 'purgeUsb']) {
    test(
      'serial Bengle keeps normal settings sequential for ${selector.isEmpty ? 'empty' : selector} selector',
      () async {
        await wireWithSerialBengle(bengleCoalescedSettings: selector);
        final expected = [
          (MMRItem.fanThreshold, 42),
          (MMRItem.allowUSBCharging, 1),
          (MMRItem.flushTemp, 955),
          (MMRItem.flushTimeout, 100),
          (MMRItem.flushFlowRate, 123),
          (MMRItem.hotWaterFlowRate, 250),
          (MMRItem.targetSteamFlow, 150),
          (MMRItem.tankTemp, -7),
          (MMRItem.steamPurgeMode, 2),
        ];
        final pending = get('/api/v1/machine/settings');
        for (var i = 0; i < expected.length; i++) {
          await waitForSerialWrites(i + 1);
          final command = serialTransport.writes[i];
          expect(int.parse(command.substring(3, 5), radix: 16), 0);
          expect(
            int.parse(command.substring(5, 11), radix: 16),
            expected[i].$1.address,
          );
          serialTransport.injectSerial(
            '[E]${_hex(_serialMmrResponse(expected[i].$1.address, [expected[i].$2]))}\n',
          );
        }
        final res = await pending;

        expect(res.statusCode, 200);
        expect(jsonDecode(await res.readAsString()), {
          'fan': 42,
          'usb': true,
          'flushTemp': 955 * 0.1,
          'flushTimeout': 100 * 0.1,
          'flushFlow': 123 * 0.1,
          'hotWaterFlow': 250 * 0.1,
          'steamFlow': 150 * 0.01,
          'tankTemp': -7,
          'steamPurgeMode': 2,
        });
      },
    );
  }

  test(
    'serial Bengle empty selector keeps advanced reads sequential',
    () async {
      await wireWithSerialBengle(bengleCoalescedSettings: '');
      final pending = get('/api/v1/machine/settings/advanced');
      await completeSerialReads([
        (MMRItem.heaterUp1Flow, 0, [25]),
        (MMRItem.heaterUp2Flow, 0, [60]),
        (MMRItem.waterHeaterIdleTemp, 0, [980]),
        (MMRItem.heaterUp2Timeout, 0, [45]),
      ]);
      final res = await pending;

      expect(res.statusCode, 200);
      expect(serialTransport.writes, hasLength(4));
      expect(
        jsonDecode(await res.readAsString()),
        containsPair('heaterPh2Timeout', 4.5),
      );
    },
  );

  group('GET /api/v1/machine/settings/advanced over coalesced MMR reads', () {
    test('serial Bengle omitted selector coalesces heater settings', () async {
      await wireWithSerialBengle();
      final pending = get('/api/v1/machine/settings/advanced');
      await completeSerialReads([
        (MMRItem.heaterUp1Flow, 2, [25, 60, 980]),
        (MMRItem.heaterUp2Timeout, 0, [45]),
      ]);
      final res = await pending;

      expect(res.statusCode, 200);
      expect(jsonDecode(await res.readAsString()), {
        'heaterPh1Flow': 25 * 0.1,
        'heaterPh2Flow': 60 * 0.1,
        'heaterIdleTemp': 980 * 0.1,
        'heaterPh2Timeout': 45 * 0.1,
        'heaterVoltage': 230,
        'refillKitSetting': 2,
      });
    });

    test('Bengle BLE omitted selector defaults to 2 advanced reads', () async {
      await wireWithUnifiedDe1(bengle: true);
      transport.queueMmrResponseWords(MMRItem.heaterUp1Flow, [25, 60, 980]);
      transport.queueMmrResponseInt(MMRItem.heaterUp2Flow, 60);
      transport.queueMmrResponseInt(MMRItem.waterHeaterIdleTemp, 980);
      transport.queueMmrResponseWords(MMRItem.heaterUp2Timeout, [45]);
      transport.writes.clear();

      final res = await get('/api/v1/machine/settings/advanced');

      expect(res.statusCode, 200);
      expect(jsonDecode(await res.readAsString()), {
        'heaterPh1Flow': 25 * 0.1,
        'heaterPh2Flow': 60 * 0.1,
        'heaterIdleTemp': 980 * 0.1,
        'heaterPh2Timeout': 45 * 0.1,
        'heaterVoltage': 230,
        'refillKitSetting': 2,
      });
      expect(mmrReads().map((w) => w.data[0]), [2, 0]);
      expect(mmrReads().map(mmrAddress), [
        MMRItem.heaterUp1Flow.address,
        MMRItem.heaterUp2Timeout.address,
      ]);
    });

    test(
      'Bengle BLE empty selector keeps advanced settings sequential',
      () async {
        await wireWithUnifiedDe1(bengle: true, bengleCoalescedSettings: '');
        transport.queueMmrResponseWords(MMRItem.heaterUp1Flow, [25, 60, 980]);
        transport.queueMmrResponseInt(MMRItem.heaterUp2Flow, 60);
        transport.queueMmrResponseInt(MMRItem.waterHeaterIdleTemp, 980);
        transport.queueMmrResponseInt(MMRItem.heaterUp2Timeout, 45);
        transport.writes.clear();

        final res = await get('/api/v1/machine/settings/advanced');

        expect(res.statusCode, 200);
        expect(jsonDecode(await res.readAsString()), {
          'heaterPh1Flow': 25 * 0.1,
          'heaterPh2Flow': 60 * 0.1,
          'heaterIdleTemp': 980 * 0.1,
          'heaterPh2Timeout': 45 * 0.1,
          'heaterVoltage': 230,
          'refillKitSetting': 2,
        });
        expect(mmrReads().map((w) => w.data[0]), List.filled(4, 0));
        expect(mmrReads().map(mmrAddress), [
          MMRItem.heaterUp1Flow.address,
          MMRItem.heaterUp2Flow.address,
          MMRItem.waterHeaterIdleTemp.address,
          MMRItem.heaterUp2Timeout.address,
        ]);
      },
    );

    test('returns the same keys and values with 2 requests', () async {
      await wireWithUnifiedDe1();
      transport.queueMmrResponseWords(MMRItem.heaterUp1Flow, [25, 60, 980]);
      transport.queueMmrResponseWords(MMRItem.heaterUp2Timeout, [45]);
      transport.writes.clear();

      final res = await get('/api/v1/machine/settings/advanced');

      expect(res.statusCode, 200);
      final body = jsonDecode(await res.readAsString()) as Map<String, dynamic>;
      expect(body, {
        'heaterPh1Flow': 25 * 0.1,
        'heaterPh2Flow': 60 * 0.1,
        'heaterIdleTemp': 980 * 0.1,
        'heaterPh2Timeout': 45 * 0.1,
        'heaterVoltage': 230,
        'refillKitSetting': 2,
      });

      final reads = mmrReads();
      expect(reads, hasLength(2));
      expect(reads.map(mmrAddress).toList(), [0x00803810, 0x00803838]);
      expect(reads.map((w) => w.data[0]).toList(), [2, 0]);
    });
  });
}
