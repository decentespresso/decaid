import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/services/webserver_service.dart';
import 'package:reaprime/src/settings/settings_controller.dart';
import 'package:reaprime/src/webui_support/webui_service.dart';
import 'package:reaprime/src/webui_support/webui_storage.dart';
import 'package:shelf_plus/shelf_plus.dart';

import '../helpers/mock_settings_service.dart';

void main() {
  late SettingsController controller;
  late Handler handler;

  setUp(() async {
    controller = SettingsController(MockSettingsService());
    await controller.loadSettings();
    final app = Router().plus;
    SettingsHandler(
      controller: controller,
      service: WebUIService(),
      webUIStorage: WebUIStorage(controller),
    ).addRoutes(app);
    handler = app.call;
  });

  tearDown(() => controller.dispose());

  Future<Response> request(String method, String path, [Object? body]) async {
    return await handler(
      Request(
        method,
        Uri.parse('http://localhost$path'),
        body: body == null ? null : jsonEncode(body),
        headers: body == null ? null : {'content-type': 'application/json'},
      ),
    );
  }

  test('GET and POST expose per-device Skale USB settings', () async {
    final before = await request('GET', '/api/v1/settings');
    final beforeJson = jsonDecode(await before.readAsString()) as Map;
    expect(beforeJson['skalePoweredByUsbByDevice'], isEmpty);
    expect(beforeJson, isNot(contains('skalePoweredByUsb')));

    final update = await request('POST', '/api/v1/settings', {
      'skalePoweredByUsbByDevice': {'skale-a': true, 'skale-b': false},
    });
    expect(update.statusCode, 200);

    final after = await request('GET', '/api/v1/settings');
    final afterJson = jsonDecode(await after.readAsString()) as Map;
    expect(afterJson['skalePoweredByUsbByDevice'], {'skale-a': true});
    expect(afterJson, isNot(contains('skalePoweredByUsb')));
  });

  test('POST rejects invalid per-device Skale USB settings', () async {
    final response = await request('POST', '/api/v1/settings', {
      'skalePoweredByUsbByDevice': {'skale-a': 'true'},
    });
    expect(response.statusCode, 400);
  });

  test('POST rejects the removed global Skale USB setting', () async {
    final response = await request('POST', '/api/v1/settings', {
      'skalePoweredByUsb': true,
    });
    expect(response.statusCode, 400);
  });
}
