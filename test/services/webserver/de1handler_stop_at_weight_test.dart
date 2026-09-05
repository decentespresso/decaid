import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/de1_controller.dart';
import 'package:reaprime/src/controllers/device_controller.dart';
import 'package:reaprime/src/controllers/workflow_controller.dart';
import 'package:reaprime/src/settings/settings_controller.dart';
import 'package:reaprime/src/models/device/de1_interface.dart';
import 'package:reaprime/src/models/device/impl/bengle/mock_bengle.dart';
import 'package:reaprime/src/models/device/impl/mock_de1/mock_de1.dart';
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

  group('GET /api/v1/machine/stopAtWeight', () {
    test('200 + the firmware target in grams', () async {
      final bengle = MockBengle();
      await wireWith(bengle);
      await bengle.setStopAtWeightTarget(42.5);

      final res = await get('/api/v1/machine/stopAtWeight');
      expect(res.statusCode, 200);
      final body = jsonDecode(await res.readAsString());
      expect(body['grams'], 42.5);
    });

    test('reports 0 when stop-at-weight is disabled in firmware', () async {
      final bengle = MockBengle();
      await wireWith(bengle);

      final res = await get('/api/v1/machine/stopAtWeight');
      expect(res.statusCode, 200);
      final body = jsonDecode(await res.readAsString());
      expect(body['grams'], 0.0);
    });

    test('404 on plain DE1', () async {
      await wireWith(MockDe1());
      final res = await get('/api/v1/machine/stopAtWeight');
      expect(res.statusCode, 404);
    });
  });
}
