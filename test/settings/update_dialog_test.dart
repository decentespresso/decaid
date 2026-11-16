import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/services/android_updater.dart';
import 'package:reaprime/src/services/update_check_service.dart';
import 'package:reaprime/src/settings/settings_controller.dart';
import 'package:reaprime/src/settings/update_dialog.dart';
import 'package:reaprime/src/webui_support/webui_storage.dart';

import '../helpers/mock_settings_service.dart';

class _Updater extends AndroidUpdater {
  _Updater() : super(owner: 'test', repo: 'test');

  Future<String> Function(void Function(double)) download = (_) async =>
      '/tmp/decent.apk';
  Future<bool> Function(String) install = (_) async => false;
  int downloadCalls = 0;
  int installCalls = 0;

  @override
  Future<UpdateInfo?> checkForUpdate(
    String version, {
    UpdateChannel channel = UpdateChannel.stable,
  }) async => UpdateInfo(
    version: '1.2.3',
    downloadUrl: 'https://example.com/decent.apk',
    releaseNotes: '## Internal Markdown\n- implementation detail',
    isPrerelease: false,
    tagName: 'v1.2.3',
  );

  @override
  Future<String> downloadUpdate(
    UpdateInfo updateInfo, {
    Function(double)? onProgress,
    Directory? cacheDir,
  }) {
    downloadCalls++;
    return download((progress) => onProgress?.call(progress));
  }

  @override
  Future<bool> installUpdate(String path) {
    installCalls++;
    return install(path);
  }
}

void main() {
  late _Updater updater;
  late UpdateCheckService service;

  setUp(() async {
    updater = _Updater();
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

  tearDown(() => service.dispose());

  Widget dialog({VoidCallback? onViewReleaseNotes}) => UpdateDialog(
    service: service,
    updateInfo: service.availableUpdate!,
    currentVersion: '1.2.2',
    onViewReleaseNotes: onViewReleaseNotes ?? () {},
  );

  Future<void> mount(WidgetTester tester) => tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () =>
                showDialog<void>(context: context, builder: (_) => dialog()),
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
    await tester.tap(find.text('Install'));
    await tester.pumpAndSettle();
    expect(updater.installCalls, 1);
    expect(find.text('Retry'), findsOneWidget);
    expect(service.downloadedPath, '/tmp/decent.apk');
  });

  testWidgets('download failure offers a friendly retry', (tester) async {
    updater.download = (_) async {
      if (updater.downloadCalls == 1) {
        throw const SocketException('private host lookup');
      }
      return '/tmp/decent.apk';
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

  testWidgets('rapid Install taps close only the update dialog', (
    tester,
  ) async {
    final installation = Completer<bool>();
    updater.install = (_) => installation.future;
    await mount(tester);
    await tester.tap(find.text('Open update'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Download'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Install'));
    await tester.tap(find.text('Install'));
    expect(updater.installCalls, 1);
    installation.complete(true);
    await tester.pumpAndSettle();
    expect(find.byType(UpdateDialog), findsNothing);
    expect(find.text('Open update'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('reopening shares live progress and cannot dismiss a download', (
    tester,
  ) async {
    final download = Completer<String>();
    updater.download = (onProgress) {
      onProgress(0.42);
      return download.future;
    };
    final operation = service.downloadUpdate(service.availableUpdate!, (_) {});
    await mount(tester);
    await tester.tap(find.text('Open update'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(
      tester
          .widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator))
          .value,
      0.42,
    );
    expect(find.text('Downloading update… 42%'), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(find.byType(UpdateDialog), findsOneWidget);
    expect(updater.downloadCalls, 1);
    download.complete('/tmp/decent.apk');
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
}
