import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/skin_feature/skin_view.dart';

void main() {
  group('skin WebView settings', () {
    test('pins text zoom so the system font size cannot rescale a skin', () {
      // Android applies the device's font-size setting to WebView text but not
      // to its layout, so leaving this unset grows a skin's type while the
      // boxes around it stay put and the text overflows them.
      expect(createSkinWebViewSettings().textZoom, 100);
    });

    test('leaves zoom controls off so a skin keeps its own scaling', () {
      final settings = createSkinWebViewSettings();
      expect(settings.supportZoom, isFalse);
      expect(settings.builtInZoomControls, isFalse);
    });
  });
}
