import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/main.dart' as app;
import 'package:reaprime/src/controllers/device_controller.dart';
import 'package:reaprime/src/controllers/presence_controller.dart';
import 'package:reaprime/src/services/android_updater.dart';
import 'package:reaprime/src/services/apk_installer.dart';
import 'package:reaprime/src/services/app_update_state.dart';
import 'package:reaprime/src/services/update_check_service.dart';
import 'package:reaprime/src/settings/settings_controller.dart';
import 'package:reaprime/src/settings/settings_view.dart';
import 'package:reaprime/src/settings/update_dialog.dart';
import 'package:reaprime/src/webui_support/webui_storage.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import '../helpers/mock_de1_controller.dart';
import '../helpers/mock_settings_service.dart';

final _release = UpdateInfo(
  version: '99.0.0',
  downloadUrl: 'https://example.test/update.apk',
  releaseNotes: 'Changes',
  isPrerelease: false,
  tagName: 'v99.0.0',
);

class _Installer extends ApkInstaller {
  _Installer() : super(platformIsAndroid: true);

  bool allowed = false;
  bool cancelPermission = false;
  int requests = 0;
  int installations = 0;
  int validations = 0;
  Completer<bool>? validation;
  Completer<void> permission = Completer<void>();

  @override
  Future<bool> isValidApk(String path) async {
    validations++;
    if (validation case final pending?) return pending.future;
    return true;
  }

  @override
  Future<bool> canInstallPackages() async => allowed;

  @override
  Future<void> requestInstallPermission() async {
    requests++;
    await permission.future;
    if (cancelPermission) {
      throw PlatformException(code: 'PERMISSION_CANCELLED');
    }
  }

  @override
  Future<bool> installApk(String path) async {
    installations++;
    return true;
  }
}

class _Updater extends AndroidUpdater {
  _Updater(this.apkPath, _Installer installer)
    : super(
        owner: 'test',
        repo: 'test',
        apkInstaller: installer,
        platformIsAndroid: true,
      );

  final String apkPath;
  int checks = 0;
  int downloads = 0;
  Completer<void> download = Completer<void>();
  Completer<void> downloadCacheWritten = Completer<void>();
  Duration completionDelay = Duration.zero;
  void Function(double)? progress;

  @override
  Future<UpdateInfo?> checkForUpdate(
    String currentVersion, {
    UpdateChannel channel = UpdateChannel.stable,
  }) async {
    checks++;
    return _release;
  }

  @override
  Future<String> downloadUpdate(
    UpdateInfo update, {
    Function(double)? onProgress,
    Directory? cacheDir,
  }) async {
    downloads++;
    progress = onProgress;
    await download.future;
    if (completionDelay > Duration.zero) {
      await Future<void>.delayed(completionDelay);
    }
    await File(apkPath).writeAsBytes([1, 2, 3]);
    if (!downloadCacheWritten.isCompleted) downloadCacheWritten.complete();
    return apkPath;
  }
}

class _OfflineStorage extends WebUIStorage {
  _OfflineStorage(super.settingsController);

  @override
  Future<void> downloadRemoteSkins() async {}
}

