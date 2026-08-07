import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/skin_feature/simulated_webview_device.dart';

void main() {
  group('simulatedWebViewDevices', () {
    test('every selectable device round-trips through its persisted id', () {
      for (final device in simulatedWebViewDevices) {
        expect(
          simulatedWebViewDeviceById(device.id),
          same(device),
          reason:
              'Device "${device.name}" (${device.id}) is offered in the picker '
              'but cannot be reloaded from its persisted id.',
        );
      }
    });

    test('device ids are unique', () {
      final ids = simulatedWebViewDevices.map((d) => d.id).toList();
      expect(ids.toSet().length, ids.length);
    });

    test('unknown or null id resolves to null', () {
      expect(simulatedWebViewDeviceById('does-not-exist'), isNull);
      expect(simulatedWebViewDeviceById(null), isNull);
    });
  });
}
