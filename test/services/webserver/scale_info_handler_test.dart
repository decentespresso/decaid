import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/de1_controller.dart';
import 'package:reaprime/src/controllers/device_controller.dart';
import 'package:reaprime/src/controllers/scale_controller.dart';
import 'package:reaprime/src/models/errors.dart';
import 'package:reaprime/src/models/device/scale.dart';
import 'package:reaprime/src/services/webserver_service.dart';
import 'package:reaprime/src/settings/settings_controller.dart';
import 'package:shelf_plus/shelf_plus.dart';

import '../../helpers/mock_device_discovery_service.dart';
import '../../helpers/mock_settings_service.dart';
import '../../helpers/test_scale.dart';

void main() {
  late DeviceController deviceController;
  late De1Controller de1Controller;
  late SettingsController settingsController;

  setUp(() async {
    deviceController = DeviceController([MockDeviceDiscoveryService()]);
    await deviceController.initialize();
    de1Controller = De1Controller(controller: deviceController);
    settingsController = SettingsController(MockSettingsService());
    await settingsController.loadSettings();
  });

  tearDown(() => deviceController.dispose());

  Future<Response> requestInfo(ScaleController controller) async {
    final app = Router().plus;
    ScaleHandler(
      controller: controller,
      de1Controller: de1Controller,
      settingsController: settingsController,
    ).addRoutes(app);
    return app.call(
      Request('GET', Uri.parse('http://localhost/api/v1/scale/info')),
    );
  }

  test('returns 503 when no scale is connected', () async {
    final controller = _DisconnectedScaleController();
    addTearDown(controller.dispose);

    final response = await requestInfo(controller);

    expect(response.statusCode, 503);
    expect(jsonDecode(await response.readAsString()), {
      'error': 'No scale connected',
    });
  });

  test('returns opaque firmwareVersion and optional batteryLevel', () async {
    for (final batteryLevel in [null, 0, 100]) {
      final scale = _InfoScale(
        ScaleInfo(firmwareVersion: 'R029', batteryLevel: batteryLevel),
      );
      addTearDown(scale.dispose);
      final controller = _FixedScaleController(scale);
      addTearDown(controller.dispose);

      final response = await requestInfo(controller);
      final json =
          jsonDecode(await response.readAsString()) as Map<String, dynamic>;

      expect(response.statusCode, 200);
      expect(json['firmwareVersion'], 'R029');
      if (batteryLevel == null) {
        expect(json.containsKey('batteryLevel'), isFalse);
      } else {
        expect(json['batteryLevel'], batteryLevel);
      }
    }
  });
}

class _InfoScale extends TestScale {
  _InfoScale(this._info);

  final ScaleInfo _info;

  @override
  ScaleInfo get scaleInfo => _info;
}

class _FixedScaleController extends ScaleController {
  _FixedScaleController(this._scale);

  final Scale _scale;

  @override
  Scale connectedScale() => _scale;
}

class _DisconnectedScaleController extends ScaleController {
  @override
  Scale connectedScale() => throw const DeviceNotConnectedException.scale();
}
