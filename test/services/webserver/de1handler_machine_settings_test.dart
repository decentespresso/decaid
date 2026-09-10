import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/de1_controller.dart';
import 'package:reaprime/src/controllers/device_controller.dart';
import 'package:reaprime/src/controllers/workflow_controller.dart';
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

class _IgnoresFanWrites extends MockDe1 {
  @override
  Future<void> setFanThreshhold(int temp) async {}
}

class _FanReadBackTimesOut extends MockDe1 {
  @override
  Future<int> getFanThreshhold() async {
    throw const MmrTimeoutException('fanThreshold', Duration(seconds: 4));
  }
}

void main() {
  late Handler handler;

  Future<void> wireWith(De1Interface? device) async {
    final deviceController = DeviceController([MockDeviceDiscoveryService()]);
    await deviceController.initialize();
    final controller = De1Controller(controller: deviceController);
    if (device != null) {
      await controller.connectToDe1(device);
    }

    final settingsController = SettingsController(MockSettingsService());
    await settingsController.loadSettings();

    final de1Handler = De1Handler(
      controller: controller,
      settingsController: settingsController,
      scaleController: TestScaleController(TestScale()),
      workflowController: WorkflowController(),
    );
    final app = Router().plus;
    de1Handler.addRoutes(app);
    handler = app.call;
  }

  Future<Response> post(Object body) async => await handler(
    Request(
      'POST',
      Uri.parse('http://localhost/api/v1/machine/settings'),
      body: body is String ? body : jsonEncode(body),
      headers: {HttpHeaders.contentTypeHeader: 'application/json'},
    ),
  );

  Future<Response> get() async => await handler(
    Request('GET', Uri.parse('http://localhost/api/v1/machine/settings')),
  );

  Future<Map<String, dynamic>> results(Response res) async {
    final body = jsonDecode(await res.readAsString()) as Map<String, dynamic>;
    return body['results'] as Map<String, dynamic>;
  }

  group('POST /api/v1/machine/settings — per-field verification', () {
    test('reports an in-band write as applied', () async {
      await wireWith(MockDe1());

      final res = await post({'steamPurgeMode': 1});

      expect(res.statusCode, 202);
      final fields = await results(res);
      expect(fields['steamPurgeMode'], {
        'requested': 1,
        'actual': 1,
        'status': 'applied',
      });
    });

    test('reports the clamped fan write as adjusted with actual 50', () async {
      await wireWith(MockDe1());

      final res = await post({'fan': 51});

      expect(res.statusCode, 202);
      final fields = await results(res);
      expect(fields['fan'], {
        'requested': 51,
        'actual': 50,
        'status': 'adjusted',
      });
    });

    test('serialises exactly the documented wire shape', () async {
      await wireWith(MockDe1());

      final res = await post({'fan': 51, 'steamPurgeMode': 1});

      expect(res.statusCode, 202);
      expect(res.headers['content-type'], contains('application/json'));
      expect(jsonDecode(await res.readAsString()), {
        'results': {
          'fan': {'requested': 51, 'actual': 50, 'status': 'adjusted'},
          'steamPurgeMode': {'requested': 1, 'actual': 1, 'status': 'applied'},
        },
      });
    });

    test('localises the verdict per field within one request body', () async {
      await wireWith(MockDe1());

      final res = await post({'fan': 51, 'steamPurgeMode': 1});

      expect(res.statusCode, 202);
      final fields = await results(res);
      expect(fields['fan']['status'], 'adjusted');
      expect(fields['fan']['actual'], 50);
      expect(fields['steamPurgeMode']['status'], 'applied');
    });

    test('an in-band fan write is applied and readable via GET', () async {
      await wireWith(MockDe1());

      final res = await post({'fan': 45});
      expect(res.statusCode, 202);
      final fields = await results(res);
      expect(fields['fan']['status'], 'applied');
      expect(fields['fan']['actual'], 45);

      final read = await get();
      expect(read.statusCode, 200);
      final body = jsonDecode(await read.readAsString());
      expect(body['fan'], 45);
    });

    test('a write the machine ignores is adjusted, not applied', () async {
      final de1 = _IgnoresFanWrites();
      await wireWith(de1);
      final before = await de1.getFanThreshhold();

      final res = await post({'fan': 45});

      expect(res.statusCode, 202);
      final fields = await results(res);
      expect(fields['fan']['status'], 'adjusted');
      expect(fields['fan']['actual'], before);
    });

    test('a read-back timeout yields unverified, still 202', () async {
      await wireWith(_FanReadBackTimesOut());

      final res = await post({'fan': 45, 'steamPurgeMode': 1});

      expect(res.statusCode, 202);
      final fields = await results(res);
      expect(fields['fan'], {
        'requested': 45,
        'actual': null,
        'status': 'unverified',
      });
      expect(fields['steamPurgeMode']['status'], 'applied');
    });

    test('usb is reported as booleans', () async {
      await wireWith(MockDe1());

      final res = await post({'usb': 'enable'});

      expect(res.statusCode, 202);
      final fields = await results(res);
      expect(fields['usb'], {
        'requested': true,
        'actual': true,
        'status': 'applied',
      });
    });

    test('an empty body is 202 with an empty results map', () async {
      await wireWith(MockDe1());

      final res = await post(<String, dynamic>{});

      expect(res.statusCode, 202);
      expect(await results(res), isEmpty);
    });

    test('malformed JSON is still 400', () async {
      await wireWith(MockDe1());

      final res = await post('{not json');

      expect(res.statusCode, 400);
    });

    test('no DE1 connected is still 500', () async {
      await wireWith(null);

      final res = await post({'fan': 45});

      expect(res.statusCode, 500);
    });
  });
}
