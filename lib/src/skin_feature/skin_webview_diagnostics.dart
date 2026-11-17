import 'package:flutter_inappwebview/flutter_inappwebview.dart';

const androidWebViewPluginVersion = '1.2.0-beta.3';

String skinCompositionName(bool textureComposition) =>
    textureComposition ? 'tlhc-with-hc-fallback' : 'hc';

Future<T?> _probe<T>(Future<T?> Function() read) async {
  try {
    return await read().timeout(const Duration(seconds: 5));
  } catch (_) {
    return null;
  }
}

Future<Map<String, Object?>> readSkinRenderingDiagnostics({
  required bool textureComposition,
  required Future<WebViewPackageInfo?> Function() readProvider,
  required Future<int?> Function() readSdk,
  required Future<InAppWebViewSettings?> Function() readSettings,
}) async {
  final provider = await _probe(readProvider);
  final sdk = await _probe(readSdk);
  final settings = await _probe(readSettings);
  return {
    'requestedMode': skinCompositionName(textureComposition),
    'actualComposition': 'not-exposed-by-plugin',
    'flutterVersion': const String.fromEnvironment(
      'FLUTTER_VERSION',
      defaultValue: 'unknown',
    ),
    'flutterRevision': const String.fromEnvironment(
      'FLUTTER_FRAMEWORK_REVISION',
      defaultValue: 'unknown',
    ),
    'androidPluginVersion': androidWebViewPluginVersion,
    'provider': provider?.toMap(),
    'sdk': sdk,
    'effectiveSettings': settings == null
        ? null
        : {
            'useHybridComposition': settings.useHybridComposition,
            'hardwareAcceleration': settings.hardwareAcceleration,
            'rendererPriorityPolicy': settings.rendererPriorityPolicy?.toMap(),
            'useOnRenderProcessGone': settings.useOnRenderProcessGone,
          },
  };
}
