import 'dart:convert';
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/de1_controller.dart';
import 'package:reaprime/src/controllers/device_controller.dart';
import 'package:reaprime/src/controllers/workflow_controller.dart';
import 'package:reaprime/src/models/device/de1_interface.dart';
import 'package:reaprime/src/models/device/machine.dart';
import 'package:reaprime/src/models/device/impl/mock_de1/mock_de1.dart';
import 'package:reaprime/src/settings/machine_settings_store.dart';
import 'package:reaprime/src/settings/settings_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:reaprime/src/services/webserver_service.dart';
import 'package:shelf_plus/shelf_plus.dart';

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
  }) async {
    if (identity.isEmpty) return;
    final current = _settings[identity];
    _settings[identity] = MachineSettings(
      fanThreshold: fanThreshold ?? current?.fanThreshold,
      refillKitSetting: refillKitSetting ?? current?.refillKitSetting,
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
  late SettingsController settingsController;
  late TestScaleController scaleController;
  late MachineSettingsStore machineSettings;

  Future<void> wireWith(
    De1Interface? device, {
    MachineSettingsStore? persistedMachineSettings,
  }) async {
    final deviceController = DeviceController([MockDeviceDiscoveryService()]);
    await deviceController.initialize();
    machineSettings = persistedMachineSettings ?? _MemoryMachineSettingsStore();
    controller = De1Controller(
      controller: deviceController,
      machineSettings: persistedMachineSettings ?? machineSettings,
    );
    if (device != null) {
      await controller.connectToDe1(device);
    }

    final mockSettings = MockSettingsService();
    settingsController = SettingsController(mockSettings);
    await settingsController.loadSettings();

    final testScale = TestScale();
    scaleController = TestScaleController(testScale);
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

  Future<Response> post(String path, Object body) async => await handler(
    Request(
      'POST',
      Uri.parse('http://localhost$path'),
      body: jsonEncode(body),
      headers: {HttpHeaders.contentTypeHeader: 'application/json'},
    ),
  );

  Future<Response> delete(String path) async =>
      await handler(Request('DELETE', Uri.parse('http://localhost$path')));

  Future<Response> putNoBody(String path) async =>
      await handler(Request('PUT', Uri.parse('http://localhost$path')));

  group('GET /api/v1/machine/settings/advanced', () {
    test('returns heaterVoltage and refillKitSetting on MockDe1', () async {
      await wireWith(MockDe1());
      final res = await get('/api/v1/machine/settings/advanced');
      expect(res.statusCode, 200);
      final body = jsonDecode(await res.readAsString());
      expect(body['heaterVoltage'], isA<int>());
      expect(body['refillKitSetting'], isA<int>());
    });

    test('returns 500 when no DE1 connected', () async {
      await wireWith(null);
      final res = await get('/api/v1/machine/settings/advanced');
      expect(res.statusCode, 500);
    });
  });

  group('POST /api/v1/machine/settings/advanced', () {
    test('writes and reads back heaterVoltage', () async {
      final de1 = MockDe1();
      await wireWith(de1);

      final res = await post('/api/v1/machine/settings/advanced', {
        'heaterVoltage': 230,
      });
      expect(res.statusCode, 202);

      final read = await de1.getHeaterVoltage();
      expect(read, De1HeaterVoltage.v220);
    });

    test('writes and reads back refillKitSetting by name', () async {
      final de1 = MockDe1();
      await wireWith(de1);

      final res = await post('/api/v1/machine/settings/advanced', {
        'refillKitSetting': 1,
      });
      expect(res.statusCode, 202);

      final read = await de1.getRefillKitSettings();
      expect(read, De1RefillKitSettings.forceOn);
    });

    test('restores API settings after reconnecting the same machine', () async {
      final first = MockDe1(deviceId: 'persistent-machine');
      await wireWith(first);

      expect(
        (await post('/api/v1/machine/settings', {'fan': 42})).statusCode,
        202,
      );
      expect(
        (await post('/api/v1/machine/settings/advanced', {
          'refillKitSetting': 1,
        })).statusCode,
        202,
      );
      await first.disconnect();
      await Future<void>.delayed(Duration.zero);

      final second = MockDe1(deviceId: 'persistent-machine');
      await controller.connectToDe1(second);
      await controller.initSettled.firstWhere(
        (generation) => generation != null,
      );

      expect(await second.getFanThreshhold(), 42);
      expect(await second.getRefillKitSettings(), De1RefillKitSettings.forceOn);
    });

    test(
      'restores different settings independently for two machines',
      () async {
        final first = _SerialMockDe1(serial: 'first');
        await wireWith(first);
        await post('/api/v1/machine/settings', {'fan': 41});
        await post('/api/v1/machine/settings/advanced', {
          'refillKitSetting': 1,
        });

        final second = _SerialMockDe1(serial: 'second');
        await controller.connectToDe1(second);
        await controller.initSettled.firstWhere(
          (generation) => generation != null,
        );
        await post('/api/v1/machine/settings', {'fan': 42});
        await post('/api/v1/machine/settings/advanced', {
          'refillKitSetting': 0,
        });

        final firstAgain = _SerialMockDe1(serial: 'first');
        await controller.connectToDe1(firstAgain);
        await controller.initSettled.firstWhere(
          (generation) => generation != null,
        );
        expect(await firstAgain.getFanThreshhold(), 41);
        expect(
          await firstAgain.getRefillKitSettings(),
          De1RefillKitSettings.forceOn,
        );

        final secondAgain = _SerialMockDe1(serial: 'second');
        await controller.connectToDe1(secondAgain);
        await controller.initSettled.firstWhere(
          (generation) => generation != null,
        );
        expect(await secondAgain.getFanThreshhold(), 42);
        expect(
          await secondAgain.getRefillKitSettings(),
          De1RefillKitSettings.forceOff,
        );
      },
    );

    test('unknown identity uses defaults without a bucket', () async {
      final known = _SerialMockDe1(serial: 'known');
      await wireWith(known);
      await post('/api/v1/machine/settings', {'fan': 42});
      await post('/api/v1/machine/settings/advanced', {'refillKitSetting': 1});

      final unknown = _SerialMockDe1(serial: '0', deviceId: '');
      await controller.connectToDe1(unknown);
      await controller.initSettled.firstWhere(
        (generation) => generation != null,
      );
      expect(await unknown.getFanThreshhold(), 55);
      expect(await unknown.getRefillKitSettings(), De1RefillKitSettings.auto);
    });

    test('restores API settings through a reconstructed controller', () async {
      SharedPreferences.setMockInitialValues({});
      await wireWith(
        MockDe1(deviceId: 'restart-machine'),
        persistedMachineSettings: SharedPreferencesMachineSettingsStore(),
      );
      await post('/api/v1/machine/settings', {'fan': 41});
      await post('/api/v1/machine/settings/advanced', {'refillKitSetting': 0});

      await wireWith(
        MockDe1(deviceId: 'restart-machine'),
        persistedMachineSettings: SharedPreferencesMachineSettingsStore(),
      );
      await controller.initSettled.firstWhere(
        (generation) => generation != null,
      );
      expect(await controller.connectedDe1().getFanThreshhold(), 41);
      expect(
        await controller.connectedDe1().getRefillKitSettings(),
        De1RefillKitSettings.forceOff,
      );
    });

    test('round-trips through GET after write', () async {
      final de1 = MockDe1();
      await wireWith(de1);

      await post('/api/v1/machine/settings/advanced', {
        'heaterVoltage': 230,
        'refillKitSetting': '2',
      });

      final res = await get('/api/v1/machine/settings/advanced');
      expect(res.statusCode, 200);
      final body = jsonDecode(await res.readAsString());
      expect(body['heaterVoltage'], 230);
      expect(body['refillKitSetting'], 2);
    });

    test(
      'writes and reads back heaterPh2Timeout without disconnecting',
      () async {
        final de1 = MockDe1();
        await wireWith(de1);

        final res = await post('/api/v1/machine/settings/advanced', {
          'heaterPh2Timeout': 7.0,
        });
        expect(res.statusCode, 202);

        expect(await de1.getHeaterPhase2Timeout(), 7.0);
        expect(controller.connectedDe1OrNull, same(de1));
      },
    );

    test('rejects a refillKitSetting outside 0/1/2 with 400', () async {
      final de1 = MockDe1();
      await wireWith(de1);

      final res = await post('/api/v1/machine/settings/advanced', {
        'refillKitSetting': 7,
      });

      expect(res.statusCode, 400);
      expect(await de1.getRefillKitSettings(), De1RefillKitSettings.auto);
    });

    test('returns 500 when no DE1 connected', () async {
      await wireWith(null);
      final res = await post('/api/v1/machine/settings/advanced', {
        'heaterVoltage': 120,
      });
      expect(res.statusCode, 500);
    });

    test(
      'does not save a completed write under a replacement machine',
      () async {
        final first = _BlockingFanMock(serial: 'first');
        await wireWith(first);
        first.blockNextFanWrite();
        final write = controller.updateMachineSettings(fan: 44);
        await first.fanWriteStarted.future;

        final second = _SerialMockDe1(serial: 'second');
        await controller.connectToDe1(second);
        first.releaseFanWrite();
        await expectLater(write, throwsA(isA<StateError>()));

        final secondAgain = _SerialMockDe1(serial: 'second');
        await controller.connectToDe1(secondAgain);
        await controller.initSettled.firstWhere(
          (generation) => generation != null,
        );
        expect(await secondAgain.getFanThreshhold(), 55);
      },
    );
  });

  group('DELETE /api/v1/machine/settings/reset', () {
    test('returns 202 on MockDe1', () async {
      await wireWith(MockDe1());
      final res = await delete('/api/v1/machine/settings/reset');
      expect(res.statusCode, 202);
    });

    test('applies the baseline defaults to the mock', () async {
      final de1 = MockDe1();
      await wireWith(de1);

      final res = await delete('/api/v1/machine/settings/reset');
      expect(res.statusCode, 202);

      expect(await de1.getFanThreshhold(), 55);
      expect(await de1.getHeaterIdleTemp(), 95);
      expect(await de1.getHeaterPhase1Flow(), 2.0);
      expect(await de1.getHeaterPhase2Flow(), 4.0);
      expect(await de1.getHeaterPhase2Timeout(), 4.0);
      expect(await de1.getRefillKitSettings(), De1RefillKitSettings.auto);
      expect(await de1.getFlowEstimation(), 1.0);
      expect(await de1.getSteamPurgeMode(), 0);
      expect(controller.connectedDe1OrNull, same(de1));
    });

    test('returns 500 when no DE1 connected', () async {
      await wireWith(null);
      final res = await delete('/api/v1/machine/settings/reset');
      expect(res.statusCode, 500);
    });

    test('reset clears only the connected machine bucket', () async {
      final first = _SerialMockDe1(serial: 'first');
      await wireWith(first);
      await post('/api/v1/machine/settings', {'fan': 42});
      await post('/api/v1/machine/settings/advanced', {'refillKitSetting': 1});

      final second = _SerialMockDe1(serial: 'second');
      await controller.connectToDe1(second);
      await controller.initSettled.firstWhere(
        (generation) => generation != null,
      );
      await post('/api/v1/machine/settings', {'fan': 43});
      await post('/api/v1/machine/settings/advanced', {'refillKitSetting': 0});
      await delete('/api/v1/machine/settings/reset');

      final firstAgain = _SerialMockDe1(serial: 'first');
      await controller.connectToDe1(firstAgain);
      await controller.initSettled.firstWhere(
        (generation) => generation != null,
      );
      expect(await firstAgain.getFanThreshhold(), 42);
      expect(
        await firstAgain.getRefillKitSettings(),
        De1RefillKitSettings.forceOn,
      );

      final secondAgain = _SerialMockDe1(serial: 'second');
      await controller.connectToDe1(secondAgain);
      await controller.initSettled.firstWhere(
        (generation) => generation != null,
      );
      expect(await secondAgain.getFanThreshhold(), 55);
      expect(
        await secondAgain.getRefillKitSettings(),
        De1RefillKitSettings.auto,
      );
    });
  });

  group('PUT /api/v1/machine/state/espresso — blockOnNoScale', () {
    test(
      'allows espresso when blockOnNoScale=true and scale is connected',
      () async {
        await wireWith(MockDe1());
        await settingsController.setBlockOnNoScale(true);

        final res = await putNoBody('/api/v1/machine/state/espresso');
        expect(res.statusCode, 200);
      },
    );

    test(
      'blocks espresso when blockOnNoScale=true and scale disconnected',
      () async {
        await wireWith(MockDe1());
        await settingsController.setBlockOnNoScale(true);
        scaleController.simulateDisconnect();

        final res = await putNoBody('/api/v1/machine/state/espresso');
        expect(res.statusCode, 400);
        final body = jsonDecode(await res.readAsString());
        expect(body['type'], 'block_no_scale');
      },
    );

    test(
      'allows espresso when blockOnNoScale=false and scale disconnected',
      () async {
        await wireWith(MockDe1());
        scaleController.simulateDisconnect();

        final res = await putNoBody('/api/v1/machine/state/espresso');
        expect(res.statusCode, 200);
      },
    );

    test('non-espresso states are never blocked (steam)', () async {
      await wireWith(MockDe1());
      await settingsController.setBlockOnNoScale(true);
      scaleController.simulateDisconnect();

      final res = await putNoBody('/api/v1/machine/state/steam');
      expect(res.statusCode, 200);
    });
  });
}

class _SerialMockDe1 extends MockDe1 {
  _SerialMockDe1({required this.serial, super.deviceId = 'serial-machine'});

  final String serial;

  @override
  MachineInfo get machineInfo => MachineInfo(
    version: '1337',
    model: 'DE1Pro',
    serialNumber: serial,
    groupHeadControllerPresent: false,
    extra: {},
  );
}

class _BlockingFanMock extends _SerialMockDe1 {
  _BlockingFanMock({required super.serial});

  final fanWriteStarted = Completer<void>();
  final _releaseFanWrite = Completer<void>();
  bool _blockFanWrite = false;

  void blockNextFanWrite() => _blockFanWrite = true;

  void releaseFanWrite() => _releaseFanWrite.complete();

  @override
  Future<void> setFanThreshhold(int temp) async {
    if (_blockFanWrite) {
      _blockFanWrite = false;
      fanWriteStarted.complete();
      await _releaseFanWrite.future;
    }
    await super.setFanThreshhold(temp);
  }
}
