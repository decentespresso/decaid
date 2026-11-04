import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:reaprime/src/skin_feature/skin_webview_composition.dart';

void main() {
  group('skin WebView settings', () {
    for (final platform in TargetPlatform.values) {
      for (final texture in [false, true]) {
        test('configures skin WebView for $platform, texture: $texture', () {
          final settings = createSkinWebViewSettings(
            platform: platform,
            textureComposition: texture,
          );
          final reason = '$platform, texture: $texture';

          expect(
            settings.overScrollMode,
            platform == TargetPlatform.android
                ? OverScrollMode.NEVER
                : OverScrollMode.IF_CONTENT_SCROLLS,
            reason: reason,
          );
          expect(
            settings.useHybridComposition,
            platform != TargetPlatform.android || !texture,
            reason: reason,
          );
          expect(settings.supportZoom, isFalse, reason: reason);
          expect(settings.builtInZoomControls, isFalse, reason: reason);
          expect(settings.textZoom, 100, reason: reason);
        });
      }
    }
  });
}
