import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/skin_feature/skin_view.dart';

void main() {
  group('skin WebView settings', () {
    test('pins text zoom so the system font size cannot rescale a skin', () {
      expect(createSkinWebViewSettings().textZoom, 100);
    });

    test('leaves zoom controls off so a skin keeps its own scaling', () {
      final settings = createSkinWebViewSettings();
      expect(settings.supportZoom, isFalse);
      expect(settings.builtInZoomControls, isFalse);
    });
  });
}
