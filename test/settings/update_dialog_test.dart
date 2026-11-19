import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/services/android_updater.dart';
import 'package:reaprime/src/services/app_update_state.dart';
import 'package:reaprime/src/services/update_check_service.dart';
import 'package:reaprime/src/settings/app_update_dialog.dart';
import 'package:reaprime/src/settings/settings_controller.dart';
import 'package:reaprime/src/settings/update_dialog.dart';
import 'package:reaprime/src/webui_support/webui_storage.dart';

import '../helpers/mock_settings_service.dart';

UpdateInfo _release({String version = '1.2.3', String? url}) => UpdateInfo(
  version: version,
  downloadUrl: url ?? 'https://example.com/decent.apk',
  releaseNotes: '## Internal Markdown\n- implementation detail',
  isPrerelease: false,
  tagName: 'v$version',
);

class _Updater extends AndroidUpdater {
  _Updater() : super(owner: 'test', repo: 'test');

  Future<String> Function(void Function(double)) download = (_) async =>
      '/tmp/decent.apk';
  Future<ApkInstallOutcome> Function(String) install = (_) async =>
      ApkInstallOutcome.permissionRequired;
  int downloadCalls = 0;
  int installCalls = 0;
  Completer<UpdateInfo?>? checkGate;
  UpdateInfo? update = _release();
  UpdateInfo? lastDownload;

  @override
  Future<UpdateInfo?> checkForUpdate(
    String version, {
    UpdateChannel channel = UpdateChannel.stable,
  }) async => checkGate?.future ?? update;

  @override
  Future<String> downloadUpdate(
    UpdateInfo updateInfo, {
    Function(double)? onProgress,
    Directory? cacheDir,
  }) {
    downloadCalls++;
    lastDownload = updateInfo;
    return download((progress) => onProgress?.call(progress));
  }

  @override
  Future<ApkInstallOutcome> installUpdate(
    String path, {
    bool requestPermission = true,
  }) {
    installCalls++;
    return install(path);
  }
}

