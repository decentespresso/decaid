import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/de1_controller.dart';
import 'package:reaprime/src/controllers/device_controller.dart';
import 'package:reaprime/src/controllers/workflow_controller.dart';
import 'package:reaprime/src/models/data/profile.dart';
import 'package:reaprime/src/models/device/de1_interface.dart';
import 'package:reaprime/src/models/device/impl/mock_de1/mock_de1.dart';
import 'package:reaprime/src/models/errors.dart';
import 'package:reaprime/src/settings/settings_controller.dart';
import 'package:reaprime/src/services/webserver_service.dart';
import 'package:shelf_plus/shelf_plus.dart';

import '../../helpers/mock_device_discovery_service.dart';
import '../../helpers/mock_settings_service.dart';
import '../../helpers/test_scale.dart';
import '../../helpers/test_scale_controller.dart';

class _FixedDe1Controller extends De1Controller {
  _FixedDe1Controller({required super.controller, this.device});

  De1Interface? device;

  @override
  De1Interface connectedDe1() {
    final d = device;
    if (d == null) throw const DeviceNotConnectedException.machine();
    return d;
  }
}

void main() {
  late Handler handler;

  Future<void> wire({
    required bool blockOnNoScale,
    required bool scaleConnected,
    required bool cleaningProfile,
  }) async {
    final deviceController = DeviceController([MockDeviceDiscoveryService()]);
    await deviceController.initialize();
    final controller = _FixedDe1Controller(
      controller: deviceController,
      device: MockDe1(),
    );

    final mockSettings = MockSettingsService();
    await mockSettings.setBlockOnNoScale(blockOnNoScale);
    final settingsController = SettingsController(mockSettings);
    await settingsController.loadSettings();

    final scaleController = TestScaleController(TestScale());
    if (!scaleConnected) scaleController.simulateDisconnect();

    final workflowController = WorkflowController();
    if (cleaningProfile) {
      workflowController.updateWorkflow(
        profile: workflowController.currentWorkflow.profile.copyWith(
          beverageType: BeverageType.cleaning,
        ),
      );
    }

    final de1Handler = De1Handler(
      controller: controller,
      settingsController: settingsController,
      scaleController: scaleController,
      workflowController: workflowController,
    );
    final app = Router().plus;
    de1Handler.addRoutes(app);
    handler = app.call;
  }

  Future<Response> requestEspresso() async => await handler(
    Request('PUT', Uri.parse('http://localhost/api/v1/machine/state/espresso')),
  );

  group('PUT /api/v1/machine/state/espresso — cleaning profile carve-out', () {
    test('still blocks a normal espresso profile with no scale', () async {
      await wire(
        blockOnNoScale: true,
        scaleConnected: false,
        cleaningProfile: false,
      );
      final res = await requestEspresso();
      expect(res.statusCode, 400);
      final body = jsonDecode(await res.readAsString());
      expect(body['type'], 'block_no_scale');
    });

    test(
      'allows a cleaning profile with no scale (no yield to weigh)',
      () async {
        await wire(
          blockOnNoScale: true,
          scaleConnected: false,
          cleaningProfile: true,
        );
        final res = await requestEspresso();
        expect(res.statusCode, 200);
      },
    );
  });
}
