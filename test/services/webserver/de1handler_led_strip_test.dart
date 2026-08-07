import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/de1_controller.dart';
import 'package:reaprime/src/controllers/device_controller.dart';
import 'package:reaprime/src/controllers/workflow_controller.dart';
import 'package:reaprime/src/settings/settings_controller.dart';
import 'package:reaprime/src/models/device/de1_interface.dart';
import 'package:reaprime/src/models/device/impl/bengle/mock_bengle.dart';
import 'package:reaprime/src/models/device/impl/mock_de1/mock_de1.dart';
import 'package:reaprime/src/models/device/led_strip.dart';
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

  Future<Response> put(String path, Object body) async => await handler(
    Request(
      'PUT',
      Uri.parse('http://localhost$path'),
      body: jsonEncode(body),
      headers: {HttpHeaders.contentTypeHeader: 'application/json'},
    ),
  );

  Future<Response> post(String path) async => await handler(
    Request(
      'POST',
      Uri.parse('http://localhost$path'),
      body: jsonEncode(const {}),
      headers: {HttpHeaders.contentTypeHeader: 'application/json'},
    ),
  );

  group('GET /api/v1/machine/capabilities — ledStrip', () {
    test('returns ledStrip when a Bengle is connected', () async {
      await wireWith(MockBengle());
      final res = await get('/api/v1/machine/capabilities');
      final body = jsonDecode(await res.readAsString());
      expect(body['capabilities'], contains('ledStrip'));
    });

    test('does not return ledStrip on plain DE1', () async {
      await wireWith(MockDe1());
      final res = await get('/api/v1/machine/capabilities');
      final body = jsonDecode(await res.readAsString());
      expect(body['capabilities'], isNot(contains('ledStrip')));
    });
  });

  group('GET /api/v1/machine/ledStrip', () {
    test('200 + initial all-off on MockBengle', () async {
      await wireWith(MockBengle());
      final res = await get('/api/v1/machine/ledStrip');
      expect(res.statusCode, 200);
      final body = jsonDecode(await res.readAsString());
      expect(body['frontStrip']['sleeping'], '000000000000');
      expect(body['frontStrip']['awake'], '000000000000');
      expect(body['backStrip']['sleeping'], '000000000000');
      expect(body['backStrip']['awake'], '000000000000');
      expect(body['frontSwitch']['sleeping'], '000000000000');
      expect(body['frontSwitch']['awake'], '000000000000');
    });

    test('404 on plain DE1', () async {
      await wireWith(MockDe1());
      final res = await get('/api/v1/machine/ledStrip');
      expect(res.statusCode, 404);
    });
  });

  group('PUT /api/v1/machine/ledStrip', () {
    test('200 + writes state into MockBengle', () async {
      final bengle = MockBengle();
      await wireWith(bengle);

      final res = await put('/api/v1/machine/ledStrip', {
        'frontStrip': {'sleeping': 'FFFF80000000', 'awake': '000000000000'},
        'backStrip': {'sleeping': '000000000000', 'awake': 'FFFFFFFFFFFF'},
        'frontSwitch': {'sleeping': '000000000000', 'awake': '000000000000'},
      });
      expect(res.statusCode, 200);

      final state = await bengle.getLedStripState();
      expect(state.frontStrip.sleeping, const Color16(65535, 32768, 0));
      expect(state.frontStrip.awake, Color16.off);
      expect(state.backStrip.awake, const Color16(65535, 65535, 65535));
    });

    test('400 on non-map body', () async {
      await wireWith(MockBengle());
      final res = await put('/api/v1/machine/ledStrip', [1, 2, 3]);
      expect(res.statusCode, 400);
    });

    test('malformed hex defaults to zero', () async {
      final bengle = MockBengle();
      await wireWith(bengle);

      final res = await put('/api/v1/machine/ledStrip', {
        'frontStrip': {'sleeping': 'XXYY', 'awake': '000000000000'},
        'backStrip': {'sleeping': '000000000000', 'awake': '000000000000'},
        'frontSwitch': {'sleeping': '000000000000', 'awake': '000000000000'},
      });
      expect(res.statusCode, 200);

      final state = await bengle.getLedStripState();
      expect(state.frontStrip.sleeping, Color16.off);
    });

    test('404 on plain DE1', () async {
      await wireWith(MockDe1());
      final res = await put('/api/v1/machine/ledStrip', {
        'frontStrip': {'sleeping': 'FFFF80000000', 'awake': '000000000000'},
        'backStrip': {'sleeping': '000000000000', 'awake': '000000000000'},
        'frontSwitch': {'sleeping': '000000000000', 'awake': '000000000000'},
      });
      expect(res.statusCode, 404);
    });
  });

  group('POST /api/v1/machine/ledStrip/commit', () {
    test('202 on Bengle', () async {
      await wireWith(MockBengle());
      final res = await post('/api/v1/machine/ledStrip/commit');
      expect(res.statusCode, 202);
    });

    test('404 on plain DE1', () async {
      await wireWith(MockDe1());
      final res = await post('/api/v1/machine/ledStrip/commit');
      expect(res.statusCode, 404);
    });
  });

  group('POST /api/v1/machine/ledStrip/reset', () {
    test('200 + returns state on Bengle', () async {
      final bengle = MockBengle();
      await wireWith(bengle);

      final written = LedStripState(
        frontStrip: ZoneLedState(
          sleeping: const Color16(65535, 0, 0),
          awake: Color16.off,
        ),
      );
      await bengle.setLedStrip(written);
      await bengle.commitLedStrip();
      await bengle.setLedStrip(const LedStripState());

      final res = await post('/api/v1/machine/ledStrip/reset');
      expect(res.statusCode, 200);
      final body = jsonDecode(await res.readAsString());
      expect(body['frontStrip']['sleeping'], 'FFFF00000000');
    });

    test('404 on plain DE1', () async {
      await wireWith(MockDe1());
      final res = await post('/api/v1/machine/ledStrip/reset');
      expect(res.statusCode, 404);
    });
  });
}
