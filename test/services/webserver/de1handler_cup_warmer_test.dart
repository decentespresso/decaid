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

  group('GET /api/v1/machine/capabilities', () {
    test('returns cupWarmer when a Bengle is connected', () async {
      await wireWith(MockBengle());
      final res = await get('/api/v1/machine/capabilities');
      expect(res.statusCode, 200);
      final body = jsonDecode(await res.readAsString());
      expect(body['capabilities'], contains('cupWarmer'));
    });

    test('returns empty list for a plain DE1', () async {
      await wireWith(MockDe1());
      final res = await get('/api/v1/machine/capabilities');
      expect(res.statusCode, 200);
      final body = jsonDecode(await res.readAsString());
      expect(body['capabilities'], isEmpty);
    });

    test('returns integratedScale when a Bengle is connected', () async {
      await wireWith(MockBengle());
      final res = await get('/api/v1/machine/capabilities');
      final body = jsonDecode(await res.readAsString());
      expect(body['capabilities'], contains('integratedScale'));
    });

    test('does not return integratedScale on plain DE1', () async {
      await wireWith(MockDe1());
      final res = await get('/api/v1/machine/capabilities');
      final body = jsonDecode(await res.readAsString());
      expect(body['capabilities'], isNot(contains('integratedScale')));
    });
  });

  group('GET /api/v1/machine/cupWarmer', () {
    test('200 + initial setpoint 0.0 on MockBengle', () async {
      await wireWith(MockBengle());
      final res = await get('/api/v1/machine/cupWarmer');
      expect(res.statusCode, 200);
      final body = jsonDecode(await res.readAsString());
      expect(body['temperature'], isA<int>());
      expect(body['temperature'], 0);
    });

    test(
      '404 on plain DE1 (machine connected but capability absent)',
      () async {
        await wireWith(MockDe1());
        final res = await get('/api/v1/machine/cupWarmer');
        expect(res.statusCode, 404);
      },
    );
  });

  group('PUT /api/v1/machine/cupWarmer', () {
    test('200 + writes setpoint into MockBengle', () async {
      final bengle = MockBengle();
      await wireWith(bengle);

      final res = await put('/api/v1/machine/cupWarmer', {'temperature': 60});
      expect(res.statusCode, 200);
      expect(await bengle.getCupWarmerTemperature(), 60.0);
    });

    test('400 on out-of-range temperature', () async {
      await wireWith(MockBengle());
      final res = await put('/api/v1/machine/cupWarmer', {'temperature': 100});
      expect(res.statusCode, 400);
    });

    test('400 on negative temperature', () async {
      await wireWith(MockBengle());
      final res = await put('/api/v1/machine/cupWarmer', {'temperature': -5});
      expect(res.statusCode, 400);
    });

    test('400 on fractional temperature', () async {
      await wireWith(MockBengle());
      final res = await put('/api/v1/machine/cupWarmer', {'temperature': 60.5});
      expect(res.statusCode, 400);
    });

    test('400 when temperature key is missing', () async {
      await wireWith(MockBengle());
      final res = await put('/api/v1/machine/cupWarmer', {});
      expect(res.statusCode, 400);
    });

    test('404 on plain DE1', () async {
      await wireWith(MockDe1());
      final res = await put('/api/v1/machine/cupWarmer', {'temperature': 60});
      expect(res.statusCode, 404);
    });
  });

  group('GET /api/v1/machine/cupWarmer — mode + current temperature', () {
    test('returns enabled=false and null temperature when off', () async {
      await wireWith(MockBengle());
      final res = await get('/api/v1/machine/cupWarmer');
      final body = jsonDecode(await res.readAsString());
      expect(body['enabled'], isFalse);
      expect(body['currentTemperature'], isNull);
    });

    test('returns enabled=true and a temperature once enabled', () async {
      final bengle = MockBengle();
      await wireWith(bengle);
      await bengle.setCupWarmerEnabled(true);
      final res = await get('/api/v1/machine/cupWarmer');
      final body = jsonDecode(await res.readAsString());
      expect(body['enabled'], isTrue);
      expect(body['currentTemperature'], 42.0);
    });
  });

  group('PUT /api/v1/machine/cupWarmer — enabled', () {
    test(
      'temperature-only request also enables manual heating (back-compat)',
      () async {
        final bengle = MockBengle();
        await wireWith(bengle);

        final res = await put('/api/v1/machine/cupWarmer', {'temperature': 45});
        expect(res.statusCode, 200);
        expect(await bengle.getCupWarmerTemperature(), 45.0);
        expect(await bengle.getCupWarmerEnabled(), isTrue);
      },
    );

    test('enabled=false disables without destroying the setpoint', () async {
      final bengle = MockBengle();
      await wireWith(bengle);
      await bengle.setCupWarmerTemperature(55.0);
      await bengle.setCupWarmerEnabled(true);

      final res = await put('/api/v1/machine/cupWarmer', {'enabled': false});
      expect(res.statusCode, 200);
      expect(await bengle.getCupWarmerEnabled(), isFalse);
      expect(
        await bengle.getCupWarmerTemperature(),
        55.0,
        reason:
            'setpoint must survive a manual disable (scheduled pre-warm '
            'needs a non-zero setpoint while the mode is off)',
      );
    });

    test(
      'temperature + enabled=false sets the setpoint but stays off',
      () async {
        final bengle = MockBengle();
        await wireWith(bengle);

        final res = await put('/api/v1/machine/cupWarmer', {
          'temperature': 55,
          'enabled': false,
        });
        expect(res.statusCode, 200);
        expect(await bengle.getCupWarmerTemperature(), 55.0);
        expect(await bengle.getCupWarmerEnabled(), isFalse);
      },
    );

    test('400 on non-boolean enabled', () async {
      await wireWith(MockBengle());
      final res = await put('/api/v1/machine/cupWarmer', {'enabled': 'yes'});
      expect(res.statusCode, 400);
    });

    test('400 when neither temperature nor enabled is present', () async {
      await wireWith(MockBengle());
      final res = await put('/api/v1/machine/cupWarmer', {});
      expect(res.statusCode, 400);
    });
  });

  group('/api/v1/machine/cupWarmer/preheat', () {
    test('GET returns the persisted preheat state', () async {
      await wireWith(MockBengle());
      final res = await get('/api/v1/machine/cupWarmer/preheat');
      expect(res.statusCode, 200);
      final body = jsonDecode(await res.readAsString());
      expect(body['enabled'], isFalse);
      expect(body['leadMinutes'], 30);
      expect(body['active'], isFalse);
    });

    test('PUT sets enable and lead minutes', () async {
      final bengle = MockBengle();
      await wireWith(bengle);

      final res = await put('/api/v1/machine/cupWarmer/preheat', {
        'enabled': true,
        'leadMinutes': 45,
      });
      expect(res.statusCode, 200);
      final state = await bengle.getCupWarmerPreheatState();
      expect(state.enabled, isTrue);
      expect(state.leadMinutes, 45);
    });

    test('PUT with only leadMinutes keeps the current enable', () async {
      final bengle = MockBengle();
      await wireWith(bengle);
      await bengle.setCupWarmerPreheat(enabled: true, leadMinutes: 30);

      final res = await put('/api/v1/machine/cupWarmer/preheat', {
        'leadMinutes': 60,
      });
      expect(res.statusCode, 200);
      final state = await bengle.getCupWarmerPreheatState();
      expect(state.enabled, isTrue);
      expect(state.leadMinutes, 60);
    });

    test('PUT rejects out-of-range leadMinutes at 400', () async {
      await wireWith(MockBengle());
      final res = await put('/api/v1/machine/cupWarmer/preheat', {
        'leadMinutes': 121,
      });
      expect(res.statusCode, 400);
    });

    test('PUT rejects fractional leadMinutes at 400', () async {
      await wireWith(MockBengle());
      final res = await put('/api/v1/machine/cupWarmer/preheat', {
        'leadMinutes': 30.5,
      });
      expect(res.statusCode, 400);
    });

    test('404 on plain DE1', () async {
      await wireWith(MockDe1());
      final res = await get('/api/v1/machine/cupWarmer/preheat');
      expect(res.statusCode, 404);
    });
  });
}
