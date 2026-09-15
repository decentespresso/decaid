import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/de1_controller.dart';
import 'package:reaprime/src/controllers/auxiliary_scale_registry.dart';
import 'package:reaprime/src/controllers/device_controller.dart';
import 'package:reaprime/src/models/data/shot_state_event.dart';
import 'package:reaprime/src/settings/gateway_mode.dart';
import 'package:reaprime/src/settings/settings_controller.dart';
import 'package:reaprime/src/services/webserver_service.dart';
import 'package:shelf_plus/shelf_plus.dart';

import '../../helpers/mock_device_discovery_service.dart';
import '../../helpers/mock_settings_service.dart';
import '../../helpers/test_scale.dart';
import '../../helpers/test_scale_controller.dart';

ShotStateEvent _event(ShotState state) =>
    ShotStateEvent(event: 'state', timestamp: DateTime.now(), state: state);

void main() {
  late Handler handler;
  late TestScale testScale;
  late De1Controller de1Controller;

  Future<void> wire({
    required bool blockTareDuringShot,
    GatewayMode gatewayMode = GatewayMode.disabled,
  }) async {
    final deviceController = DeviceController([MockDeviceDiscoveryService()]);
    await deviceController.initialize();
    de1Controller = De1Controller(controller: deviceController);

    final mockSettings = MockSettingsService();
    await mockSettings.setBlockTareDuringShot(blockTareDuringShot);
    await mockSettings.updateGatewayMode(gatewayMode);
    final settingsController = SettingsController(mockSettings);
    await settingsController.loadSettings();

    testScale = TestScale();
    final scaleController = TestScaleController(testScale);
    final registry = AuxiliaryScaleRegistry();
    addTearDown(registry.dispose);

    final scaleHandler = ScaleHandler(
      controller: scaleController,
      de1Controller: de1Controller,
      settingsController: settingsController,
      auxiliaryScaleRegistry: registry,
    );
    final app = Router().plus;
    scaleHandler.addRoutes(app);
    handler = app.call;
  }

  Future<Response> requestTare() async => await handler(
    Request('PUT', Uri.parse('http://localhost/api/v1/scale/tare')),
  );

  group('PUT /api/v1/scale/tare — blockTareDuringShot disabled (default)', () {
    setUp(() => wire(blockTareDuringShot: false));

    test('tares while a shot is pouring', () async {
      de1Controller.publishShotEvent(_event(ShotState.pouring));
      final res = await requestTare();
      expect(res.statusCode, 200);
      expect(testScale.tareCallCount, 1);
    });
  });

  group('PUT /api/v1/scale/tare — blockTareDuringShot enabled', () {
    setUp(() => wire(blockTareDuringShot: true));

    test('allows tare while idle', () async {
      de1Controller.publishShotEvent(_event(ShotState.idle));
      final res = await requestTare();
      expect(res.statusCode, 200);
      expect(testScale.tareCallCount, 1);
    });

    test('allows tare once a shot has finished', () async {
      de1Controller.publishShotEvent(_event(ShotState.finished));
      final res = await requestTare();
      expect(res.statusCode, 200);
      expect(testScale.tareCallCount, 1);
    });

    test('blocks tare while preheating', () async {
      de1Controller.publishShotEvent(_event(ShotState.preheating));
      final res = await requestTare();
      expect(res.statusCode, 400);
      final body = jsonDecode(await res.readAsString());
      expect(body['type'], 'block_tare_during_shot');
      expect(testScale.tareCallCount, 0);
    });

    test('blocks tare while pouring', () async {
      de1Controller.publishShotEvent(_event(ShotState.pouring));
      final res = await requestTare();
      expect(res.statusCode, 400);
      final body = jsonDecode(await res.readAsString());
      expect(body['type'], 'block_tare_during_shot');
      expect(testScale.tareCallCount, 0);
    });

    test('blocks tare while stopping', () async {
      de1Controller.publishShotEvent(_event(ShotState.stopping));
      final res = await requestTare();
      expect(res.statusCode, 400);
      expect(testScale.tareCallCount, 0);
    });
  });

  group(
    'PUT /api/v1/scale/tare — blockTareDuringShot enabled, full gateway mode',
    () {
      setUp(
        () => wire(blockTareDuringShot: true, gatewayMode: GatewayMode.full),
      );

      test('allows tare even while a tracked shot looks active', () async {
        de1Controller.publishShotEvent(_event(ShotState.pouring));
        final res = await requestTare();
        expect(res.statusCode, 200);
        expect(testScale.tareCallCount, 1);
      });
    },
  );
}
