import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:reaprime/src/settings/feature_flags.dart';
import 'package:reaprime/src/settings/settings_controller.dart';

class SkinWebViewComposition extends StatelessWidget {
  final SettingsController settings;
  final TargetPlatform platform;
  final Widget Function(BuildContext, bool textureComposition) builder;

  const SkinWebViewComposition({
    super.key,
    required this.settings,
    required this.platform,
    required this.builder,
  });

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: settings,
    builder: (context, _) {
      final texture =
          platform == TargetPlatform.android &&
          settings.isFeatureFlagEnabled(
            FeatureFlag.androidTextureLayerComposition,
          );
      return KeyedSubtree(
        key: ValueKey(texture),
        child: builder(context, texture),
      );
    },
  );
}

InAppWebViewSettings createSkinWebViewSettings({
  required TargetPlatform platform,
  required bool textureComposition,
}) => InAppWebViewSettings(
  javaScriptEnabled: true,
  javaScriptCanOpenWindowsAutomatically: false,
  mediaPlaybackRequiresUserGesture: false,
  allowFileAccessFromFileURLs: false,
  allowUniversalAccessFromFileURLs: false,
  useShouldOverrideUrlLoading: true,
  browserAcceleratorKeysEnabled: platform != TargetPlatform.windows,
  useHybridComposition:
      platform != TargetPlatform.android || !textureComposition,
  cacheEnabled: false,
  supportZoom: false,
  builtInZoomControls: false,
  enableViewportScale: true,
  verticalScrollBarEnabled: false,
  horizontalScrollBarEnabled: false,
  userAgent: 'Decent',
  rendererPriorityPolicy: RendererPriorityPolicy(
    rendererRequestedPriority: RendererPriority.RENDERER_PRIORITY_BOUND,
    waivedWhenNotVisible: false,
  ),
  useOnRenderProcessGone: true,
);
