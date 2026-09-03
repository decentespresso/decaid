import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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
