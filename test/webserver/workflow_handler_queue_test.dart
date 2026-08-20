import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/de1_controller.dart';
import 'package:reaprime/src/controllers/device_controller.dart';
import 'package:reaprime/src/controllers/workflow_controller.dart';
import 'package:reaprime/src/models/device/de1_interface.dart';
import 'package:reaprime/src/services/webserver/workflow_handler.dart';
import 'package:shelf_plus/shelf_plus.dart';

import '../helpers/mock_device_discovery_service.dart';
import '../helpers/test_de1.dart';

class _StallingSteamDe1 extends TestDe1 {
  _StallingSteamDe1() : super(deviceId: 'stalling-de1', name: 'StallingDe1');

  int setSteamFlowCalls = 0;

  @override
  Future<void> setSteamFlow(double value) async {
    setSteamFlowCalls++;
    if (setSteamFlowCalls == 1) {
      await Completer<void>().future;
    }
  }

  @override
  Future<void> updateShotSettings(De1ShotSettings settings) async {}
}

void main() {
  test('a stalled workflow apply does not 503 every later request', () async {
    final deviceController = DeviceController([MockDeviceDiscoveryService()]);
    await deviceController.initialize();
    final de1Controller = De1Controller(
      controller: deviceController,
      deviceWriteStallTimeout: const Duration(milliseconds: 200),
    );
    final de1 = _StallingSteamDe1();
    await de1Controller.connectToDe1(de1);
    de1.emitShotSettings(
      De1ShotSettings(
        steamSetting: 0,
        targetSteamTemp: 150,
        targetSteamDuration: 30,
        targetHotWaterTemp: 75,
        targetHotWaterVolume: 50,
        targetHotWaterDuration: 30,
        targetShotVolume: 36,
        groupTemp: 94.0,
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));

    final app = Router().plus;
    WorkflowHandler(
      controller: WorkflowController(),
      de1controller: de1Controller,
      applyTimeout: const Duration(milliseconds: 300),
    ).addRoutes(app);
    final handler = app.call;

    Future<Response> put(int duration) async => await handler(
      Request(
        'PUT',
        Uri.parse('http://localhost/api/v1/workflow'),
        body: jsonEncode({
          'steamSettings': {'duration': duration},
        }),
      ),
    );

    final first = await put(16);
    expect(first.statusCode, 503);

    final second = await put(17).timeout(const Duration(seconds: 5));
    expect(
      second.statusCode,
      200,
      reason: 'the queue must drain after the stalled entry gives up',
    );

    await de1.dispose();
  });
}
