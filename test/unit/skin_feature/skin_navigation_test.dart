import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/device_controller.dart';
import 'package:reaprime/src/controllers/display_controller.dart';
import 'package:reaprime/src/launcher/launcher_view.dart';
import 'package:reaprime/src/services/webview_log_service.dart';
import 'package:reaprime/src/settings/settings_controller.dart';
import 'package:reaprime/src/skin_feature/skin_view.dart';
import 'package:reaprime/src/webui_support/webui_service.dart';

import '../../helpers/mock_de1_controller.dart';
import '../../helpers/mock_settings_service.dart';

DisplayController _createDisplayController(
  SettingsController settingsController,
) {
  return DisplayController(
    de1Controller: MockDe1Controller(controller: DeviceController(const [])),
    settingsController: settingsController,
    setBrightness: (_) async {},
    resetBrightness: () async {},
    enableWakeLock: () async {},
    disableWakeLock: () async {},
    platformSupport: const DisplayPlatformSupport(
      brightness: false,
      wakeLock: false,
    ),
  );
}

void main() {
  test('skin exit guide explains Android navigation and Dashboard purpose', () {
    final instructions = skinExitInstructions(TargetPlatform.android);

    expect(instructions, contains('settings and skin selection'));
    expect(instructions, contains('Swipe inward from either screen edge'));
    expect(instructions, contains('reveal the navigation bar'));
    expect(instructions, contains('tap Back'));
  });

  test('skin exit guide points Windows users to the system menu', () {
    final instructions = skinExitInstructions(TargetPlatform.windows);

    expect(instructions, contains('Windows system menu'));
    expect(instructions, contains('Back to Dashboard'));
    expect(instructions, isNot(contains('Alt+Backspace')));
    expect(instructions, isNot(contains('Alt+Space')));
  });

  testWidgets('system back exits directly to Dashboard without an overlay', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final navigatorKey = GlobalKey<NavigatorState>();
    final webViewLogService = WebViewLogService(logDirectoryPath: '.');
    final settingsController = SettingsController(MockSettingsService());
    final displayController = _createDisplayController(settingsController);
    addTearDown(webViewLogService.dispose);
    addTearDown(displayController.dispose);

    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigatorKey,
        home: const Scaffold(body: Text('Dashboard')),
        routes: {
          LauncherView.routeName: (_) =>
              const Scaffold(body: Text('Dashboard')),
          '/skins-test': (_) => const Scaffold(body: Text('Skins')),
          SkinView.routeName: (_) => SkinView(
            settingsController: settingsController,
            webViewLogService: webViewLogService,
            deviceIp: '127.0.0.1',
            displayController: displayController,
            port: 43210,
            webView: const SizedBox.expand(key: Key('webview')),
          ),
        },
      ),
    );
    navigatorKey.currentState!.pushNamed('/skins-test');
    await tester.pumpAndSettle();
    SkinView.open(navigatorKey.currentState!);
    await tester.pump();

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    expect(find.text('Dashboard'), findsOneWidget);
    expect(find.text('Skins'), findsNothing);

    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    navigatorKey.currentState!.pushNamed('/skins-test');
    await tester.pumpAndSettle();
    SkinView.open(navigatorKey.currentState!);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    debugDefaultTargetPlatformOverride = null;

    expect(
      tester.getSize(find.byKey(const Key('webview'))),
      const Size(1600, 900),
    );
    expect(find.byTooltip('Open Dashboard'), findsNothing);
  });

  testWidgets('iOS edge swipe exits directly to Dashboard', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final navigatorKey = GlobalKey<NavigatorState>();
    final webViewLogService = WebViewLogService(logDirectoryPath: '.');
    final settingsController = SettingsController(MockSettingsService());
    final displayController = _createDisplayController(settingsController);
    addTearDown(webViewLogService.dispose);
    addTearDown(displayController.dispose);

    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigatorKey,
        home: const Scaffold(body: Text('Dashboard')),
        routes: {
          LauncherView.routeName: (_) =>
              const Scaffold(body: Text('Dashboard')),
          '/skins-test': (_) => const Scaffold(body: Text('Skins')),
          SkinView.routeName: (_) => SkinView(
            settingsController: settingsController,
            webViewLogService: webViewLogService,
            deviceIp: '127.0.0.1',
            displayController: displayController,
            port: 43210,
            webView: const SizedBox.expand(key: Key('webview')),
          ),
        },
      ),
    );
    navigatorKey.currentState!.pushNamed('/skins-test');
    await tester.pumpAndSettle();
    SkinView.open(navigatorKey.currentState!);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    await tester.dragFrom(const Offset(1, 450), const Offset(800, 0));
    await tester.pumpAndSettle();

    expect(find.text('Dashboard'), findsOneWidget);
    expect(find.text('Skins'), findsNothing);
    expect(find.byType(SkinView), findsNothing);
    debugDefaultTargetPlatformOverride = null;
  });

  group('classifySkinNavigation', () {
    test('allows the active skin origin and its sub-paths', () {
      expect(
        classifySkinNavigation(
          Uri.parse('http://localhost:43210/'),
          skinPort: 43210,
        ),
        SkinNavDecision.allow,
      );
      expect(
        classifySkinNavigation(
          Uri.parse('http://localhost:43210/foo?x=1'),
          skinPort: 43210,
        ),
        SkinNavDecision.allow,
      );
      expect(
        classifySkinNavigation(
          Uri.parse('http://localhost:3000/'),
          skinPort: 43210,
        ),
        SkinNavDecision.allow,
      );
    });

    test('allows the settings plugin path', () {
      expect(
        classifySkinNavigation(
          Uri.parse('http://localhost:8080/api/v1/plugins/settings.reaplugin'),
        ),
        SkinNavDecision.allow,
      );
    });

    test('exits to the dashboard for the exact skin exit URL', () {
      final url = skinExitDashboardUrlForPort(43210);
      expect(
        classifySkinNavigation(Uri.parse(url), skinPort: 43210),
        SkinNavDecision.exitDashboard,
      );
    });

    test('blocks extended and malformed skin exit URLs', () {
      final url = skinExitDashboardUrlForPort(43210);
      for (final url in [
        '$url/path',
        '$url?unexpected=true',
        '$url#fragment',
        'http://user@localhost:43210$skinExitDashboardPath',
        'http://localhost:43211$skinExitDashboardPath',
        'http://localhost$skinExitDashboardPath',
        'https://localhost:43210$skinExitDashboardPath',
        'http://example.com:43210$skinExitDashboardPath',
      ]) {
        expect(
          classifySkinNavigation(Uri.parse(url), skinPort: 43210),
          isNot(SkinNavDecision.exitDashboard),
          reason: url,
        );
      }
    });

    test('opens external https links in the browser', () {
      expect(
        classifySkinNavigation(
          Uri.parse('https://decentespresso.com/doc/quickstart/'),
        ),
        SkinNavDecision.openExternal,
      );
    });

    test('opens external (non-localhost) http links in the browser', () {
      expect(
        classifySkinNavigation(Uri.parse('http://example.com/page')),
        SkinNavDecision.openExternal,
      );
    });

    test('blocks non-http schemes', () {
      expect(
        classifySkinNavigation(Uri.parse('mailto:hi@example.com')),
        SkinNavDecision.block,
      );
      expect(
        classifySkinNavigation(Uri.parse('tel:+123')),
        SkinNavDecision.block,
      );
    });

    test('blocks a null url', () {
      expect(classifySkinNavigation(null), SkinNavDecision.block);
    });
  });

  test('only main-frame load errors replace the skin', () {
    expect(shouldShowSkinLoadError(false), isFalse);
    expect(shouldShowSkinLoadError(true), isTrue);
    expect(shouldShowSkinLoadError(null), isTrue);
  });

  group('SkinExitCoordinator', () {
    final target = Uri.parse(skinExitDashboardUrlForPort(43210));
    final trustedPage = Uri.parse('http://localhost:43210/?_=123');

    test('accepts one trusted main-frame request', () {
      final coordinator = SkinExitCoordinator();

      expect(
        coordinator.tryStart(
          target: target,
          isForMainFrame: true,
          topLevelUri: trustedPage,
          skinPort: 43210,
        ),
        isTrue,
      );
      expect(
        coordinator.tryStart(
          target: target,
          isForMainFrame: true,
          topLevelUri: trustedPage,
          skinPort: 43210,
        ),
        isFalse,
      );
      expect(coordinator.inProgress, isTrue);
    });

    test('rejects subframes and untrusted top-level origins', () {
      expect(
        SkinExitCoordinator().tryStart(
          target: target,
          isForMainFrame: false,
          topLevelUri: trustedPage,
          skinPort: 43210,
        ),
        isFalse,
      );
      expect(
        SkinExitCoordinator().tryStart(
          target: target,
          isForMainFrame: true,
          topLevelUri: Uri.parse('http://example.com:43210/'),
          skinPort: 43210,
        ),
        isFalse,
      );
    });
  });
}