void main() {
  late Directory directory;
  late String apkPath;
  late MockSettingsService preferences;
  late SettingsController settings;
  late PresenceController presence;
  late _OfflineStorage storage;
  late _Installer installer;
  late _Updater updater;
  late UpdateCheckService service;
  late GlobalKey<NavigatorState> navigator;
  Route<void>? settingsRoute;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('combined-update-');
    apkPath = '${directory.path}/update.apk';
    await File(apkPath).writeAsBytes([1, 2, 3]);
    preferences = MockSettingsService();
    settings = SettingsController(preferences);
    await settings.loadSettings();
    presence = PresenceController(
      de1Controller: MockDe1Controller(controller: DeviceController(const [])),
      settingsController: settings,
    );
    storage = _OfflineStorage(settings);
    installer = _Installer();
    updater = _Updater(apkPath, installer);
    service = UpdateCheckService(
      settingsService: preferences,
      webUIStorage: storage,
      updater: updater,
      platformIsAndroid: true,
      platformIsMacOS: false,
      externallyManaged: false,
    );
    navigator = GlobalKey<NavigatorState>();
    settingsRoute = null;
    await service.checkForUpdate();
  });

  tearDown(() async {
    service.dispose();
    presence.dispose();
    settings.dispose();
    if (!updater.download.isCompleted) updater.download.complete();
    await directory.delete(recursive: true);
  });

  Future<void> settle(WidgetTester tester) async {
    for (var frame = 0; frame < 6; frame++) {
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 2)),
      );
    }
  }

  Future<void> waitFor(
    WidgetTester tester,
    bool Function() done, {
    String reason = 'the expected state',
  }) async {
    final watchdog = Stopwatch()..start();
    while (!done()) {
      if (watchdog.elapsed > const Duration(seconds: 30)) {
        fail('Timed out after ${watchdog.elapsed} waiting for $reason');
      }
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 2)),
      );
    }
    await settle(tester);
  }

  Future<void> pumpApp(WidgetTester tester) async {
    await tester.pumpWidget(
      ShadApp(
        navigatorKey: navigator,
        builder: (_, child) => ScaffoldMessenger(child: child!),
        initialRoute: '/',
        onGenerateRoute: (route) {
          final created = MaterialPageRoute<void>(
            settings: route,
            builder: (context) => switch (route.name) {
              SettingsView.routeName => SettingsView(
                controller: settings,
                presenceController: presence,
                updateCheckService: service,
                webUIStorage: storage,
                updateVersion: route.arguments as String?,
              ),
              _ => const Scaffold(body: Text('Dashboard')),
            },
          );
          if (route.name == SettingsView.routeName) settingsRoute = created;
          return created;
        },
      ),
    );
    await settle(tester);
  }

  Future<void> openUpdater(WidgetTester tester) async {
    unawaited(
      SettingsView.openUpdate(navigator.currentState!, _release.version),
    );
    await waitFor(
      tester,
      () => find.byType(UpdateDialog).evaluate().isNotEmpty,
      reason: 'the updater dialog',
    );
  }

  Future<void> downloadApk(WidgetTester tester) async {
    await tester.tap(find.text('Download'));
    await waitFor(
      tester,
      () => updater.downloads == 1 && updater.progress != null,
      reason: 'the single download to start with progress',
    );
    updater.progress!(0.42);
    await settle(tester);
  }

  Future<void> finishDownload(WidgetTester tester) async {
    updater.download.complete();
    await waitFor(
      tester,
      () => updater.downloadCacheWritten.isCompleted,
      reason: 'the transfer to write its cache file',
    );
    await waitFor(
      tester,
      () => find.text('Install').evaluate().isNotEmpty,
      reason: 'the Install action once the transfer completes',
    );
  }

  Future<void> tapInstall(WidgetTester tester, {bool Function()? done}) async {
    await tester.tap(find.text('Install'));
    await waitFor(
      tester,
      done ??
          () =>
              installer.installations > 0 ||
              service.currentState.phase != AppUpdatePhase.installing,
      reason: 'the installation attempt to start',
    );
  }

  testWidgets(
    'View into Settings opens the shared updater without a download',
    (tester) async {
      await pumpApp(tester);
      expect(find.byType(UpdateDialog), findsNothing);

      await openUpdater(tester);

      expect(find.byType(SettingsView), findsOneWidget);
      expect(find.byType(UpdateDialog), findsOneWidget);
      expect(find.text('Version 99.0.0'), findsOneWidget);
      expect(updater.downloads, 0);
      expect(installer.installations, 0);
      expect(installer.requests, 0);
    },
  );

  testWidgets('explicit Download transfers once and Install launches once', (
    tester,
  ) async {
    await pumpApp(tester);
    await openUpdater(tester);

    await downloadApk(tester);
    expect(updater.downloads, 1);
    expect(find.textContaining('42%'), findsOneWidget);
    expect(
      tester
          .widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator))
          .value,
      0.42,
    );
    await tester.tap(find.text('Download'));
    await settle(tester);
    expect(updater.downloads, 1);

    await finishDownload(tester);
    expect(installer.installations, 0);

    installer.allowed = true;
    await tapInstall(tester);

    expect(installer.installations, 1);
    expect(updater.downloads, 1);
    expect(find.byType(UpdateDialog), findsNothing);
    expect(find.textContaining('Update installation started'), findsOneWidget);
  });

  testWidgets('a dismissed download outlives Settings and rejoins as one', (
    tester,
  ) async {
    await pumpApp(tester);
    await openUpdater(tester);
    await downloadApk(tester);

    await tester.binding.handlePopRoute();
    await settle(tester);
    expect(find.byType(UpdateDialog), findsNothing);
    expect(service.currentState.phase, AppUpdatePhase.downloading);
    expect(updater.downloads, 1);

    await openUpdater(tester);
    expect(find.textContaining('42%'), findsOneWidget);
    expect(updater.downloads, 1);

    await finishDownload(tester);
    expect(find.text('Install'), findsOneWidget);
    expect(installer.installations, 0);
  });

  testWidgets(
    'a delayed transfer completion is awaited before Install is asserted',
    (tester) async {
      await pumpApp(tester);
      await openUpdater(tester);
      await downloadApk(tester);

      await tester.binding.handlePopRoute();
      await settle(tester);
      expect(find.byType(UpdateDialog), findsNothing);
      expect(service.currentState.phase, AppUpdatePhase.downloading);

      await openUpdater(tester);
      expect(find.textContaining('42%'), findsOneWidget);
      expect(updater.downloads, 1);

      updater.completionDelay = const Duration(seconds: 10);
      await finishDownload(tester);
      expect(find.text('Install'), findsOneWidget);
      expect(service.currentState.phase, AppUpdatePhase.available);
      expect(installer.installations, 0);
    },
  );

  testWidgets('a granted permission launches the cached installer once', (
    tester,
  ) async {
    await pumpApp(tester);
    await openUpdater(tester);
    await downloadApk(tester);
    await finishDownload(tester);

    await tester.tap(find.text('Install'));
    await waitFor(tester, () => installer.requests == 1);
    expect(installer.requests, 1);
    expect(installer.installations, 0);
    expect(
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, 'Cancel'))
          .onPressed,
      isNull,
    );

    service.onAppResumed();
    service.onAppResumed();
    await settle(tester);
    expect(installer.requests, 1);
    expect(installer.installations, 0);

    installer.allowed = true;
    installer.permission.complete();
    await waitFor(tester, () => installer.installations > 0);

    expect(installer.installations, 1);
    expect(updater.downloads, 1);
    expect(installer.requests, 1);
    expect(find.byType(UpdateDialog), findsNothing);
    expect(service.installationStarted, isFalse);
    expect(service.currentState.phase, AppUpdatePhase.available);

    service.onAppResumed();
    service.onAppResumed();
    await settle(tester);
    expect(installer.installations, 1);
    expect(updater.downloads, 1);
  });

  testWidgets('rapid Install taps during a pending permission launch once', (
    tester,
  ) async {
    await pumpApp(tester);
    await openUpdater(tester);
    await downloadApk(tester);
    await finishDownload(tester);

    await tester.tap(find.text('Install'));
    await tester.tap(find.text('Install'));
    await waitFor(tester, () => installer.requests == 1);
    await settle(tester);
    expect(installer.requests, 1);

    installer.allowed = true;
    installer.permission.complete();
    await waitFor(tester, () => installer.installations > 0);
    await settle(tester);

    expect(installer.installations, 1);
    expect(installer.requests, 1);
    expect(updater.downloads, 1);
  });

  testWidgets('denied permission is neutral and Retry never downloads again', (
    tester,
  ) async {
    await pumpApp(tester);
    await openUpdater(tester);
    await downloadApk(tester);
    await finishDownload(tester);

    await tester.tap(find.text('Install'));
    await waitFor(tester, () => installer.requests == 1);
    service.onAppResumed();
    await settle(tester);
    expect(installer.requests, 1);
    installer.permission.complete();
    await waitFor(tester, () => find.text('Retry').evaluate().isNotEmpty);

    expect(find.byType(UpdateDialog), findsOneWidget);
    final guidance = tester.widget<Text>(
      find.textContaining('Installation is not authorized'),
    );
    expect(guidance.style?.color, isNull);
    expect(find.textContaining("Couldn't"), findsNothing);
    expect(service.currentState.error, isNull);
    expect(installer.installations, 0);

    installer.permission = Completer<void>();
    await tester.tap(find.text('Retry'));
    await waitFor(tester, () => installer.requests == 2);
    installer.permission.complete();
    await waitFor(tester, () => find.text('Retry').evaluate().isNotEmpty);

    expect(installer.requests, 2);
    expect(installer.installations, 0);
    expect(updater.downloads, 1);
    expect(
      find.textContaining('Installation is not authorized'),
      findsOneWidget,
    );
  });

  testWidgets(
    'dismissing the updater dialog during a pending permission prevents a launch',
    (tester) async {
      await pumpApp(tester);
      await openUpdater(tester);
      await downloadApk(tester);
      await finishDownload(tester);

      await tester.tap(find.text('Install'));
      await waitFor(tester, () => installer.requests == 1);
      expect(installer.installations, 0);

      navigator.currentState!.pop();
      await settle(tester);
      expect(find.byType(UpdateDialog), findsNothing);

      installer.allowed = true;
      installer.permission.complete();
      await waitFor(
        tester,
        () => service.currentState.phase != AppUpdatePhase.installing,
      );

      expect(installer.installations, 0);
      expect(service.currentState.error, isNull);

      await openUpdater(tester);
      expect(find.text('Install'), findsOneWidget);
      expect(updater.downloads, 1);

      await tapInstall(tester);
      expect(installer.installations, 1);
      expect(updater.downloads, 1);
    },
  );

  testWidgets(
    'dismissing the updater dialog during validation prevents a launch',
    (tester) async {
      await pumpApp(tester);
      await openUpdater(tester);
      await downloadApk(tester);
      await finishDownload(tester);

      installer.validation = Completer<bool>();
      await tester.tap(find.text('Install'));
      await waitFor(tester, () => installer.validations == 1);
      expect(installer.requests, 0);
      expect(find.byType(UpdateDialog), findsOneWidget);

      navigator.currentState!.pop();
      await settle(tester);
      expect(find.byType(UpdateDialog), findsNothing);

      installer.allowed = true;
      installer.validation!.complete(true);
      await settle(tester);

      expect(installer.requests, 0);
      expect(installer.installations, 0);
      expect(service.currentState.error, isNull);

      installer.validation = null;
      await openUpdater(tester);
      expect(find.text('Install'), findsOneWidget);
      await tapInstall(tester);

      expect(installer.requests, 0);
      expect(installer.installations, 1);
      expect(updater.downloads, 1);
    },
  );

  testWidgets(
    'removing the Settings route during a pending permission prevents a launch',
    (tester) async {
      await pumpApp(tester);
      await openUpdater(tester);
      await downloadApk(tester);
      await finishDownload(tester);

      await tester.tap(find.text('Install'));
      await waitFor(tester, () => installer.requests == 1);
      expect(installer.installations, 0);
      expect(settingsRoute?.isActive, isTrue);

      unawaited(
        navigator.currentState!.pushNamedAndRemoveUntil('/', (_) => false),
      );
      await waitFor(tester, () => find.byType(SettingsView).evaluate().isEmpty);

      expect(find.byType(SettingsView), findsNothing);
      expect(find.byType(UpdateDialog), findsNothing);
      expect(settingsRoute?.isActive, isFalse);

      installer.allowed = true;
      installer.permission.complete();
      await waitFor(
        tester,
        () => service.currentState.phase != AppUpdatePhase.installing,
      );

      expect(installer.installations, 0);
      expect(service.currentState.error, isNull);
      expect(updater.downloads, 1);
    },
  );

  testWidgets('removing the updater routes keeps the shared service alive', (
    tester,
  ) async {
    await pumpApp(tester);
    await openUpdater(tester);
    await downloadApk(tester);
    await finishDownload(tester);

    unawaited(
      navigator.currentState!.pushNamedAndRemoveUntil('/', (_) => false),
    );
    await waitFor(tester, () => find.byType(SettingsView).evaluate().isEmpty);

    expect(find.byType(UpdateDialog), findsNothing);
    expect(service.currentState.phase, AppUpdatePhase.available);
    expect(service.downloadedPath, apkPath);

    await service.checkForUpdate();

    expect(updater.checks, 2);
    expect(service.currentState.phase, AppUpdatePhase.available);
  });

  testWidgets(
    'terminal cleanup cancels a pending native validation and its service',
    (tester) async {
      await pumpApp(tester);
      await openUpdater(tester);
      await downloadApk(tester);
      await finishDownload(tester);

      installer.validation = Completer<bool>();
      await tester.tap(find.text('Install'));
      await waitFor(tester, () => installer.validations == 1);
      expect(installer.requests, 0);

      final observer = app.AppLifecycleObserver(updateCheckService: service);
      observer.didChangeAppLifecycleState(AppLifecycleState.detached);
      await settle(tester);

      installer.allowed = true;
      installer.validation!.complete(true);
      await settle(tester);

      expect(installer.requests, 0);
      expect(installer.installations, 0);
      expect(updater.downloads, 1);
    },
  );

  testWidgets(
    'terminal cleanup cancels a pending permission launch and its service',
    (tester) async {
      await pumpApp(tester);
      await openUpdater(tester);
      await downloadApk(tester);
      await finishDownload(tester);

      final observer = app.AppLifecycleObserver(updateCheckService: service);
      addTearDown(observer.dispose);

      await tester.tap(find.text('Install'));
      await waitFor(tester, () => installer.requests == 1);
      expect(installer.installations, 0);

      observer.didChangeAppLifecycleState(AppLifecycleState.detached);
      await settle(tester);

      installer.allowed = true;
      installer.permission.complete();
      await settle(tester);

      expect(installer.requests, 1);
      expect(installer.installations, 0);
      expect(updater.downloads, 1);
    },
  );

  testWidgets(
    'a native permission cancellation keeps an explicit cached retry',
    (tester) async {
      await pumpApp(tester);
      await openUpdater(tester);
      await downloadApk(tester);
      await finishDownload(tester);

      installer.cancelPermission = true;
      await tester.tap(find.text('Install'));
      await waitFor(tester, () => installer.requests == 1);
      installer.permission.complete();
      await waitFor(tester, () => find.text('Install').evaluate().isNotEmpty);

      expect(find.byType(UpdateDialog), findsOneWidget);
      expect(find.text('Install'), findsOneWidget);
      expect(find.textContaining("Couldn't"), findsNothing);
      expect(service.currentState.error, isNull);
      expect(installer.installations, 0);

      service.onAppResumed();
      service.onAppResumed();
      await settle(tester);

      expect(installer.installations, 0);
      expect(find.text('Install'), findsOneWidget);

      installer.allowed = true;
      installer.cancelPermission = false;
      await tapInstall(tester);
      expect(installer.installations, 1);
      expect(updater.downloads, 1);
    },
  );

  testWidgets('repeated resume after a launch never relaunches the installer', (
    tester,
  ) async {
    await pumpApp(tester);
    await openUpdater(tester);
    await downloadApk(tester);
    await finishDownload(tester);
    installer.allowed = true;

    await tapInstall(tester);
    expect(installer.installations, 1);
    expect(find.byType(UpdateDialog), findsNothing);

    service.onAppResumed();
    service.onAppResumed();
    await settle(tester);
    expect(installer.installations, 1);

    await openUpdater(tester);
    expect(find.text('Install'), findsOneWidget);
    expect(installer.installations, 1);
    expect(updater.downloads, 1);

    await tapInstall(tester);
    expect(installer.installations, 2);
    expect(updater.downloads, 1);
  });

  testWidgets('an unauthorized remote install performs no local work', (
    tester,
  ) async {
    await pumpApp(tester);

    final approved = await tester.runAsync(service.requestRemoteInstall);

    expect(approved, isFalse);
    expect(updater.downloads, 0);
    expect(installer.requests, 0);
    expect(installer.installations, 0);
    expect(service.currentState.phase, AppUpdatePhase.available);
    expect(service.currentState.error, isNull);
    expect(find.byType(UpdateDialog), findsNothing);
  });

  testWidgets('an authorized remote install keeps the automatic flow', (
    tester,
  ) async {
    installer.allowed = true;
    updater.download.complete();
    await pumpApp(tester);

    final approved = await tester.runAsync(service.requestRemoteInstall);

    expect(approved, isTrue);
    expect(updater.downloads, 1);
    expect(installer.installations, 1);
    expect(find.byType(UpdateDialog), findsNothing);
  });
}
