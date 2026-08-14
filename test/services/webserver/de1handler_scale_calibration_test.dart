import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/de1_controller.dart';
import 'package:reaprime/src/controllers/device_controller.dart';
import 'package:reaprime/src/controllers/workflow_controller.dart';
import 'package:reaprime/src/models/device/de1_interface.dart';
import 'package:reaprime/src/models/device/impl/bengle/mock_bengle.dart';
import 'package:reaprime/src/models/device/impl/mock_de1/mock_de1.dart';
import 'package:reaprime/src/services/webserver_service.dart';
import 'package:reaprime/src/settings/settings_controller.dart';
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

  group('scaleCalibration capability discovery', () {
    test(
      'lists scaleCalibration when a current-firmware Bengle is connected',
      () async {
        await wireWith(MockBengle());
        final res = await get('/api/v1/machine/capabilities');
        final body = jsonDecode(await res.readAsString());
        expect(body['capabilities'], contains('scaleCalibration'));
      },
    );

    test('does not list scaleCalibration on plain DE1', () async {
      await wireWith(MockDe1());
      final res = await get('/api/v1/machine/capabilities');
      final body = jsonDecode(await res.readAsString());
      expect(body['capabilities'], isNot(contains('scaleCalibration')));
    });

    test('outdated Bengle firmware gets no partial capability set', () async {
      await wireWith(MockBengle(supportsCurrentFirmwareSurface: false));
      final res = await get('/api/v1/machine/capabilities');
      final body = jsonDecode(await res.readAsString());
      expect(body['capabilities'], isEmpty);
    });
  });

  group('GET /api/v1/machine/scaleCalibration', () {
    test('returns the decoded state for a Bengle', () async {
      await wireWith(MockBengle());
      final res = await get('/api/v1/machine/scaleCalibration');
      expect(res.statusCode, 200);
      final body = jsonDecode(await res.readAsString());
      expect(body['step'], 'idle');
      expect(body['detectedCell'], 'none');
      expect(body['status'], 'none');
    });

    test('404 on plain DE1', () async {
      await wireWith(MockDe1());
      final res = await get('/api/v1/machine/scaleCalibration');
      expect(res.statusCode, 404);
    });

    test(
      '404 on outdated Bengle firmware names scaleCalibration in the body',
      () async {
        await wireWith(MockBengle(supportsCurrentFirmwareSurface: false));
        final res = await get('/api/v1/machine/scaleCalibration');
        expect(res.statusCode, 404);
        final body = jsonDecode(await res.readAsString());
        expect(body['error'], contains('scaleCalibration'));
        expect(body['error'], isNot(contains('cupWarmer')));
      },
    );
  });

  group('PUT /api/v1/machine/scaleCalibration', () {
    test('accepts a zero command', () async {
      await wireWith(MockBengle());
      final res = await put('/api/v1/machine/scaleCalibration', {
        'command': 'zero',
      });
      expect(res.statusCode, 202);
      final body = jsonDecode(await res.readAsString());
      expect(body['status'], 'accepted');
      expect(body['state']['step'], 'zeroing');
    });

    test('accepts a latch command with a fractional weight', () async {
      await wireWith(MockBengle());
      final res = await put('/api/v1/machine/scaleCalibration', {
        'command': 'latch',
        'weightGrams': 45.5,
      });
      expect(res.statusCode, 202);
      final body = jsonDecode(await res.readAsString());
      expect(body['state']['step'], 'calLatch');
    });

    test('accepts abort', () async {
      await wireWith(MockBengle());
      final res = await put('/api/v1/machine/scaleCalibration', {
        'command': 'abort',
      });
      expect(res.statusCode, 202);
    });

    test('rejects unknown commands at 400', () async {
      await wireWith(MockBengle());
      final res = await put('/api/v1/machine/scaleCalibration', {
        'command': 'left',
      });
      expect(res.statusCode, 400);
    });

    test('rejects latch without weightGrams at 400', () async {
      await wireWith(MockBengle());
      final res = await put('/api/v1/machine/scaleCalibration', {
        'command': 'latch',
      });
      expect(res.statusCode, 400);
    });

    test('rejects out-of-range weightGrams at 400', () async {
      await wireWith(MockBengle());
      final res = await put('/api/v1/machine/scaleCalibration', {
        'command': 'latch',
        'weightGrams': 20000,
      });
      expect(res.statusCode, 400);
    });

    test('404 on plain DE1', () async {
      await wireWith(MockDe1());
      final res = await put('/api/v1/machine/scaleCalibration', {
        'command': 'zero',
      });
      expect(res.statusCode, 404);
    });

    test(
      '404 on outdated Bengle firmware names scaleCalibration in the body',
      () async {
        await wireWith(MockBengle(supportsCurrentFirmwareSurface: false));
        final res = await put('/api/v1/machine/scaleCalibration', {
          'command': 'zero',
        });
        expect(res.statusCode, 404);
        final body = jsonDecode(await res.readAsString());
        expect(body['error'], contains('scaleCalibration'));
        expect(body['error'], isNot(contains('cupWarmer')));
      },
    );
  });
}
