import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/services/webserver_service.dart';
import 'package:reaprime/src/settings/settings_controller.dart';
import 'package:reaprime/src/webui_support/webui_service.dart';
import 'package:reaprime/src/webui_support/webui_storage.dart';
import 'package:shelf_plus/shelf_plus.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;

import '../../helpers/mock_device_scanner.dart';
import '../../helpers/mock_settings_service.dart';
import '../../helpers/test_scale.dart';
import '../../helpers/test_usb_hds.dart';

class _WebUI extends Fake implements WebUIService {
  @override
  String serverPath() => '/';
}

class _Storage extends Fake implements WebUIStorage {}

void main() {
  late MockSettingsService store;
  late SettingsController settings;
  late MockDeviceScanner scanner;
  late RouterPlus router;

  setUp(() async {
    store = MockSettingsService();
    settings = SettingsController(store);
    await settings.loadSettings();
    scanner = MockDeviceScanner();
    router = Router().plus;
    SettingsHandler(
      controller: settings,
      service: _WebUI(),
      webUIStorage: _Storage(),
      deviceScanner: scanner,
    ).addRoutes(router);
  });

  tearDown(() {
    settings.dispose();
    scanner.dispose();
  });

  Future<Response> updatePreference(String? id) async => router.call(
    Request(
      'POST',
      Uri.parse('http://localhost/api/v1/settings'),
      headers: {'content-type': 'application/json'},
      body: jsonEncode({'preferredScaleId': id}),
    ),
  );

  Future<String?> readPreference() async {
    final response = await router.call(
      Request('GET', Uri.parse('http://localhost/api/v1/settings')),
    );
    final body =
        jsonDecode(await response.readAsString()) as Map<String, dynamic>;
    return body['preferredScaleId'] as String?;
  }

  test(
    'USB HDS preference round-trips over a loopback HTTP connection',
    () async {
      final hds = TestUsbHds();
      scanner.addDevice(hds);
      final server = await shelf_io.serve(
        router.call,
        InternetAddress.loopbackIPv4,
        0,
      );
      final client = HttpClient();
      addTearDown(() async {
        client.close(force: true);
        await server.close(force: true);
        hds.dispose();
      });
      final uri = Uri.parse('http://127.0.0.1:${server.port}/api/v1/settings');
      final post = await client.postUrl(uri);
      post.headers.contentType = ContentType.json;
      post.write(jsonEncode({'preferredScaleId': hds.deviceId}));
      final updated = await post.close();
      expect(updated.statusCode, 200);
      await updated.drain<void>();
      final get = await client.getUrl(uri);
      final response = await get.close();
      expect(response.statusCode, 200);
      final body = jsonDecode(
        await utf8.decoder.bind(response).join(),
      ) as Map<String, dynamic>;
      expect(body['preferredScaleId'], hds.deviceId);
      expect(await store.preferredScaleId(), 'usb-hds:any');
    },
  );

  test(
    'discovered serial-less USB HDS saves a durable family preference',
    () async {
      final hds = TestUsbHds(deviceId: 'usb-1a86-7522-unknown-1004');
      scanner.addDevice(hds);
      addTearDown(hds.dispose);

      final response = await updatePreference(hds.deviceId);

      expect(response.statusCode, 200);
      expect(await store.preferredScaleId(), 'usb-hds:any');
      expect(await readPreference(), hds.deviceId);
    },
  );

  test(
    'explicit USB HDS family selector persists without a live scale',
    () async {
      expect((await updatePreference('usb-hds:any')).statusCode, 200);
      expect(await store.preferredScaleId(), 'usb-hds:any');
      expect(await readPreference(), 'usb-hds:any');

      final reloaded = SettingsController(store);
      await reloaded.loadSettings();
      expect(reloaded.preferredScaleId, 'usb-hds:any');
      reloaded.dispose();
    },
  );

  test(
    'multiple matching USB HDS attachments keep the family readback',
    () async {
      final first = TestUsbHds(deviceId: 'usb-1a86-7522-unknown-1004');
      final second = TestUsbHds(deviceId: 'usb-1a86-7522-unknown-1005');
      scanner.addDevice(first);
      scanner.addDevice(second);
      addTearDown(first.dispose);
      addTearDown(second.dispose);
      await settings.setPreferredScaleId('usb-hds:any');

      expect(await readPreference(), 'usb-hds:any');
      expect(await store.preferredScaleId(), 'usb-hds:any');

      scanner.removeDevice(second.deviceId);
      expect(await readPreference(), first.deviceId);
      expect(await store.preferredScaleId(), 'usb-hds:any');

      scanner.removeDevice(first.deviceId);
      expect(await readPreference(), 'usb-hds:any');
      expect(await store.preferredScaleId(), 'usb-hds:any');
    },
  );

  test(
    'readback projects only a protocol-identified serial-less USB HDS',
    () async {
      final stable = TestUsbHds(deviceId: 'usb-1a86-7522-KNOWN');
      final unsupported = TestScale(deviceId: 'usb-1a86-7522-unknown-1004');
      scanner.addDevice(stable);
      scanner.addDevice(unsupported);
      addTearDown(stable.dispose);
      addTearDown(unsupported.dispose);
      await settings.setPreferredScaleId('usb-hds:any');

      expect(await readPreference(), 'usb-hds:any');
      expect(await store.preferredScaleId(), 'usb-hds:any');
    },
  );

  test(
    'unsupported or absent session IDs are rejected instead of reporting saved',
    () async {
      await settings.setPreferredScaleId('saved-scale');
      final unsupported = TestScale(deviceId: 'usb-2e8a-a-unknown-7');
      scanner.addDevice(unsupported);
      addTearDown(unsupported.dispose);

      for (final id in [unsupported.deviceId, 'usb-1a86-7522-unknown-1004']) {
        final response = await updatePreference(id);
        expect(response.statusCode, 400);
        expect(settings.preferredScaleId, 'saved-scale');
        expect(await store.preferredScaleId(), 'saved-scale');
      }
    },
  );

  test(
    'stable scale IDs stay exact and null clears the family preference',
    () async {
      final hds = TestUsbHds(deviceId: 'usb-1a86-7522-KNOWN');
      scanner.addDevice(hds);
      addTearDown(hds.dispose);

      expect((await updatePreference(hds.deviceId)).statusCode, 200);
      expect(await store.preferredScaleId(), hds.deviceId);
      expect(await readPreference(), hds.deviceId);
      expect((await updatePreference('usb-hds:any')).statusCode, 200);
      expect((await updatePreference(null)).statusCode, 200);
      expect(await store.preferredScaleId(), isNull);
      expect(await readPreference(), isNull);
    },
  );
}
