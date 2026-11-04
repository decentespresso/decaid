import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:reaprime/src/skin_feature/skin_webview_composition.dart';

void main() {
  group('skin WebView settings', () {
    test('disables only Android overscroll and preserves other settings', () {
      for (final platform in TargetPlatform.values) {
        for (final texture in [false, true]) {
          final settings = createSkinWebViewSettings(
            platform: platform,
            textureComposition: texture,
          );
          expect(
            settings.overScrollMode,
            platform == TargetPlatform.android
                ? OverScrollMode.NEVER
                : OverScrollMode.IF_CONTENT_SCROLLS,
            reason: '$platform, texture: $texture',
          );
          final previousSettings = InAppWebViewSettings(
            javaScriptEnabled: true,
            javaScriptCanOpenWindowsAutomatically: false,
            mediaPlaybackRequiresUserGesture: false,
            allowFileAccessFromFileURLs: false,
            allowUniversalAccessFromFileURLs: false,
            useShouldOverrideUrlLoading: true,
            browserAcceleratorKeysEnabled: platform != TargetPlatform.windows,
            useHybridComposition:
                platform != TargetPlatform.android || !texture,
            cacheEnabled: false,
            supportZoom: false,
            builtInZoomControls: false,
            enableViewportScale: true,
            textZoom: 100,
            verticalScrollBarEnabled: false,
            horizontalScrollBarEnabled: false,
            userAgent: 'Decent',
            rendererPriorityPolicy: RendererPriorityPolicy(
              rendererRequestedPriority:
                  RendererPriority.RENDERER_PRIORITY_BOUND,
              waivedWhenNotVisible: false,
            ),
            useOnRenderProcessGone: true,
          );
          expect(
            settings.toMap()..remove('overScrollMode'),
            previousSettings.toMap()..remove('overScrollMode'),
            reason: '$platform, texture: $texture',
          );
        }
      }
    });

    for (final platform in TargetPlatform.values) {
      for (final texture in [false, true]) {
        test('preserves skin scaling for $platform, texture: $texture', () {
          final settings = createSkinWebViewSettings(
            platform: platform,
            textureComposition: texture,
          );
          expect(settings.textZoom, 100);
          expect(settings.supportZoom, isFalse);
          expect(settings.builtInZoomControls, isFalse);
        });
      }
    }
  });
}
