import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/launcher/launcher_view.dart';
import 'package:reaprime/src/services/webview_log_service.dart';
import 'package:reaprime/src/settings/settings_controller.dart';
import 'package:reaprime/src/skin_feature/skin_view.dart';
import 'package:reaprime/src/webui_support/webui_service.dart';

import '../../helpers/mock_settings_service.dart';

void main() {
  test('skin exit guide explains Android navigation and Dashboard purpose', () {
    final instructions = skinExitInstructions(TargetPlatform.android);

    expect(instructions, contains('settings and skin selection'));
    expect(instructions, contains('Swipe inward from either screen edge'));
    expect(instructions, contains('reveal the navigation bar'));
    expect(instructions, contains('tap Back'));
  });

  test('skin exit guide points Windows users to the Dashboard button', () {
    final instructions = skinExitInstructions(TargetPlatform.windows);

    expect(instructions, contains('Dashboard button'));
    expect(instructions, isNot(contains('Alt+Backspace')));
  });

  testWidgets('system back and Windows button exit directly to Dashboard', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final navigatorKey = GlobalKey<NavigatorState>();
    final webViewLogService = WebViewLogService(logDirectoryPath: '.');
    addTearDown(webViewLogService.dispose);

    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigatorKey,
        home: const Scaffold(body: Text('Dashboard')),
        routes: {
          LauncherView.routeName: (_) =>
              const Scaffold(body: Text('Dashboard')),
          '/skins-test': (_) => const Scaffold(body: Text('Skins')),
          SkinView.routeName: (_) => SkinView(
            settingsController: SettingsController(MockSettingsService()),
            webViewLogService: webViewLogService,
            deviceIp: '127.0.0.1',
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
    await tester.tap(find.byTooltip('Open Dashboard'));
    await tester.pumpAndSettle();

    expect(find.text('Dashboard'), findsOneWidget);
    expect(find.text('Skins'), findsNothing);
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
    addTearDown(webViewLogService.dispose);

    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigatorKey,
        home: const Scaffold(body: Text('Dashboard')),
        routes: {
          LauncherView.routeName: (_) =>
              const Scaffold(body: Text('Dashboard')),
          '/skins-test': (_) => const Scaffold(body: Text('Skins')),
          SkinView.routeName: (_) => SkinView(
            settingsController: SettingsController(MockSettingsService()),
            webViewLogService: webViewLogService,
            deviceIp: '127.0.0.1',
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
    test('allows localhost:3000 and its sub-paths', () {
      expect(
        classifySkinNavigation(Uri.parse('http://localhost:3000/')),
        SkinNavDecision.allow,
      );
      expect(
        classifySkinNavigation(Uri.parse('http://localhost:3000/foo?x=1')),
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
      expect(
        classifySkinNavigation(Uri.parse(skinExitDashboardUrl)),
        SkinNavDecision.exitDashboard,
      );
    });

    test('blocks extended and malformed skin exit URLs', () {
      for (final url in [
        '$skinExitDashboardUrl/path',
        '$skinExitDashboardUrl?unexpected=true',
        '$skinExitDashboardUrl#fragment',
        'http://user@localhost:3000$skinExitDashboardPath',
        'http://localhost:3001$skinExitDashboardPath',
        'http://localhost$skinExitDashboardPath',
        'https://localhost:3000$skinExitDashboardPath',
        'http://example.com:3000$skinExitDashboardPath',
      ]) {
        expect(
          classifySkinNavigation(Uri.parse(url)),
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

  group('SkinExitCoordinator', () {
    final target = Uri.parse(skinExitDashboardUrl);
    final trustedPage = Uri.parse('http://localhost:3000/?_=123');

    test('accepts one trusted main-frame request', () {
      final coordinator = SkinExitCoordinator();

      expect(
        coordinator.tryStart(
          target: target,
          isForMainFrame: true,
          topLevelUri: trustedPage,
        ),
        isTrue,
      );
      expect(
        coordinator.tryStart(
          target: target,
          isForMainFrame: true,
          topLevelUri: trustedPage,
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
        ),
        isFalse,
      );
      expect(
        SkinExitCoordinator().tryStart(
          target: target,
          isForMainFrame: true,
          topLevelUri: Uri.parse('http://example.com:3000/'),
        ),
        isFalse,
      );
    });
  });
}
