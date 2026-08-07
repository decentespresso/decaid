import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/services/android_updater.dart';
import 'package:reaprime/src/services/update_check_service.dart';
import 'package:reaprime/src/services/webserver_service.dart';
import 'package:reaprime/src/settings/settings_controller.dart';
import 'package:reaprime/src/webui_support/webui_storage.dart';
import 'package:shelf_plus/shelf_plus.dart';

import 'helpers/mock_settings_service.dart';

class _NoopUpdater extends AndroidUpdater {
  _NoopUpdater() : super(owner: 'tadelv', repo: 'reaprime');
  @override
  Future<UpdateInfo?> checkForUpdate(
    String v, {
    UpdateChannel channel = UpdateChannel.stable,
  }) async => null;
  @override
  void dispose() {}
}

void main() {
  late UpdateCheckService service;
  late UpdateHandler updateHandler;
  late Handler handler;

  UpdateCheckService buildService({required bool isAndroid}) {
    final settingsController = SettingsController(MockSettingsService());
    return UpdateCheckService(
      settingsService: MockSettingsService(),
      webUIStorage: WebUIStorage(settingsController),
      updater: _NoopUpdater(),
      platformIsAndroid: isAndroid,
      platformIsMacOS: false,
    );
  }

  setUp(() {
    service = buildService(isAndroid: true);
    updateHandler = UpdateHandler(service: service);
    final app = Router().plus;
    updateHandler.addRoutes(app);
    handler = app.call;
  });

  tearDown(() => service.dispose());

  Future<Response> sendGet(String path) async =>
      await handler(Request('GET', Uri.parse('http://localhost$path')));

  group('GET /api/v1/update', () {
    test('returns the current state snapshot', () async {
      final response = await sendGet('/api/v1/update');
      expect(response.statusCode, 200);
      expect(response.headers['content-type'], contains('application/json'));

      final body = jsonDecode(await response.readAsString());
      expect(body['phase'], 'idle');
      expect(body['currentVersion'], isA<String>());
      expect(body['releaseUrl'], contains('releases'));
      expect(body['installable'], false);
    });
  });

  group('handleCommand', () {
    test('unknown command yields an error reply', () {
      final replies = <Map<String, dynamic>>[];
      updateHandler.handleCommand({'command': 'bogus'}, replies.add);
      expect(replies.single['error'], contains('Unknown command'));
    });

    test('missing command field yields an error reply', () {
      final replies = <Map<String, dynamic>>[];
      updateHandler.handleCommand({}, replies.add);
      expect(replies.single['error'], contains('Missing'));
    });

    test('install on non-Android replies with not-supported + url', () {
      final nonAndroid = buildService(isAndroid: false);
      final h = UpdateHandler(service: nonAndroid);
      final replies = <Map<String, dynamic>>[];

      h.handleCommand({'command': 'install'}, replies.add);

      expect(replies.single['error'], contains('not supported'));
      expect(replies.single['url'], contains('releases'));
      nonAndroid.dispose();
    });
  });
}