void main() {
  late _Updater updater;
  late UpdateCheckService service;
  late Directory directory;
  late File apk;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('update-dialog-');
    apk = await File('${directory.path}/update.apk').writeAsBytes([1, 2, 3]);
    updater = _Updater();
    updater.download = (_) async => apk.path;
    final settings = MockSettingsService();
    service = UpdateCheckService(
      settingsService: settings,
      webUIStorage: WebUIStorage(SettingsController(settings)),
      updater: updater,
      platformIsAndroid: true,
      platformIsMacOS: false,
      externallyManaged: false,
    );
    await service.checkForUpdate();
  });

  tearDown(() async {
    service.dispose();
    await directory.delete(recursive: true);
  });

  Widget dialog({VoidCallback? onViewReleaseNotes}) => UpdateDialog(
    service: service,
    updateInfo: service.availableUpdate!,
    currentVersion: '1.2.2',
    onViewReleaseNotes: onViewReleaseNotes ?? () {},
  );

  Future<void> tapInstall(
    WidgetTester tester, {
    String label = 'Install',
  }) async {
    await tester.runAsync(() async {
      await tester.tap(find.text(label));
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      while (service.currentState.phase == AppUpdatePhase.installing &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
    });
    await tester.pumpAndSettle();
  }

  Future<void> mount(WidgetTester tester) => tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => showAppUpdateDialog(context, service),
            child: const Text('Open update'),
          ),
        ),
      ),
    ),
  );

  testWidgets('cancel never downloads or installs an update', (tester) async {
    await mount(tester);
    await tester.tap(find.text('Open update'));
    await tester.pumpAndSettle();
    expect(updater.downloadCalls, 0);
    expect(updater.installCalls, 0);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.byType(UpdateDialog), findsNothing);
    expect(updater.downloadCalls, 0);
    expect(updater.installCalls, 0);
  });

  testWidgets('download waits for a separate install confirmation', (
    tester,
  ) async {
    await tester.pumpWidget(MaterialApp(home: dialog()));
    await tester.tap(find.text('Download'));
    await tester.pumpAndSettle();
    expect(find.text('Install'), findsOneWidget);
    expect(updater.installCalls, 0);
    await tapInstall(tester);
    expect(updater.installCalls, 1);
    expect(find.text('Retry'), findsOneWidget);
    expect(
      find.textContaining('Installation is not authorized'),
      findsOneWidget,
    );
    expect(service.downloadedPath, apk.path);
  });

  testWidgets('download failure offers a friendly retry', (tester) async {
    updater.download = (_) async {
      if (updater.downloadCalls == 1) {
        throw const SocketException('private host lookup');
      }
      return apk.path;
    };
    await tester.pumpWidget(MaterialApp(home: dialog()));
    await tester.tap(find.text('Download'));
    await tester.pumpAndSettle();
    expect(
      find.text(
        "Couldn't download the app update. Check your internet connection and try again.",
      ),
      findsOneWidget,
    );
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(updater.downloadCalls, 2);
    expect(find.text('Install'), findsOneWidget);
    expect(find.textContaining('Check your internet'), findsNothing);
  });

  for (final replacement in ['new version', 'replaced asset']) {
    testWidgets('a confirmed $replacement clears an earlier action error', (
      tester,
    ) async {
      await mount(tester);
      await tester.tap(find.text('Open update'));
      await tester.pumpAndSettle();
      service.clearAvailableUpdate();
      await tester.tap(find.text('Download'));
      await tester.pumpAndSettle();
      expect(
        find.text("Couldn't download the app update. Try again."),
        findsOneWidget,
      );
      updater.update = replacement == 'new version'
          ? _release(version: '2.0.0')
          : _release(url: 'https://example.com/replaced.apk');

      await tester.runAsync(() => service.checkForUpdate());
      await tester.pumpAndSettle();

      expect(
        find.text("Couldn't download the app update. Try again."),
        findsNothing,
      );
      expect(find.text('Download'), findsOneWidget);
      expect(find.text('Retry'), findsNothing);
      expect(updater.downloadCalls, 0);
      expect(updater.installCalls, 0);
    });

    testWidgets('an open dialog follows a confirmed $replacement', (
      tester,
    ) async {
      await tester.pumpWidget(MaterialApp(home: dialog()));
      final next = replacement == 'new version'
          ? _release(version: '2.0.0')
          : _release(url: 'https://example.com/replaced.apk');
      updater.update = next;
      await tester.runAsync(() => service.checkForUpdate());
      await tester.pumpAndSettle();

      expect(find.text('Version ${next.version}'), findsOneWidget);
      expect(updater.downloadCalls, 0);
      await tester.tap(find.text('Download'));
      await tester.pumpAndSettle();

      expect(updater.lastDownload, same(next));
      expect(updater.downloadCalls, 1);
      expect(updater.installCalls, 0);
    });

    testWidgets('a confirmed $replacement clears the cached Install control', (
      tester,
    ) async {
      await service.downloadUpdate(service.availableUpdate!, (_) {});
      await tester.pumpWidget(MaterialApp(home: dialog()));
      expect(find.text('Install'), findsOneWidget);
      final next = replacement == 'new version'
          ? _release(version: '2.0.0')
          : _release(url: 'https://example.com/replaced.apk');
      updater.update = next;
      await tester.runAsync(() => service.checkForUpdate());
      await tester.pumpAndSettle();

      expect(find.text('Version ${next.version}'), findsOneWidget);
      expect(find.text('Install'), findsNothing);
      expect(updater.installCalls, 0);
      await tester.tap(find.text('Download'));
      await tester.pumpAndSettle();
      expect(updater.lastDownload, same(next));
      expect(updater.downloadCalls, 2);
    });
  }

  testWidgets(
    'a withdrawn update removes download, install and release notes',
    (tester) async {
      await service.downloadUpdate(service.availableUpdate!, (_) {});
      await tester.pumpWidget(MaterialApp(home: dialog()));
      expect(find.text('Install'), findsOneWidget);
      updater.update = null;
      await tester.runAsync(() => service.checkForUpdate());
      await tester.pumpAndSettle();

      expect(find.text('This update is no longer available.'), findsOneWidget);
      expect(find.text('Download'), findsNothing);
      expect(find.text('Install'), findsNothing);
      expect(find.text("What's new"), findsNothing);
      expect(updater.downloadCalls, 1);
      expect(updater.installCalls, 0);
    },
  );

  testWidgets('a pending check disables Download until its result arrives', (
    tester,
  ) async {
    await mount(tester);
    await tester.tap(find.text('Open update'));
    await tester.pumpAndSettle();
    final update = service.availableUpdate!;
    final checking = Completer<UpdateInfo?>();
    updater.checkGate = checking;
    final operation = service.checkForUpdate();
    await tester.pumpAndSettle();
    final button = find.widgetWithText(ElevatedButton, 'Download');
    expect(tester.widget<ElevatedButton>(button).onPressed, isNull);
    expect(
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, 'Cancel'))
          .onPressed,
      isNotNull,
    );
    await tester.tap(button);
    expect(updater.downloadCalls, 0);
    checking.complete(update);
    await operation;
    await tester.pumpAndSettle();
    expect(tester.widget<ElevatedButton>(button).onPressed, isNotNull);
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(updater.downloadCalls, 1);
    expect(find.text('Install'), findsOneWidget);
  });

  testWidgets('a rejected stale Download shows visible feedback', (
    tester,
  ) async {
    await mount(tester);
    await tester.tap(find.text('Open update'));
    await tester.pumpAndSettle();
    service.clearAvailableUpdate();
    await tester.tap(find.text('Download'));
    await tester.pumpAndSettle();
    expect(
      find.text("Couldn't download the app update. Try again."),
      findsOneWidget,
    );
    expect(updater.downloadCalls, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('an invalidated cached Install shows visible feedback', (
    tester,
  ) async {
    await mount(tester);
    await tester.tap(find.text('Open update'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Download'));
    await tester.pumpAndSettle();
    service.clearAvailableUpdate();
    await tester.tap(find.text('Install'));
    await tester.pumpAndSettle();
    expect(
      find.text("Couldn't install the app update. Try again."),
      findsOneWidget,
    );
    expect(updater.installCalls, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('rapid Install taps close only the update dialog', (
    tester,
  ) async {
    late Completer<ApkInstallOutcome> installation;
    await mount(tester);
    await tester.tap(find.text('Open update'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Download'));
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      installation = Completer<ApkInstallOutcome>();
      final requested = Completer<void>();
      updater.install = (_) {
        requested.complete();
        return installation.future;
      };
      await tester.tap(find.text('Install'));
      await tester.tap(find.text('Install'));
      await requested.future;
    });
    expect(updater.installCalls, 1);
    await tester.runAsync(() async {
      final finished = service.updateState.firstWhere(
        (_) => service.installationStarted,
      );
      installation.complete(ApkInstallOutcome.installerLaunched);
      await finished;
    });
    await tester.pumpAndSettle();
    expect(find.byType(UpdateDialog), findsNothing);
    expect(find.text('Open update'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('returning from the installer allows a cached explicit retry', (
    tester,
  ) async {
    updater.install = (_) async => ApkInstallOutcome.installerLaunched;
    await mount(tester);
    await tester.tap(find.text('Open update'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Download'));
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      final finished = service.updateState.firstWhere(
        (_) => service.installationStarted,
      );
      await tester.tap(find.text('Install'));
      await finished;
    });
    await tester.pumpAndSettle();
    expect(find.byType(UpdateDialog), findsNothing);
    expect(updater.installCalls, 1);
    service.onAppResumed();
    await tester.tap(find.text('Open update'));
    await tester.pumpAndSettle();
    expect(find.text('Install'), findsOneWidget);
    expect(updater.downloadCalls, 1);
    await tester.runAsync(() async {
      final finished = service.updateState.firstWhere(
        (_) => service.installationStarted,
      );
      await tester.tap(find.text('Install'));
      await finished;
    });
    await tester.pumpAndSettle();
    expect(updater.installCalls, 2);
    expect(updater.downloadCalls, 1);
    expect(find.byType(UpdateDialog), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final dismissal in ['Back', 'Cancel']) {
    testWidgets('$dismissal closes a download without losing shared progress', (
      tester,
    ) async {
      final download = Completer<String>();
      updater.download = (onProgress) {
        onProgress(0.42);
        return download.future;
      };
      final operation = service.downloadUpdate(
        service.availableUpdate!,
        (_) {},
      );
      try {
        await mount(tester);
        await tester.tap(find.text('Open update'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));
        expect(find.text('Downloading update… 42%'), findsOneWidget);
        if (dismissal == 'Back') {
          await tester.binding.handlePopRoute();
        } else {
          await tester.tap(find.text('Cancel'));
        }
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));
        expect(find.byType(UpdateDialog), findsNothing);
        expect(service.currentState.phase, AppUpdatePhase.downloading);
        expect(updater.downloadCalls, 1);

        await tester.tap(find.text('Open update'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));
        expect(find.text('Downloading update… 42%'), findsOneWidget);
        expect(updater.downloadCalls, 1);
        download.complete(apk.path);
        await operation;
        await tester.pumpAndSettle();
        expect(find.text('Install'), findsOneWidget);
        expect(updater.installCalls, 0);

        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Open update'));
        await tester.pumpAndSettle();
        expect(find.text('Install'), findsOneWidget);
        expect(updater.downloadCalls, 1);
      } finally {
        if (!download.isCompleted) download.complete(apk.path);
        await operation;
      }
    });
  }

  testWidgets('reopening after a dismissed download shows its shared failure', (
    tester,
  ) async {
    final download = Completer<String>();
    updater.download = (_) => download.future;
    final operation = service.downloadUpdate(service.availableUpdate!, (_) {});
    final result = operation.then<Object?>(
      (_) => null,
      onError: (Object error) => error,
    );
    try {
      await mount(tester);
      await tester.tap(find.text('Open update'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.tap(find.text('Cancel'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byType(UpdateDialog), findsNothing);
      download.completeError(const SocketException('private host lookup'));
      expect(await result, isA<SocketException>());
      await tester.tap(find.text('Open update'));
      await tester.pumpAndSettle();

      expect(find.text(service.currentState.error!), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
      expect(updater.downloadCalls, 1);
      expect(updater.installCalls, 0);
      expect(tester.takeException(), isNull);
    } finally {
      if (!download.isCompleted) download.complete(apk.path);
      await result;
    }
  });

  testWidgets('opens GitHub release notes instead of rendering raw Markdown', (
    tester,
  ) async {
    var calls = 0;
    await tester.pumpWidget(
      MaterialApp(home: dialog(onViewReleaseNotes: () => calls++)),
    );
    expect(find.textContaining('Internal Markdown'), findsNothing);
    await tester.tap(find.text("What's new"));
    await tester.pump();
    expect(calls, 1);
  });

  testWidgets(
    'permission denial is neutral and retry reuses the downloaded APK',
    (tester) async {
      final installedPaths = <String>[];
      updater.install = (path) async {
        installedPaths.add(path);
        return ApkInstallOutcome.permissionRequired;
      };
      await tester.pumpWidget(MaterialApp(home: dialog()));
      await tester.tap(find.text('Download'));
      await tester.pumpAndSettle();
      await tapInstall(tester);

      expect(find.byType(UpdateDialog), findsOneWidget);
      final guidance = tester.widget<Text>(
        find.textContaining('Installation is not authorized'),
      );
      expect(guidance.style?.color, isNull);
      expect(find.textContaining("Couldn't"), findsNothing);
      expect(service.currentState.error, isNull);

      await tapInstall(tester, label: 'Retry');

      expect(updater.downloadCalls, 1);
      expect(installedPaths, [apk.path, apk.path]);
      expect(service.currentState.error, isNull);
    },
  );

  testWidgets('invalid APK is discarded and Retry downloads again', (
    tester,
  ) async {
    updater.install = (_) async => throw const InvalidApkException();
    await tester.pumpWidget(MaterialApp(home: dialog()));
    await tester.tap(find.text('Download'));
    await tester.pumpAndSettle();
    await tapInstall(tester);

    expect(
      find.text("Couldn't install the app update. Try again."),
      findsOneWidget,
    );
    expect(service.downloadedPath, isNull);
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();

    expect(updater.downloadCalls, 2);
    expect(find.text('Install'), findsOneWidget);
    expect(find.textContaining("Couldn't"), findsNothing);
  });

  testWidgets('native cancellation never relaunches and reuses the cache', (
    tester,
  ) async {
    updater.install = (_) async => ApkInstallOutcome.cancelled;
    await tester.pumpWidget(MaterialApp(home: dialog()));
    await tester.tap(find.text('Download'));
    await tester.pumpAndSettle();
    await tapInstall(tester);

    expect(find.byType(UpdateDialog), findsOneWidget);
    expect(find.text('Install'), findsOneWidget);
    expect(find.textContaining("Couldn't"), findsNothing);
    expect(service.currentState.error, isNull);

    service.onAppResumed();
    service.onAppResumed();
    await tester.pumpAndSettle();

    expect(updater.installCalls, 1);
    expect(find.text('Install'), findsOneWidget);
    await tapInstall(tester);

    expect(updater.installCalls, 2);
    expect(updater.downloadCalls, 1);
  });
}
