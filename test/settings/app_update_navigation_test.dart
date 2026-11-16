import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/device_controller.dart';
import 'package:reaprime/src/controllers/display_controller.dart';
import 'package:reaprime/src/controllers/presence_controller.dart';
import 'package:reaprime/src/launcher/launcher_view.dart';
import 'package:reaprime/src/notifications/notification_actions.dart';
import 'package:reaprime/src/notifications/notification_center.dart';
import 'package:reaprime/src/notifications/notification_overlay.dart';
import 'package:reaprime/src/notifications/update_notifications.dart';
import 'package:reaprime/src/services/android_updater.dart';
import 'package:reaprime/src/services/app_update_state.dart';
import 'package:reaprime/src/services/update_check_service.dart';
import 'package:reaprime/src/services/webview_log_service.dart';
import 'package:reaprime/src/settings/settings_controller.dart';
import 'package:reaprime/src/settings/settings_view.dart';
import 'package:reaprime/src/settings/update_dialog.dart';
import 'package:reaprime/src/skin_feature/skin_view.dart';
import 'package:reaprime/src/webui_support/webui_storage.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import '../helpers/mock_de1_controller.dart';
import '../helpers/mock_settings_service.dart';

final _update = UpdateInfo(
  version: '99.0.0',
  downloadUrl: 'https://example.test/update.apk',
  releaseNotes: 'Changes',
  isPrerelease: false,
  tagName: 'v99.0.0',
);

class _Updater extends AndroidUpdater {
  _Updater() : super(owner: 'decentespresso', repo: 'decaid');

  UpdateInfo? update = _update;
  int checks = 0;
  int downloads = 0;
  int installations = 0;
  final download = Completer<String>();
  Completer<UpdateInfo?>? checkGate;
  void Function(double)? progress;

  @override
  Future<UpdateInfo?> checkForUpdate(
    String currentVersion, {
    UpdateChannel channel = UpdateChannel.stable,
  }) async {
    checks++;
    if (checkGate case final gate?) return gate.future;
    return update;
  }

  @override
  Future<String> downloadUpdate(
    UpdateInfo update, {
    Function(double)? onProgress,
    Directory? cacheDir,
  }) {
    downloads++;
    progress = onProgress;
    return download.future;
  }

  @override
  Future<bool> installUpdate(String path) async {
    installations++;
    return false;
  }
}

class _OfflineStorage extends WebUIStorage {
  _OfflineStorage(super.settingsController);

  @override
  Future<void> downloadRemoteSkins() async {}
}

class _WebView extends StatelessWidget {
  const _WebView({required this.center, required this.actions});

  final NotificationCenter center;
  final NotificationActions actions;

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.topLeft,
    child: TextButton(
      onPressed: () => showNotifications(context, center, actions),
      child: const Text('Open notifications'),
    ),
  );
}

Future<void> _pumpRoute(WidgetTester tester) async {
  for (var transition = 0; transition < 5; transition++) {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  }
}

