import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/services/android_updater.dart';
import 'package:reaprime/src/settings/update_dialog.dart';

void main() {
  final updateInfo = UpdateInfo(
    version: '1.2.3',
    downloadUrl: 'https://example.com/decent.apk',
    releaseNotes: '## Internal Markdown\n- implementation detail',
    isPrerelease: false,
    tagName: 'v1.2.3',
  );

  testWidgets('cancel never downloads or installs an update', (tester) async {
    var downloadCalls = 0;
    var installCalls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showDialog<void>(
              context: context,
              builder: (_) => UpdateDialog(
                updateInfo: updateInfo,
                currentVersion: '1.2.2',
                onViewReleaseNotes: () {},
                onDownload: (_, _) async {
                  downloadCalls++;
                  return '/tmp/decent.apk';
                },
                onInstall: (_) async {
                  installCalls++;
                  return ApkInstallOutcome.installerLaunched;
                },
              ),
            ),
            child: const Text('Open update'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open update'));
    await tester.pumpAndSettle();
    expect(downloadCalls, 0);
    expect(installCalls, 0);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.byType(UpdateDialog), findsNothing);
    expect(downloadCalls, 0);
    expect(installCalls, 0);
  });

  testWidgets('download waits for a separate install confirmation', (
    tester,
  ) async {
    var installCalls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: UpdateDialog(
          updateInfo: updateInfo,
          currentVersion: '1.2.2',
          onViewReleaseNotes: () {},
          onDownload: (_, _) async => '/tmp/decent.apk',
          onInstall: (_) async {
            installCalls++;
            return ApkInstallOutcome.permissionRequired;
          },
        ),
      ),
    );
    await tester.tap(find.text('Download'));
    await tester.pumpAndSettle();
    expect(find.text('Install'), findsOneWidget);
    expect(installCalls, 0);
    await tester.tap(find.text('Install'));
    await tester.pumpAndSettle();
    expect(installCalls, 1);
  });

  testWidgets('download failure offers a friendly retry', (tester) async {
    var calls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: UpdateDialog(
          updateInfo: updateInfo,
          currentVersion: '1.2.2',
          onViewReleaseNotes: () {},
          onDownload: (_, _) async {
            calls++;
            if (calls == 1) throw const SocketException('private host lookup');
            return '/tmp/decent.apk';
          },
          onInstall: (_) async => ApkInstallOutcome.installerLaunched,
        ),
      ),
    );
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
    expect(calls, 2);
    expect(find.text('Install'), findsOneWidget);
    expect(find.textContaining('Check your internet'), findsNothing);
  });

  testWidgets('shows determinate download progress and percentage', (
    tester,
  ) async {
    final download = Completer<String>();

    await tester.pumpWidget(
      MaterialApp(
        home: UpdateDialog(
          updateInfo: updateInfo,
          currentVersion: '1.2.2',
          onViewReleaseNotes: () {},
          onDownload: (info, onProgress) {
            onProgress(0.42);
            return download.future;
          },
          onInstall: (_) async => ApkInstallOutcome.installerLaunched,
        ),
      ),
    );

    await tester.tap(find.text('Download'));
    await tester.pump();

    final indicator = tester.widget<LinearProgressIndicator>(
      find.byType(LinearProgressIndicator),
    );
    expect(indicator.value, 0.42);
    expect(find.text('Downloading update… 42%'), findsOneWidget);
  });

  testWidgets('opens GitHub release notes instead of rendering raw Markdown', (
    tester,
  ) async {
    var viewReleaseNotesCalls = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: UpdateDialog(
          updateInfo: updateInfo,
          currentVersion: '1.2.2',
          onViewReleaseNotes: () => viewReleaseNotesCalls++,
          onDownload: (_, _) async => '/tmp/decent.apk',
          onInstall: (_) async => ApkInstallOutcome.installerLaunched,
        ),
      ),
    );

    expect(find.textContaining('Internal Markdown'), findsNothing);

    await tester.tap(find.text("What's new"));
    await tester.pump();

    expect(viewReleaseNotesCalls, 1);
  });

  testWidgets(
    'permission denial is neutral and retry reuses the downloaded APK',
    (tester) async {
      var downloads = 0;
      final installedPaths = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: UpdateDialog(
              updateInfo: updateInfo,
              currentVersion: '1.2.2',
              onViewReleaseNotes: () {},
              onDownload: (_, _) async {
                downloads++;
                return '/tmp/cached.apk';
              },
              onInstall: (path) async {
                installedPaths.add(path);
                return ApkInstallOutcome.permissionRequired;
              },
            ),
          ),
        ),
      );
      await tester.tap(find.text('Download'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Install'));
      await tester.pumpAndSettle();

      expect(find.byType(UpdateDialog), findsOneWidget);
      final guidance = tester.widget<Text>(
        find.textContaining('Installation is not authorized'),
      );
      expect(guidance.style?.color, isNull);
      expect(find.textContaining("Couldn't"), findsNothing);
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(downloads, 1);
      expect(installedPaths, ['/tmp/cached.apk', '/tmp/cached.apk']);
    },
  );

  testWidgets('invalid APK is discarded and Retry downloads again', (
    tester,
  ) async {
    var downloads = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: UpdateDialog(
            updateInfo: updateInfo,
            currentVersion: '1.2.2',
            onViewReleaseNotes: () {},
            onDownload: (_, _) async {
              downloads++;
              return '/tmp/download-$downloads.apk';
            },
            onInstall: (_) async => throw const InvalidApkException(),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Download'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Install'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();

    expect(downloads, 2);
    expect(find.text('Install'), findsOneWidget);
  });
}
