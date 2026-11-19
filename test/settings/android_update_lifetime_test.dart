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

  Future<void> settle(WidgetTester tester) async {
    for (var frame = 0; frame < 6; frame++) {
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 2)),
      );
    }
  }

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
              ),
              child: const Text('Open update'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open update'));
    await settle(tester);
  }

  testWidgets('a launched install closes the quick dialog and disposes', (
    tester,
  ) async {
    final installer = _PendingInstaller()..allowed = true;
    final updater = _Updater(installer);
    addTearDown(updater.dispose);
    await openDialog(tester, GlobalKey<NavigatorState>(), updater);

    expect(find.byType(AndroidQuickUpdateDialog), findsNothing);
    expect(updater.disposals, 1);
    expect(installer.requests, 0);
    expect(installer.installations, 1);
  });

  testWidgets(
    'pending permission resists dismissal and route removal cancels installation',
    (tester) async {
      final installer = _PendingInstaller();
      final updater = _Updater(installer);
      final navigator = GlobalKey<NavigatorState>();
      addTearDown(updater.dispose);
      await openDialog(tester, navigator, updater);
      expect(find.byType(AndroidQuickUpdateDialog), findsOneWidget);
      expect(installer.requests, 1);
      expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, 'Close'))
            .onPressed,
        isNull,
      );

      await tester.tapAt(const Offset(10, 10));
      await settle(tester);
      await navigator.currentState!.maybePop();
      await settle(tester);
      expect(find.byType(AndroidQuickUpdateDialog), findsOneWidget);
      expect(updater.disposals, 0);

      navigator.currentState!.pop();
      await settle(tester);
      expect(find.byType(AndroidQuickUpdateDialog), findsNothing);
      expect(updater.disposals, 1);
      installer.allowed = true;
      installer.permissionReturn.complete();
      await settle(tester);

      expect(installer.installations, 0);
      expect(tester.takeException(), isNull);
    },
  );
}
