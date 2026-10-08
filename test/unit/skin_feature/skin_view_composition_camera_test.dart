import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/device_controller.dart';
import 'package:reaprime/src/controllers/display_controller.dart';
import 'package:reaprime/src/services/webview_compatibility_checker.dart';
import 'package:reaprime/src/services/webview_log_service.dart';
import 'package:reaprime/src/settings/feature_flags.dart';
import 'package:reaprime/src/settings/settings_controller.dart';
import 'package:reaprime/src/skin_feature/skin_view.dart';

import '../../helpers/mock_de1_controller.dart';
import '../../helpers/mock_settings_service.dart';

class _WebViewPlatform extends InAppWebViewPlatform {
  @override
  PlatformInAppWebViewWidget createPlatformInAppWebViewWidget(
    PlatformInAppWebViewWidgetCreationParams params,
  ) => _WebView(params);

  @override
  PlatformWebViewEnvironment createPlatformWebViewEnvironmentStatic() =>
      _Environment();
}

class _Environment extends PlatformWebViewEnvironment {
  _Environment()
    : super.implementation(const PlatformWebViewEnvironmentCreationParams());

  @override
  Future<String?> getAvailableVersion({
    String? browserExecutableFolder,
  }) async => 'test';

  @override
  Future<void> dispose() async {}
}

class _WebView extends PlatformInAppWebViewWidget {
  _WebView(super.params) : super.implementation();

  @override
  Widget build(BuildContext context) => const SizedBox.expand();

  @override
  T controllerFromPlatform<T>(PlatformInAppWebViewController controller) =>
      InAppWebViewController.fromPlatform(platform: controller) as T;

  @override
  void dispose() {}
}

class _Controller extends PlatformInAppWebViewController {
  _Controller()
    : super.implementation(
        const PlatformInAppWebViewControllerCreationParams(id: 1),
      );
}

void main() {
  testWidgets('composition recreation retains camera permission restrictions', (
    tester,
  ) async {
    final previous = InAppWebViewPlatform.instance;
    InAppWebViewPlatform.instance = _WebViewPlatform();
    WebViewCompatibilityChecker.clearCache();
    final settings = SettingsController(MockSettingsService());
    final logs = WebViewLogService(logDirectoryPath: '.');
    final display = DisplayController(
      de1Controller: MockDe1Controller(controller: DeviceController(const [])),
      settingsController: settings,
      setBrightness: (_) async {},
      resetBrightness: () async {},
      enableWakeLock: () async {},
      disableWakeLock: () async {},
      platformSupport: const DisplayPlatformSupport(
        brightness: false,
        wakeLock: false,
      ),
    );
    addTearDown(() {
      display.dispose();
      settings.dispose();
      logs.dispose();
      WebViewCompatibilityChecker.clearCache();
      if (previous != null) InAppWebViewPlatform.instance = previous;
    });
    await tester.pumpWidget(
      MaterialApp(
        home: SkinView(
          settingsController: settings,
          webViewLogService: logs,
          deviceIp: '127.0.0.1',
          displayController: display,
          port: 24800,
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    for (final texture in [false, true, false]) {
      await settings.setFeatureFlag(
        FeatureFlag.androidTextureLayerComposition,
        texture,
      );
      await tester.pump();
      final params = tester
          .widget<InAppWebView>(find.byType(InAppWebView))
          .platform
          .params;
      expect(params.initialSettings!.useHybridComposition, !texture);
      expect(params.initialSettings!.allowFileAccessFromFileURLs, isFalse);
      expect(params.initialSettings!.allowUniversalAccessFromFileURLs, isFalse);
      expect(params.onPermissionRequest, isNotNull);
      expect(params.onRenderProcessGone, isNotNull);
      final response = await params.onPermissionRequest!(
        InAppWebViewController.fromPlatform(platform: _Controller()),
        PermissionRequest(
          origin: WebUri('http://localhost:24800'),
          resources: [PermissionResourceType.MICROPHONE],
        ),
      );
      expect(response!.action, PermissionResponseAction.DENY);
    }
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));
}
