import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/settings/settings_controller.dart';
import 'package:reaprime/src/webui_support/webui_storage.dart';

import 'helpers/mock_settings_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('diagnostics skin registration follows the build flag', () async {
    final directory = Directory.systemTemp.createTempSync(
      'diagnostics_skin_test',
    );
    try {
      final settings = SettingsController(MockSettingsService());
      await settings.loadSettings();
      final storage = WebUIStorage(settings, webUIDir: directory);
      await storage.initialize(downloadRemote: false);

      final skin = storage.getSkin('ble-reconnect-diagnostics');
      if (WebUIStorage.diagnosticsSkinEnabled) {
        expect(skin, isNotNull);
        expect(skin!.isBundled, isTrue);
      } else {
        expect(skin, isNull);
      }
    } finally {
      directory.deleteSync(recursive: true);
    }
  });

  test(
    'bundled diagnostics skin contains the capture/report harness',
    () async {
      final html = await rootBundle.loadString(
        'assets/ble-reconnect-diagnostics/index.html',
      );
      final manifest = await rootBundle.loadString(
        'assets/ble-reconnect-diagnostics/manifest.json',
      );

      expect(manifest, contains('ble-reconnect-diagnostics'));
      expect(html, contains('/api/v1/info'));
      expect(html, contains('/api/v1/diagnostics/ble'));
      expect(html, contains('/ws/v1/devices'));
      expect(html, contains('/ws/v1/machine/snapshot'));
      expect(html, contains('physical marker'));
      expect(html, contains('/api/v1/devices/scan?connect='));
      expect(html, contains('report.diagnostics'));
      expect(html, contains('report.probes'));
    },
  );
}
