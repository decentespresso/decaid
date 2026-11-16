import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/services/android_updater.dart';
import 'package:reaprime/src/services/apk_installer.dart';
import 'package:reaprime/src/settings/settings_view.dart';
import 'package:reaprime/src/settings/update_dialog.dart';

class _PendingInstaller extends ApkInstaller {
  final permissionReturn = Completer<void>();
  bool allowed = false;
  int requests = 0;
  int installations = 0;

  @override
  Future<bool> isValidApk(String path) async => true;

  @override
  Future<bool> canInstallPackages() async => allowed;

  @override
  Future<void> requestInstallPermission() async {
    requests++;
    await permissionReturn.future;
  }

  @override
  Future<bool> installApk(String path) async {
    installations++;
    return true;
  }
}

class _Updater extends AndroidUpdater {
  _Updater(_PendingInstaller installer)
    : super(
        owner: 'test',
        repo: 'test',
        apkInstaller: installer,
        platformIsAndroid: true,
      );

  int disposals = 0;

  @override
  Future<String> downloadUpdate(
    UpdateInfo update, {
    Function(double)? onProgress,
    Directory? cacheDir,
  }) async => '/cached-update.apk';

  @override
  void dispose() {
    disposals++;
    super.dispose();
  }
}

void main() {
  final update = UpdateInfo(
    version: '1.2.3',
    downloadUrl: 'https://example.test/update.apk',
    releaseNotes: '',
    isPrerelease: false,
    tagName: 'v1.2.3',
  );

  Future<void> openDialog(
    WidgetTester tester,
    GlobalKey<NavigatorState> navigator,
    _Updater updater,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showAndroidUpdateDialog(
                context,
                updateInfo: update,
                updater: updater,
                onViewReleaseNotes: () {},
              ),
              child: const Text('Open update'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open update'));
    await tester.pumpAndSettle();
  }

  testWidgets('closing the Settings update dialog disposes its updater', (
    tester,
  ) async {
    final installer = _PendingInstaller();
    final updater = _Updater(installer);
    addTearDown(updater.dispose);
    await openDialog(tester, GlobalKey<NavigatorState>(), updater);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(find.byType(UpdateDialog), findsNothing);
    expect(updater.disposals, 1);
    expect(installer.requests, 0);
    expect(installer.installations, 0);
  });

  testWidgets(
    'pending permission resists dismissal and route removal cancels installation',
    (tester) async {
      final installer = _PendingInstaller();
      final updater = _Updater(installer);
      final navigator = GlobalKey<NavigatorState>();
      addTearDown(updater.dispose);
      await openDialog(tester, navigator, updater);
      await tester.tap(find.text('Download'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Install'));
      await tester.pump();
      expect(installer.requests, 1);

      await tester.tapAt(const Offset(10, 10));
      await tester.pump();
      await navigator.currentState!.maybePop();
      await tester.pump();
      expect(find.byType(UpdateDialog), findsOneWidget);
      expect(updater.disposals, 0);

      navigator.currentState!.pop();
      await tester.pumpAndSettle();
      expect(find.byType(UpdateDialog), findsNothing);
      expect(updater.disposals, 1);
      installer.allowed = true;
      installer.permissionReturn.complete();
      await tester.pumpAndSettle();

      expect(installer.installations, 0);
      expect(tester.takeException(), isNull);
    },
  );
}
