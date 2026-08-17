import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/de1_controller.dart';
import 'package:reaprime/src/controllers/device_controller.dart';
import 'package:reaprime/src/controllers/workflow_controller.dart';
import 'package:reaprime/src/models/device/de1_interface.dart';
import 'package:reaprime/src/models/device/impl/mock_de1/mock_de1.dart';
import 'package:reaprime/src/models/device/transport/ble_timeout_exception.dart';
import 'package:reaprime/src/models/errors.dart';
import 'package:reaprime/src/settings/settings_controller.dart';
import 'package:reaprime/src/services/webserver_service.dart';
import 'package:shelf_plus/shelf_plus.dart';

import '../../helpers/mock_device_discovery_service.dart';
import '../../helpers/mock_settings_service.dart';
import '../../helpers/test_de1.dart';
import '../../helpers/test_scale.dart';
import '../../helpers/test_scale_controller.dart';

class _TimeoutDe1 extends TestDe1 {
  @override
  Future<De1Calibration> readCalibration(
    De1CalibrationTarget target, {
    De1CalibrationSource source = De1CalibrationSource.current,
  }) async {
    throw EndpointUnavailableException(
      'calibration',
      const Duration(seconds: 4),
    );
  }
}

class _BleTimeoutDe1 extends TestDe1 {
  @override
  Future<De1Calibration> readCalibration(
    De1CalibrationTarget target, {
    De1CalibrationSource source = De1CalibrationSource.current,
  }) async {
    throw BleTimeoutException('read');
  }

  @override
  Future<void> writeCalibration(De1Calibration calibration) async {
    throw BleTimeoutException('write');
  }
}