Future<(GlobalKey<NavigatorState>, _Updater, UpdateCheckService)> _mount(
  WidgetTester tester, {
  bool skin = false,
  bool available = true,
  bool android = true,
}) async {
  final preferences = MockSettingsService();
  final settings = SettingsController(preferences);
  await settings.loadSettings();
  final de1 = MockDe1Controller(controller: DeviceController(const []));
  final presence = PresenceController(
    de1Controller: de1,
    settingsController: settings,
  );
  final display = DisplayController(
    de1Controller: de1,
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
  final logs = WebViewLogService(logDirectoryPath: '.');
  final updater = _Updater()..update = available ? _update : null;
  final storage = _OfflineStorage(settings);
  final service = UpdateCheckService(
    settingsService: preferences,
    webUIStorage: storage,
    updater: updater,
    platformIsAndroid: android,
    platformIsMacOS: false,
    externallyManaged: false,
  );
  final center = (await tester.runAsync(() async => NotificationCenter()))!;
  final actions = NotificationActions(
    center: center,
    updateCheckService: service,
    onOpenAccount: () {},
    launch: (_) async {
      fail('Viewing an app update must not open an external browser');
    },
  );
  final navigator = GlobalKey<NavigatorState>();
  final notifications = (await tester.runAsync(() async {
    final notifications = UpdateNotifications(
      center: center,
      service: service,
      onView: (update) =>
          SettingsView.openUpdate(navigator.currentState!, update.version),
    );
    if (available) await service.checkForUpdate();
    await notifications.settled;
    return notifications;
  }))!;
  addTearDown(() async {
    await tester.runAsync(() => notifications.dispose());
    actions.dispose();
    center.dispose();
    service.dispose();
    presence.dispose();
    display.dispose();
    logs.dispose();
    settings.dispose();
  });
  await tester.pumpWidget(
    ShadApp(
      navigatorKey: navigator,
      builder: (_, child) => ScaffoldMessenger(child: child!),
      initialRoute: LauncherView.routeName,
      onGenerateRoute: (route) => MaterialPageRoute<void>(
        settings: route,
        builder: (context) => switch (route.name) {
          SettingsView.routeName => SettingsView(
            controller: settings,
            presenceController: presence,
            updateCheckService: service,
            webUIStorage: storage,
            updateVersion: route.arguments as String?,
          ),
          SkinView.routeName => SkinView(
            settingsController: settings,
            webViewLogService: logs,
            deviceIp: '127.0.0.1',
            displayController: display,
            port: 43210,
            webView: _WebView(center: center, actions: actions),
          ),
          _ => Scaffold(
            body: Column(
              children: [
                const Text('Dashboard'),
                _WebView(center: center, actions: actions),
              ],
            ),
          ),
        },
      ),
    ),
  );
  await _pumpRoute(tester);
  if (skin) {
    unawaited(navigator.currentState!.pushNamed(SkinView.routeName));
    await _pumpRoute(tester);
    expect(find.byType(SkinView), findsOneWidget);
  }
  return (navigator, updater, service);
}

void main() {
  for (final skin in [false, true]) {
    testWidgets(
      'app-update View from ${skin ? 'skin' : 'dashboard'} uses shared progress',
      (tester) async {
        final (navigator, updater, service) = await _mount(tester, skin: skin);
        await tester.tap(find.text('Open notifications'));
        await _pumpRoute(tester);
        expect(find.byType(NotificationOverlay), findsOneWidget);
        expect(find.text('Download'), findsNothing);
        await tester.tap(find.text('View'));
        await _pumpRoute(tester);

        expect(find.byType(NotificationOverlay), findsNothing);
        expect(find.byType(SkinView, skipOffstage: false), findsNothing);
        expect(find.byType(SettingsView), findsOneWidget);
        expect(find.byType(UpdateDialog), findsOneWidget);
        expect(find.text('Version 99.0.0'), findsOneWidget);
        expect(updater.downloads, 0);
        expect(updater.installations, 0);

        await tester.tap(find.text('Download'));
        await tester.tap(find.text('Download'));
        await tester.pump();
        updater.progress!(0.42);
        await tester.pump();
        expect(updater.downloads, 1);
        expect(
          tester
              .widget<LinearProgressIndicator>(
                find.byType(LinearProgressIndicator),
              )
              .value,
          0.42,
        );
        expect(find.textContaining('42%'), findsOneWidget);

        navigator.currentState!.pop();
        await _pumpRoute(tester);
        unawaited(SettingsView.openUpdate(navigator.currentState!, '99.0.0'));
        await _pumpRoute(tester);
        expect(find.byType(UpdateDialog), findsOneWidget);
        expect(find.textContaining('42%'), findsOneWidget);
        expect(updater.downloads, 1);

        updater.download.complete('/tmp/update.apk');
        await tester.pump();
        await tester.pump();
        expect(find.text('Install'), findsOneWidget);
        expect(service.downloadedPath, '/tmp/update.apk');
        expect(updater.installations, 0);

        await tester.tap(find.text('Cancel'));
        await _pumpRoute(tester);
        unawaited(SettingsView.openUpdate(navigator.currentState!, '99.0.0'));
        await _pumpRoute(tester);
        expect(find.text('Install'), findsOneWidget);
        expect(updater.downloads, 1);
        expect(updater.checks, 1);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets('stale app-update navigation rechecks without an empty dialog', (
    tester,
  ) async {
    final (navigator, updater, _) = await _mount(tester, available: false);
    unawaited(SettingsView.openUpdate(navigator.currentState!, '99.0.0'));
    await _pumpRoute(tester);
    expect(updater.checks, 1);
    expect(updater.downloads, 0);
    expect(updater.installations, 0);
    expect(find.byType(SettingsView), findsOneWidget);
    expect(find.byType(UpdateDialog), findsNothing);
    await tester.pump(const Duration(seconds: 10));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('app-update navigation waits for an already-running check', (
    tester,
  ) async {
    final (navigator, updater, service) = await _mount(
      tester,
      available: false,
    );
    final gate = Completer<UpdateInfo?>();
    updater.checkGate = gate;
    unawaited(service.requestCheck());
    await tester.pump();
    expect(service.currentState.phase, AppUpdatePhase.checking);

    unawaited(SettingsView.openUpdate(navigator.currentState!, '99.0.0'));
    await _pumpRoute(tester);
    expect(updater.checks, 1);
    expect(find.byType(SettingsView), findsOneWidget);
    expect(find.byType(UpdateDialog), findsNothing);
    expect(find.text('You are on the latest version'), findsNothing);
    expect(updater.downloads, 0);

    gate.complete(_update);
    await _pumpRoute(tester);
    expect(find.byType(UpdateDialog), findsOneWidget);
    expect(find.text('Version 99.0.0'), findsOneWidget);
    expect(find.text('You are on the latest version'), findsNothing);
    expect(updater.checks, 1);
    expect(updater.downloads, 0);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'desktop app-update View opens update info without APK controls',
    (tester) async {
      final (_, updater, _) = await _mount(tester, android: false);
      await tester.tap(find.text('Open notifications'));
      await _pumpRoute(tester);
      await tester.tap(find.text('View'));
      await _pumpRoute(tester);
      expect(find.byType(NotificationOverlay), findsNothing);
      expect(find.byType(SettingsView), findsOneWidget);
      expect(find.text('Update Available'), findsOneWidget);
      expect(find.text('Version 99.0.0 is available'), findsOneWidget);
      expect(find.text("What's new"), findsOneWidget);
      expect(find.text('Download'), findsNothing);
      expect(find.text('Install'), findsNothing);
      expect(updater.downloads, 0);
      expect(updater.installations, 0);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
