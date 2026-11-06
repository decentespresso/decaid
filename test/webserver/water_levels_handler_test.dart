import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/de1_controller.dart';
import 'package:reaprime/src/controllers/device_controller.dart';
import 'package:reaprime/src/controllers/scale_controller.dart';
import 'package:reaprime/src/controllers/workflow_controller.dart';
import 'package:reaprime/src/models/device/impl/de1/de1.models.dart';
import 'package:reaprime/src/models/device/impl/de1/unified_de1/unified_de1.dart';
import 'package:reaprime/src/services/webserver_service.dart';
import 'package:reaprime/src/settings/settings_controller.dart';
import 'package:shelf_plus/shelf_plus.dart';

import '../helpers/barrier_ble_transport.dart';
import '../helpers/mock_device_discovery_service.dart';
import '../helpers/mock_settings_service.dart';

void main() {
  late BarrierBleTransport transport;
  late De1Controller de1Controller;
  late DeviceController deviceController;
  late ScaleController scaleController;
  late Handler handler;

  setUp(() async {
    transport = BarrierBleTransport();
    transport.queueOnConnectResponses();

    final de1 = UnifiedDe1(transport: transport);

    deviceController = DeviceController([MockDeviceDiscoveryService()]);
    await deviceController.initialize();
    de1Controller = De1Controller(controller: deviceController);
    await de1Controller.connectToDe1(de1);

    final settingsController = SettingsController(MockSettingsService());
    await settingsController.loadSettings();

    scaleController = ScaleController();
    final de1Handler = De1Handler(
      controller: de1Controller,
      settingsController: settingsController,
      scaleController: scaleController,
      workflowController: WorkflowController(),
    );

    final app = Router().plus;
    de1Handler.addRoutes(app);
    handler = app.call;
  });

  tearDown(() async {
    await de1Controller.dispose();
    deviceController.dispose();
    scaleController.dispose();
  });

  Future<Response> getWaterLevels() async {
    return await handler(
      Request('GET', Uri.parse('http://localhost/api/v1/machine/waterLevels')),
    );
  }

  Future<Map<String, dynamic>> jsonBody(Response response) async {
    return jsonDecode(await response.readAsString()) as Map<String, dynamic>;
  }

  void emitWaterLevels({required int currentRaw, required int refillRaw}) {
    final frame = ByteData(4)
      ..setUint16(0, currentRaw, Endian.big)
      ..setUint16(2, refillRaw, Endian.big);
    transport.emitNotification(
      Endpoint.waterLevels,
      frame.buffer.asUint8List(),
    );
  }

  Future<Response> postWaterLevels(int refillLevel) async {
    return await handler(
      Request(
        'POST',
        Uri.parse('http://localhost/api/v1/machine/waterLevels'),
        body: jsonEncode({'refillLevel': refillLevel}),
        headers: {'content-type': 'application/json'},
      ),
    );
  }

  test('waterLevels POST and queued writes stay pending until the write '
      'completes', () async {
    final writeArrived = transport.nextWrite(Endpoint.waterLevels.uuid);
    final barrier = Completer<void>();
    transport.pauseNextWrite(Endpoint.waterLevels.uuid, barrier);

    final first = postWaterLevels(50);
    await writeArrived;

    var secondWriteArrived = false;
    transport.nextWrite(Endpoint.waterLevels.uuid).then((_) {
      secondWriteArrived = true;
    });
    var secondResponseArrived = false;
    final second = postWaterLevels(60).then((r) {
      secondResponseArrived = true;
      return r;
    });
    await _settle();

    expect(secondWriteArrived, isFalse);
    expect(secondResponseArrived, isFalse);

    barrier.complete();

    final firstResponse = await first;
    expect(firstResponse.statusCode, 202);
    final secondResponse = await second;
    expect(secondResponse.statusCode, 202);
    expect(secondWriteArrived, isTrue);
  });

  test('transport failure surfaces through REST error handling', () async {
    final writeArrived = transport.nextWrite(Endpoint.waterLevels.uuid);
    final barrier = Completer<void>();
    transport.pauseNextWrite(Endpoint.waterLevels.uuid, barrier);

    final response = postWaterLevels(50);
    await writeArrived;

    barrier.completeError(StateError('transport boom'));
    final res = await response;
    expect(res.statusCode, 500);
  });

  group('GET /api/v1/machine/waterLevels', () {
    test('answers the latest frame the machine sent', () async {
      emitWaterLevels(currentRaw: 30 * 256, refillRaw: 5 * 256);
      emitWaterLevels(currentRaw: 42 * 256 + 128, refillRaw: 12 * 256);
      await _settle();

      final response = await getWaterLevels();

      expect(response.statusCode, 200);
      expect(response.headers['content-type'], contains('application/json'));
      expect(await jsonBody(response), {
        'currentLevel': 42.5,
        'refillLevel': 12.0,
      });
    });

    test('waits for the first frame when none has arrived yet', () async {
      var answered = false;
      final pending = getWaterLevels().then((r) {
        answered = true;
        return r;
      });
      await _settle();
      expect(answered, isFalse);

      emitWaterLevels(currentRaw: 20 * 256, refillRaw: 7 * 256);

      final response = await pending;
      expect(response.statusCode, 200);
      expect(await jsonBody(response), {
        'currentLevel': 20.0,
        'refillLevel': 7.0,
      });
    });

    test('times out with 504 when the machine sends no frame', () {
      fakeAsync((async) {
        Response? response;
        getWaterLevels().then((r) => response = r);

        async.elapse(const Duration(seconds: 3));
        expect(response, isNull);

        async.elapse(const Duration(seconds: 2));
        expect(response?.statusCode, 504);
      });
    });

    test('answers 500 while no machine is connected', () async {
      await de1Controller.dispose();
      de1Controller = De1Controller(controller: deviceController);
      final settingsController = SettingsController(MockSettingsService());
      await settingsController.loadSettings();
      final de1Handler = De1Handler(
        controller: de1Controller,
        settingsController: settingsController,
        scaleController: scaleController,
        workflowController: WorkflowController(),
      );
      final app = Router().plus;
      de1Handler.addRoutes(app);
      handler = app.call;

      final response = await getWaterLevels();

      expect(response.statusCode, 500);
    });
  });
}

Future<void> _settle([int turns = 10]) async {
  for (var i = 0; i < turns; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}