De1ShotSettings _anyShotSettings() => De1ShotSettings(
  steamSetting: 0,
  targetSteamTemp: 0,
  targetSteamDuration: 0,
  targetHotWaterTemp: 0,
  targetHotWaterVolume: 0,
  targetHotWaterDuration: 0,
  targetShotVolume: 0,
  groupTemp: 90,
);

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

  Future<Response> put(String path, Object body) async => await handler(
    Request(
      'PUT',
      Uri.parse('http://localhost$path'),
      body: jsonEncode(body),
      headers: {HttpHeaders.contentTypeHeader: 'application/json'},
    ),
  );

  group('legacy flow estimation calibration', () {
    test('GET returns the flowMultiplier unchanged', () async {
      await wireWith(MockDe1());
      final res = await get('/api/v1/machine/calibration');
      expect(res.statusCode, 200);
      final body = jsonDecode(await res.readAsString());
      expect(body, {'flowMultiplier': 1.0});
    });

    test('POST flowMultiplier round-trips through GET', () async {
      final de1 = MockDe1();
      await wireWith(de1);

      final res = await post('/api/v1/machine/calibration', {
        'flowMultiplier': 1.1,
      });
      expect(res.statusCode, 202);
      expect(await de1.getFlowEstimation(), 1.1);

      final read = jsonDecode(
        await (await get('/api/v1/machine/calibration')).readAsString(),
      );
      expect(read, {'flowMultiplier': 1.1});
    });

    test('returns 500 when no DE1 connected', () async {
      await wireWith(null);
      final res = await get('/api/v1/machine/calibration');
      expect(res.statusCode, 500);
    });
  });

  group('GET /api/v1/machine/calibration/{target}', () {
    test('reads current calibration for every target', () async {
      await wireWith(MockDe1());
      for (final target in ['flow', 'pressure', 'temperature']) {
        final res = await get('/api/v1/machine/calibration/$target');
        expect(res.statusCode, 200, reason: target);
        final body = jsonDecode(await res.readAsString());
        expect(body['target'], target);
        expect(body['source'], 'current');
        expect(body['de1ReportedValue'], isA<num>());
        expect(body['measuredValue'], isA<num>());
      }
    });

    test('reads factory calibration with source=factory', () async {
      await wireWith(MockDe1());
      final res = await get(
        '/api/v1/machine/calibration/pressure?source=factory',
      );
      expect(res.statusCode, 200);
      final body = jsonDecode(await res.readAsString());
      expect(body['target'], 'pressure');
      expect(body['source'], 'factory');
    });

    test('rejects unknown targets', () async {
      await wireWith(MockDe1());
      final res = await get('/api/v1/machine/calibration/bogus');
      expect(res.statusCode, 400);
    });

    test('rejects unknown sources', () async {
      await wireWith(MockDe1());
      final res = await get('/api/v1/machine/calibration/flow?source=bogus');
      expect(res.statusCode, 400);
    });

    test('maps a missing machine response to 504', () async {
      await wireWith(_TimeoutDe1());
      final res = await get('/api/v1/machine/calibration/flow');
      expect(res.statusCode, 504);
    });

    test('maps a transport-level read timeout to 504', () async {
      await wireWith(_BleTimeoutDe1());
      final res = await get('/api/v1/machine/calibration/flow');
      expect(res.statusCode, 504);
    });

    test('returns 500 when no DE1 connected', () async {
      await wireWith(null);
      final res = await get('/api/v1/machine/calibration/flow');
      expect(res.statusCode, 500);
    });
  });

  group('PUT /api/v1/machine/calibration/{target}', () {
    test('writes calibration and round-trips through GET', () async {
      final de1 = MockDe1();
      await wireWith(de1);

      final res = await put('/api/v1/machine/calibration/flow', {
        'de1ReportedValue': 1.05,
        'measuredValue': 1.02,
      });
      expect(res.statusCode, 202);

      final read = jsonDecode(
        await (await get('/api/v1/machine/calibration/flow')).readAsString(),
      );
      // Writes are corrections: the mock applies measured/reported to the
      // stored scalar like the real machine, and ratiometric reads always
      // report 1.0 in the reported field.
      expect(read['de1ReportedValue'], 1.0);
      expect(read['measuredValue'], closeTo(1.0 * 1.02 / 1.05, 1e-9));
      expect(read['source'], 'current');
    });

    test('writes every target with machine correction semantics', () async {
      final de1 = MockDe1();
      await wireWith(de1);
      for (final (target, base, reported, measured) in [
        ('flow', 1.0, 1.1, 1.05),
        ('pressure', 9.0, 9.5, 9.25),
        ('temperature', 93.0, 93.5, 93.0),
      ]) {
        final res = await put('/api/v1/machine/calibration/$target', {
          'de1ReportedValue': reported,
          'measuredValue': measured,
        });
        expect(res.statusCode, 202, reason: target);
        final read = await de1.readCalibration(
          De1CalibrationTarget.values.firstWhere((t) => t.name == target),
        );
        final expected = target == 'temperature'
            ? base + (measured - reported)
            : base * measured / reported;
        if (target == 'temperature') {
          expect(read.de1ReportedValue, 0.0);
        } else {
          expect(read.de1ReportedValue, 1.0);
        }
        expect(read.measuredValue, closeTo(expected, 1e-9));
      }
    });

    test('does not touch the flow estimation multiplier', () async {
      final de1 = MockDe1();
      await wireWith(de1);

      await put('/api/v1/machine/calibration/flow', {
        'de1ReportedValue': 1.05,
        'measuredValue': 1.02,
      });

      expect(await de1.getFlowEstimation(), 1.0);
    });

    test('rejects unknown targets', () async {
      await wireWith(MockDe1());
      final res = await put('/api/v1/machine/calibration/bogus', {
        'de1ReportedValue': 1.0,
        'measuredValue': 1.0,
      });
      expect(res.statusCode, 400);
    });

    test('rejects missing or invalid values', () async {
      await wireWith(MockDe1());

      final missing = await put('/api/v1/machine/calibration/flow', {
        'de1ReportedValue': 1.0,
      });
      expect(missing.statusCode, 400);

      final nonFinite = await handler(
        Request(
          'PUT',
          Uri.parse('http://localhost/api/v1/machine/calibration/flow'),
          body: '{"de1ReportedValue": 1e999, "measuredValue": 1.0}',
          headers: {HttpHeaders.contentTypeHeader: 'application/json'},
        ),
      );
      expect(nonFinite.statusCode, 400);

      final invalidJson = await handler(
        Request(
          'PUT',
          Uri.parse('http://localhost/api/v1/machine/calibration/flow'),
          body: 'not json',
          headers: {HttpHeaders.contentTypeHeader: 'application/json'},
        ),
      );
      expect(invalidJson.statusCode, 400);
    });

    test('rejects values outside the signed Q16.16 range', () async {
      await wireWith(MockDe1());

      final reportedTooLarge = await put('/api/v1/machine/calibration/flow', {
        'de1ReportedValue': 40000,
        'measuredValue': 1.0,
      });
      expect(reportedTooLarge.statusCode, 400);

      final measuredTooNegative = await put(
        '/api/v1/machine/calibration/flow',
        {'de1ReportedValue': 1.0, 'measuredValue': -40000},
      );
      expect(measuredTooNegative.statusCode, 400);

      final measured = await get('/api/v1/machine/calibration/flow');
      expect(measured.statusCode, 200);
    });

    test('maps a transport-level write timeout to 504', () async {
      final de1 = _BleTimeoutDe1();
      await wireWith(de1);
      // Settle the controller's startup-data initialization; otherwise the
      // queued write races the controller's 2s init timeout.
      de1.emitShotSettings(_anyShotSettings());
      final res = await put('/api/v1/machine/calibration/flow', {
        'de1ReportedValue': 1.0,
        'measuredValue': 1.0,
      });
      expect(res.statusCode, 504);
    });

    test('returns 500 when no DE1 connected', () async {
      await wireWith(null);
      final res = await put('/api/v1/machine/calibration/flow', {
        'de1ReportedValue': 1.0,
        'measuredValue': 1.0,
      });
      expect(res.statusCode, 500);
    });
  });
}
