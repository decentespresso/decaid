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

class _FailingResetBengle extends MockBengle {
  @override
  Future<LedStripState?> resetLedStrip() async => null;
}

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
    test(
      'a current-firmware Bengle exposes the entire capability set',
      () async {
        await wireWith(MockBengle());
        final res = await get('/api/v1/machine/capabilities');
        final body = jsonDecode(await res.readAsString());
        expect(body['capabilities'], [
          'cupWarmer',
          'integratedScale',
          'stopAtWeight',
          'ledStrip',
          'scaleCalibration',
          'preheat',
          'wakeSchedule',
        ]);
      },
    );

    test('does not return ledStrip on plain DE1', () async {
      await wireWith(MockDe1());
      final res = await get('/api/v1/machine/capabilities');
      final body = jsonDecode(await res.readAsString());
      expect(body['capabilities'], isNot(contains('ledStrip')));
    });
  });

  group('GET /api/v1/machine/ledStrip', () {
    test('200 + hydrated palette on MockBengle', () async {
      await wireWith(MockBengle());
      final res = await get('/api/v1/machine/ledStrip');
      expect(res.statusCode, 200);
      final body = jsonDecode(await res.readAsString());
      expect(body['frontStrip']['sleeping'], '300020001000');
      expect(body['frontStrip']['awake'], 'FF00F0008000');
      expect(body['backStrip']['sleeping'], '300020001000');
      expect(body['backStrip']['awake'], 'FF00F0008000');
      expect(body['frontSwitch']['awake'], 'FF00F0008000');
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
      expect(state!.frontStrip.sleeping, const Color16(65280, 32768, 0));
      expect(state.frontStrip.awake, Color16.off);
      expect(state.backStrip.awake, const Color16(65280, 65280, 65280));
    });

    test('400 on non-map body', () async {
      await wireWith(MockBengle());
      final res = await put('/api/v1/machine/ledStrip', [1, 2, 3]);
      expect(res.statusCode, 400);
    });

    test('replicated-byte input is stored and echoed canonically', () async {
      await wireWith(MockBengle());

      final res = await put('/api/v1/machine/ledStrip', {
        'frontStrip': {'sleeping': 'FFFF22220000', 'awake': 'FF00F0008000'},
        'backStrip': {'sleeping': '300020001000', 'awake': 'FFFFFFFFFFFF'},
        'frontSwitch': {'sleeping': '000000000000', 'awake': '000000000000'},
      });
      expect(res.statusCode, 200);

      final putBody = await res.readAsString();
      final echoed = jsonDecode(putBody);
      expect(
        echoed['frontStrip']['sleeping'],
        'FF0022000000',
        reason: 'the PUT 200 body must be the stored canonical spelling',
      );
      expect(echoed['backStrip']['awake'], 'FF00FF00FF00');

      final getRes = await get('/api/v1/machine/ledStrip');
      expect(getRes.statusCode, 200);
      expect(
        await getRes.readAsString(),
        putBody,
        reason: 'a following GET must be byte-identical to the PUT echo',
      );
    });

    test('the audited F-044 write on frontStrip.awake echoes the palette '
        'the machine recorded', () async {
      await wireWith(MockBengle());

      final res = await put('/api/v1/machine/ledStrip', {
        'frontStrip': {'awake': 'FFFF22220000', 'sleeping': '400022000000'},
        'backStrip': {'awake': 'FF00D3008E00', 'sleeping': '400022000000'},
        'frontSwitch': {'awake': 'FFFF22220000', 'sleeping': '400022000000'},
      });
      expect(res.statusCode, 200);

      final echoed = jsonDecode(await res.readAsString());
      expect(
        echoed,
        {
          'frontStrip': {'sleeping': '400022000000', 'awake': 'FF0022000000'},
          'backStrip': {'sleeping': '400022000000', 'awake': 'FF00D3008E00'},
          'frontSwitch': {'sleeping': '400022000000', 'awake': 'FF0022000000'},
        },
        reason:
            'the echo must match the stored state the audited machine '
            'served back for this exact write',
      );
    });

    test('canonical input is echoed byte-identically', () async {
      await wireWith(MockBengle());

      const frontStrip = {'sleeping': 'FF0022000000', 'awake': 'FF00F0008000'};
      const backStrip = {'sleeping': '300020001000', 'awake': 'FF00FF00FF00'};

      final res = await put('/api/v1/machine/ledStrip', {
        'frontStrip': frontStrip,
        'backStrip': backStrip,
        'frontSwitch': {'sleeping': '000000000000', 'awake': '000000000000'},
      });
      expect(res.statusCode, 200);

      final echoed = jsonDecode(await res.readAsString());
      expect(echoed['frontStrip'], frontStrip);
      expect(echoed['backStrip'], backStrip);
    });

    test(
      'the echoed frontSwitch is the derived palette, not the sent one',
      () async {
        await wireWith(MockBengle());

        final res = await put('/api/v1/machine/ledStrip', {
          'frontStrip': {'sleeping': '000000000000', 'awake': '000000000000'},
          'backStrip': {'sleeping': '000000000000', 'awake': '000000000000'},
          'frontSwitch': {'sleeping': 'FFFF00000000', 'awake': '0000FFFF0000'},
        });
        expect(res.statusCode, 200);

        final echoed = jsonDecode(await res.readAsString());
        expect(echoed['frontSwitch']['awake'], 'FF00F000C800');
        expect(echoed['frontSwitch']['sleeping'], '550050004300');
      },
    );

    test('reset after a PUT returns the same canonical body', () async {
      await wireWith(MockBengle());

      final res = await put('/api/v1/machine/ledStrip', {
        'frontStrip': {'sleeping': 'FFFF22220000', 'awake': 'FF00F0008000'},
        'backStrip': {'sleeping': '300020001000', 'awake': 'FFFFFFFFFFFF'},
        'frontSwitch': {'sleeping': '000000000000', 'awake': '000000000000'},
      });
      expect(res.statusCode, 200);
      final putBody = await res.readAsString();

      final resetRes = await post('/api/v1/machine/ledStrip/reset');
      expect(resetRes.statusCode, 200);
      expect(await resetRes.readAsString(), putBody);
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
      expect(state!.frontStrip.sleeping, Color16.off);
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
    test('200 + returns current state on Bengle (truthful reload)', () async {
      final bengle = MockBengle();
      await wireWith(bengle);

      final written = LedStripState(
        frontStrip: ZoneLedState(
          sleeping: const Color16(65535, 0, 0),
          awake: Color16.off,
        ),
      );
      await bengle.setLedStrip(written);

      final res = await post('/api/v1/machine/ledStrip/reset');
      expect(res.statusCode, 200);
      final body = jsonDecode(await res.readAsString());
      expect(body['frontStrip']['sleeping'], 'FF0000000000');
    });

    test('503 when the reload fails after a successful hydration', () async {
      final bengle = _FailingResetBengle();
      await wireWith(bengle);
      await bengle.setLedStrip(
        LedStripState(
          frontStrip: ZoneLedState(
            sleeping: const Color16(0xFF00, 0x0000, 0x0000),
            awake: Color16.off,
          ),
        ),
      );

      final res = await post('/api/v1/machine/ledStrip/reset');
      expect(
        res.statusCode,
        503,
        reason: 'a failed reset must not return stale cached state as 200',
      );
    });

    test('404 on plain DE1', () async {
      await wireWith(MockDe1());
      final res = await post('/api/v1/machine/ledStrip/reset');
      expect(res.statusCode, 404);
    });
  });
}
