import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/de1_controller.dart';
import 'package:reaprime/src/controllers/device_controller.dart';
import 'package:reaprime/src/controllers/presence_controller.dart';
import 'package:reaprime/src/models/wake_schedule.dart';
import 'package:reaprime/src/settings/settings_controller.dart';
import 'package:reaprime/src/services/webserver_service.dart';
import 'package:shelf_plus/shelf_plus.dart';

import '../../helpers/mock_device_discovery_service.dart';
import '../../helpers/mock_settings_service.dart';

void main() {
  late Handler handler;
  late SettingsController settingsController;
  late MockSettingsService mockService;

  void wire() {
    mockService = MockSettingsService();
    settingsController = SettingsController(mockService);

    final deviceController = DeviceController([MockDeviceDiscoveryService()]);
    final de1Controller = De1Controller(controller: deviceController);

    final pc = PresenceController(
      de1Controller: de1Controller,
      settingsController: settingsController,
    );
    final ph = PresenceHandler(
      presenceController: pc,
      settingsController: settingsController,
    );
    final app = Router().plus;
    ph.addRoutes(app);
    handler = app.call;
  }

  Future<Response> post(String path, Object? body) async => await handler(
    Request(
      'POST',
      Uri.parse('http://localhost$path'),
      body: body != null ? jsonEncode(body) : null,
      headers: body != null
          ? {HttpHeaders.contentTypeHeader: 'application/json'}
          : null,
    ),
  );

  Future<Response> get(String path) async =>
      await handler(Request('GET', Uri.parse('http://localhost$path')));

  Future<Map<String, dynamic>> getSettings() async {
    final res = await get('/api/v1/presence/settings');
    return jsonDecode(await res.readAsString()) as Map<String, dynamic>;
  }

  group('POST /api/v1/presence/settings', () {
    setUp(() async {
      wire();
      await settingsController.loadSettings();
    });

    test('accepts valid boolean-only partial update', () async {
      final res = await post('/api/v1/presence/settings', {
        'userPresenceEnabled': false,
      });
      expect(res.statusCode, 200);
      final body = jsonDecode(await res.readAsString());
      expect(body['userPresenceEnabled'], false);
      expect(settingsController.userPresenceEnabled, false);
      expect(settingsController.sleepTimeoutMinutes, 30);
    });

    test('accepts valid timeout-only partial update', () async {
      final res = await post('/api/v1/presence/settings', {
        'sleepTimeoutMinutes': 37,
      });
      expect(res.statusCode, 200);
      final body = jsonDecode(await res.readAsString());
      expect(body['sleepTimeoutMinutes'], 37);
      expect(settingsController.sleepTimeoutMinutes, 37);
    });

    test('accepts combined update', () async {
      final res = await post('/api/v1/presence/settings', {
        'userPresenceEnabled': false,
        'sleepTimeoutMinutes': 60,
      });
      expect(res.statusCode, 200);
      final body = jsonDecode(await res.readAsString());
      expect(body['userPresenceEnabled'], false);
      expect(body['sleepTimeoutMinutes'], 60);
    });

    test('normalizes timeout above 240 to 240', () async {
      final res = await post('/api/v1/presence/settings', {
        'sleepTimeoutMinutes': 999,
      });
      expect(res.statusCode, 200);
      final body = jsonDecode(await res.readAsString());
      expect(body['sleepTimeoutMinutes'], 240);
      expect(settingsController.sleepTimeoutMinutes, 240);
    });

    test('normalizes negative timeout to 0', () async {
      final res = await post('/api/v1/presence/settings', {
        'sleepTimeoutMinutes': -10,
      });
      expect(res.statusCode, 200);
      final body = jsonDecode(await res.readAsString());
      expect(body['sleepTimeoutMinutes'], 0);
      expect(settingsController.sleepTimeoutMinutes, 0);
    });

    test('rejects timeout string with 400', () async {
      final res = await post('/api/v1/presence/settings', {
        'sleepTimeoutMinutes': '30',
      });
      expect(res.statusCode, 400);
    });

    test('rejects timeout double with 400', () async {
      final res = await post('/api/v1/presence/settings', {
        'sleepTimeoutMinutes': 30.5,
      });
      expect(res.statusCode, 400);
    });

    test('rejects timeout null with 400', () async {
      final res = await post('/api/v1/presence/settings', {
        'sleepTimeoutMinutes': null,
      });
      expect(res.statusCode, 400);
    });

    test('rejects non-boolean userPresenceEnabled with 400', () async {
      final res = await post('/api/v1/presence/settings', {
        'userPresenceEnabled': 'true',
      });
      expect(res.statusCode, 400);
    });

    test('rejects malformed JSON with 400', () async {
      final res = await handler(
        Request(
          'POST',
          Uri.parse('http://localhost/api/v1/presence/settings'),
          body: '{bad json',
          headers: {HttpHeaders.contentTypeHeader: 'application/json'},
        ),
      );
      expect(res.statusCode, 400);
    });

    test('rejects JSON array root with 400', () async {
      final res = await post('/api/v1/presence/settings', [1, 2, 3]);
      expect(res.statusCode, 400);
    });

    test('rejects JSON string root with 400', () async {
      final res = await post('/api/v1/presence/settings', 'hello');
      expect(res.statusCode, 400);
    });

    test('rejects JSON null root with 400', () async {
      final res = await post('/api/v1/presence/settings', null);
      expect(res.statusCode, 400);
    });

    test(
      'mixed valid and invalid fields return 400 and change nothing',
      () async {
        await settingsController.setUserPresenceEnabled(false);
        await settingsController.setSleepTimeoutMinutes(45);

        final res = await post('/api/v1/presence/settings', {
          'userPresenceEnabled': true,
          'sleepTimeoutMinutes': '30',
        });
        expect(res.statusCode, 400);

        expect(settingsController.userPresenceEnabled, false);
        expect(settingsController.sleepTimeoutMinutes, 45);
      },
    );

    test('rejected request preserves previous values', () async {
      await settingsController.setUserPresenceEnabled(false);
      await settingsController.setSleepTimeoutMinutes(120);

      final res = await post('/api/v1/presence/settings', {
        'sleepTimeoutMinutes': 'abc',
      });
      expect(res.statusCode, 400);

      final settings = await getSettings();
      expect(settings['userPresenceEnabled'], false);
      expect(settings['sleepTimeoutMinutes'], 120);
    });
  });

  group('POST /api/v1/presence/schedules', () {
    setUp(() async {
      wire();
      await settingsController.loadSettings();
    });

    Future<Response> put(String path, Object? body) async => await handler(
      Request(
        'PUT',
        Uri.parse('http://localhost$path'),
        body: body != null ? jsonEncode(body) : null,
        headers: body != null
            ? {HttpHeaders.contentTypeHeader: 'application/json'}
            : null,
      ),
    );

    test('accepts a valid schedule', () async {
      final res = await post('/api/v1/presence/schedules', {
        'time': '07:30',
        'daysOfWeek': [1, 7],
        'enabled': true,
        'keepAwakeFor': 45,
      });
      expect(res.statusCode, 201);
    });

    test('rejects an hour above 23 with 400', () async {
      final res = await post('/api/v1/presence/schedules', {'time': '25:00'});
      expect(res.statusCode, 400);
    });

    test('rejects a minute above 59 with 400', () async {
      final res = await post('/api/v1/presence/schedules', {'time': '07:60'});
      expect(res.statusCode, 400);
    });

    test('rejects out-of-range weekdays with 400', () async {
      final res = await post('/api/v1/presence/schedules', {
        'time': '07:30',
        'daysOfWeek': [0, 8],
      });
      expect(res.statusCode, 400);
    });

    test('a rejected schedule changes nothing', () async {
      await settingsController.setWakeSchedules('[]');
      final res = await post('/api/v1/presence/schedules', {'time': '25:00'});
      expect(res.statusCode, 400);
      expect(settingsController.wakeSchedules, '[]');
    });

    test('update rejects an out-of-range weekday with 400', () async {
      await post('/api/v1/presence/schedules', {
        'time': '07:30',
        'daysOfWeek': [1],
      });
      final schedules = WakeSchedule.deserializeList(
        settingsController.wakeSchedules,
      );
      final id = schedules.single.id;

      final res = await put('/api/v1/presence/schedules/$id', {
        'daysOfWeek': [9],
      });
      expect(res.statusCode, 400);
    });
  });
}
