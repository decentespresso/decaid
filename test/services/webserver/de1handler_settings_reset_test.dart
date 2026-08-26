import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/de1_controller.dart';
import 'package:reaprime/src/controllers/device_controller.dart';
import 'package:reaprime/src/controllers/workflow_controller.dart';
import 'package:reaprime/src/models/device/de1_interface.dart';
import 'package:reaprime/src/models/device/impl/mock_de1/mock_de1.dart';
import 'package:reaprime/src/settings/settings_controller.dart';
import 'package:reaprime/src/services/webserver_service.dart';
import 'package:shelf_plus/shelf_plus.dart';

import '../../helpers/mock_device_discovery_service.dart';
import '../../helpers/mock_settings_service.dart';
import '../../helpers/test_scale.dart';
import '../../helpers/test_scale_controller.dart';

void main() {
  late Handler handler;
  late De1Controller controller;
  late SettingsController settingsController;
  late TestScaleController scaleController;

  Future<void> wireWith(De1Interface? device) async {
    final deviceController = DeviceController([MockDeviceDiscoveryService()]);
    await deviceController.initialize();
    controller = De1Controller(controller: deviceController);
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
