import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/de1_controller.dart';
import 'package:reaprime/src/controllers/device_controller.dart';
import 'package:reaprime/src/controllers/workflow_controller.dart';
import 'package:reaprime/src/models/device/de1_interface.dart';
import 'package:reaprime/src/models/device/impl/de1/de1.models.dart';
import 'package:reaprime/src/models/device/impl/bengle/bengle.dart';
import 'package:reaprime/src/models/device/impl/bengle/mock_bengle.dart';
import 'package:reaprime/src/models/device/impl/de1/unified_de1/unified_de1.dart';
import 'package:reaprime/src/models/device/impl/mock_de1/mock_de1.dart';
import 'package:reaprime/src/services/webserver_service.dart';
import 'package:reaprime/src/settings/machine_settings_store.dart';
import 'package:reaprime/src/settings/settings_controller.dart';
import 'package:shelf_plus/shelf_plus.dart';

import '../../helpers/fake_ble_transport.dart';
import '../../helpers/mock_device_discovery_service.dart';
import '../../helpers/mock_settings_service.dart';
import '../../helpers/test_scale.dart';
import '../../helpers/test_scale_controller.dart';

class _MemoryMachineSettingsStore implements MachineSettingsStore {
  final Map<String, MachineSettings> _settings = {};

  @override
  Future<MachineSettings?> read(String identity) async => _settings[identity];

  @override
  Future<void> update(
    String identity, {
    int? fanThreshold,
    De1RefillKitSettings? refillKitSetting,
    double? flowCalibration,
  }) async {
    if (identity.isEmpty) return;
    final current = _settings[identity];
    _settings[identity] = MachineSettings(
      fanThreshold: fanThreshold ?? current?.fanThreshold,
      refillKitSetting: refillKitSetting ?? current?.refillKitSetting,
      flowCalibration: flowCalibration ?? current?.flowCalibration,
    );
  }

  @override
  Future<void> clearExceptFlowCalibration(String identity) async {
    final current = _settings[identity];
    if (current == null) return;
    _settings[identity] = MachineSettings(
      flowCalibration: current.flowCalibration,
    );
  }

  @override
  Future<void> clear(String identity) async {
    _settings.remove(identity);
  }
}

void main() {
  late Handler handler;
  late De1Controller controller;
  late FakeBleTransport transport;

  Future<void> wireWithUnifiedDe1({bool bengle = false}) async {
    final deviceController = DeviceController([MockDeviceDiscoveryService()]);
    await deviceController.initialize();
    controller = De1Controller(
      controller: deviceController,
      machineSettings: _MemoryMachineSettingsStore(),
    );
    transport = FakeBleTransport();
    transport.queueOnConnectResponses(v13Model: bengle ? 128 : 1);
    transport.queuePaletteHydrationResponses();
    await controller.connectToDe1(
      bengle ? Bengle(transport: transport) : UnifiedDe1(transport: transport),
    );

    final settingsController = SettingsController(MockSettingsService());
    await settingsController.loadSettings();

    final testScale = TestScale();
    final scaleController = TestScaleController(testScale);
    final de1Handler = De1Handler(
      controller: controller,
      settingsController: settingsController,
      scaleController: scaleController,
      workflowController: WorkflowController(),
    );
    final app = Router().plus;
    de1Handler.addRoutes(app);
    handler = app.call;
  }

  Future<Response> get(String path) async =>
      await handler(Request('GET', Uri.parse('http://localhost$path')));

  List<FakeBleWrite> mmrReads() => transport.writes
      .where((w) => w.characteristicUUID == Endpoint.readFromMMR.uuid)
      .toList();

  int mmrAddress(FakeBleWrite write) =>
      (write.data[1] << 16) | (write.data[2] << 8) | write.data[3];

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
      // Purge pair stays single-word: firmware zeroes these words in
      // multi-word responses (verified on hardware).
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

    test(
      'Bengle uses nine sequential reads with identical normal JSON',
      () async {
        await wireWithUnifiedDe1(bengle: true);
        transport.queueMmrResponseWords(MMRItem.fanThreshold, [42, -7]);
        transport.queueMmrResponseInt(MMRItem.tankTemp, -7);
        transport.queueMmrResponseInt(MMRItem.targetSteamFlow, 150);
        transport.queueMmrResponseWords(MMRItem.flushFlowRate, [
          123,
          955,
          100,
          250,
        ]);
        transport.queueMmrResponseInt(MMRItem.flushTemp, 955);
        transport.queueMmrResponseInt(MMRItem.flushTimeout, 100);
        transport.queueMmrResponseInt(MMRItem.hotWaterFlowRate, 250);
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
          machineSettings: _MemoryMachineSettingsStore(),
        );
        await controller.connectToDe1(device);
        final settingsController = SettingsController(MockSettingsService());
        await settingsController.loadSettings();
        final de1Handler = De1Handler(
          controller: controller,
          settingsController: settingsController,
          scaleController: TestScaleController(TestScale()),
          workflowController: WorkflowController(),
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
        // Startup defaults may have adjusted the fan threshold; the fallback
        // only promises the same keys and value types.
        expect(body['fan'], isA<int>());
        expect(body['usb'], false);
      });
    }
  });

  group('GET /api/v1/machine/settings/advanced over coalesced MMR reads', () {
    test(
      'Bengle uses four sequential reads with identical advanced JSON',
      () async {
        await wireWithUnifiedDe1(bengle: true);
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
