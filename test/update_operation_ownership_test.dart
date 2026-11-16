import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/services/android_updater.dart';
import 'package:reaprime/src/services/app_update_state.dart';
import 'package:reaprime/src/services/update_check_service.dart';
import 'package:reaprime/src/settings/settings_controller.dart';
import 'package:reaprime/src/settings/update_dialog.dart';
import 'package:reaprime/src/webui_support/webui_storage.dart';

import 'helpers/mock_settings_service.dart';

class _Updater extends AndroidUpdater {
  _Updater() : super(owner: 'test', repo: 'test');

  Completer<void>? downloadGate;
  Completer<void>? installGate;
  Completer<void>? checkGate;
  UpdateInfo? nextCheck;
  bool failDownload = false;
  bool failInstall = false;
  bool failCheck = false;
  bool installResult = false;
  int downloads = 0;
  int installations = 0;
  int checks = 0;

  @override
  Future<UpdateInfo?> checkForUpdate(
    String currentVersion, {
    UpdateChannel channel = UpdateChannel.stable,
  }) async {
    checks++;
    if (checkGate != null) await checkGate!.future;
    if (failCheck) throw StateError('private check failure');
    return nextCheck;
  }

  @override
  Future<String> downloadUpdate(
    UpdateInfo info, {
    Function(double)? onProgress,
    Directory? cacheDir,
  }) async {
    downloads++;
    onProgress?.call(0.42);
    if (downloadGate != null) await downloadGate!.future;
    if (failDownload) throw StateError('private failure detail');
    return '/tmp/${info.tagName}.apk';
  }

  @override
  Future<bool> installUpdate(String path) async {
    installations++;
    if (installGate != null) await installGate!.future;
    if (failInstall) throw StateError('private installer failure');
    return installResult;
  }

  @override
  void dispose() {}
}

class _DelayedSettings extends MockSettingsService {
  Completer<void>? channelGate;
  Completer<void>? timestampGate;
  Completer<void>? skippedGate;

  @override
  Future<UpdateChannel> updateChannel() async {
    if (channelGate != null) await channelGate!.future;
    return super.updateChannel();
  }

  @override
  Future<void> setLastUpdateCheckTime(DateTime time) async {
    if (timestampGate != null) await timestampGate!.future;
    return super.setLastUpdateCheckTime(time);
  }

  @override
  Future<String?> skippedVersion() async {
    if (skippedGate != null) await skippedGate!.future;
    return super.skippedVersion();
  }
}

UpdateInfo _update({String version = '1.0.0', String? url}) => UpdateInfo(
  version: version,
  tagName: 'v$version',
  downloadUrl: url ?? 'https://example.com/$version.apk',
  releaseNotes: '',
  isPrerelease: false,
);

UpdateCheckService _service(_Updater updater, {MockSettingsService? settings}) {
  final selectedSettings = settings ?? MockSettingsService();
  return UpdateCheckService(
    settingsService: selectedSettings,
    webUIStorage: WebUIStorage(SettingsController(selectedSettings)),
    updater: updater,
    platformIsAndroid: true,
    platformIsMacOS: false,
  );
}

Widget _dialog(UpdateCheckService service, UpdateInfo update) => MaterialApp(
  home: Scaffold(
    body: UpdateDialog(
      updateInfo: update,
      currentVersion: '0.9.3',
      updateService: service,
      onViewReleaseNotes: () {},
      onDownload: service.downloadUpdate,
      onInstall: service.installDownloadedUpdate,
    ),
  ),
);

void main() {
  test(
    'an explicit check can select another release after installer cancellation',
    () async {
      final updater = _Updater()..installResult = true;
      final service = _service(updater);
      addTearDown(service.dispose);
      final path = await service.downloadUpdate(_update(), (_) {});
      await service.installDownloadedUpdate(path);
      final next = _update(version: '2.0.0');
      updater.nextCheck = next;

      await service.requestCheck();
      final nextPath = await service.downloadUpdate(next, (_) {});

      expect(updater.checks, 1);
      expect(updater.downloads, 2);
      expect(service.downloadedPathFor(next), nextPath);
      expect(service.installerLaunched, isFalse);
    },
  );

  for (final result in ['none', 'newer', 'quiet error', 'error']) {
    for (final completed in [false, true]) {
      test(
        'a late $result check cannot replace a ${completed ? 'completed' : 'running'} download',
        () async {
          final updater = _Updater()..checkGate = Completer<void>();
          final service = _service(updater);
          addTearDown(service.dispose);
          final update = _update();
          final check = service.checkForUpdate(quiet: result == 'quiet error');
          await Future<void>.delayed(Duration.zero);
          updater.downloadGate = Completer<void>();
          final download = service.downloadUpdate(update, (_) {});
          await Future<void>.delayed(Duration.zero);
          if (completed) {
            updater.downloadGate!.complete();
            await download;
          }
          final before = service.currentState;
          updater.nextCheck = result == 'newer'
              ? _update(version: '2.0.0')
              : null;
          updater.failCheck = result.endsWith('error');
          updater.checkGate!.complete();

          expect(await check, same(update));
          expect(service.currentState, same(before));
          expect(service.availableUpdate, same(update));
          if (!completed) {
            updater.downloadGate!.complete();
            await download;
          }
        },
      );
    }
  }

  for (final boundary in ['channel', 'timestamp', 'skipped']) {
    test('a check awaiting $boundary cannot replace an installation', () async {
      final updater = _Updater();
      final settings = _DelayedSettings();
      final service = _service(updater, settings: settings);
      addTearDown(service.dispose);
      final update = _update();
      final path = await service.downloadUpdate(update, (_) {});
      final gate = Completer<void>();
      if (boundary == 'channel') settings.channelGate = gate;
      if (boundary == 'timestamp') settings.timestampGate = gate;
      if (boundary == 'skipped') settings.skippedGate = gate;
      updater.nextCheck = _update(version: '2.0.0');
      final check = service.checkForUpdate();
      await Future<void>.delayed(Duration.zero);
      updater.installGate = Completer<void>();
      final installation = service.installDownloadedUpdate(path);
      final before = service.currentState;
      gate.complete();

      expect(await check, same(update));
      expect(service.currentState, same(before));
      updater.installGate!.complete();
      await installation;
    });
  }

  testWidgets(
    'reopening after installer cancellation offers an explicit cached retry',
    (tester) async {
      final updater = _Updater()..installResult = true;
      final service = _service(updater);
      addTearDown(service.dispose);
      final update = _update();
      await tester.runAsync(() async {
        final path = await service.downloadUpdate(update, (_) {});
        await service.installDownloadedUpdate(path);
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) => UpdateDialog(
                    updateInfo: update,
                    currentVersion: '0.9.3',
                    updateService: service,
                    onViewReleaseNotes: () {},
                    onDownload: service.downloadUpdate,
                    onInstall: service.installDownloadedUpdate,
                  ),
                ),
                child: const Text('Open update'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open update'));
      await tester.pumpAndSettle();

      expect(find.text('Retry'), findsOneWidget);
      updater.installGate = Completer<void>();
      await tester.tap(find.text('Retry'));
      await tester.pump();
      expect(service.installerLaunched, isFalse);
      expect(find.text('Installing update...'), findsOneWidget);
      await tester.runAsync(() async {
        updater.installGate!.complete();
      });
      await tester.pumpAndSettle();
      expect(updater.downloads, 1);
      expect(updater.installations, 2);
      expect(find.byType(UpdateDialog), findsNothing);
    },
  );

  for (final mismatch in ['tag', 'url']) {
    test('a different $mismatch cannot join an active download', () async {
      final updater = _Updater()..downloadGate = Completer<void>();
      final service = _service(updater);
      addTearDown(service.dispose);
      final first = _update();
      final second = mismatch == 'tag'
          ? _update(version: '2.0.0')
          : _update(url: 'https://example.com/replaced.apk');
      final operation = service.downloadUpdate(first, (_) {});
      await Future<void>.delayed(Duration.zero);

      await expectLater(
        service.downloadUpdate(second, (_) {}),
        throwsStateError,
      );

      expect(updater.downloads, 1);
      expect(service.currentState.phase, AppUpdatePhase.downloading);
      expect(service.currentState.latestVersion, first.version);
      updater.downloadGate!.complete();
      expect(await operation, '/tmp/v1.0.0.apk');
      expect(service.downloadedPathFor(second), isNull);
    });
  }

  test('installation cannot overlap an unfinished download', () async {
    final updater = _Updater()..downloadGate = Completer<void>();
    final service = _service(updater);
    addTearDown(service.dispose);
    final operation = service.downloadUpdate(_update(), (_) {});

    await expectLater(
      service.installDownloadedUpdate('/tmp/v1.0.0.apk'),
      throwsStateError,
    );

    expect(updater.installations, 0);
    expect(service.currentState.phase, AppUpdatePhase.downloading);
    updater.downloadGate!.complete();
    await operation;
  });

  test('download cannot replace a pending installation', () async {
    final updater = _Updater();
    final service = _service(updater);
    addTearDown(service.dispose);
    final first = _update();
    final path = await service.downloadUpdate(first, (_) {});
    updater.installGate = Completer<void>();
    final installation = service.installDownloadedUpdate(path);

    await expectLater(
      service.downloadUpdate(_update(version: '2.0.0'), (_) {}),
      throwsStateError,
    );

    expect(updater.downloads, 1);
    expect(updater.installations, 1);
    expect(service.currentState.phase, AppUpdatePhase.installing);
    expect(service.downloadedPathFor(first), path);
    updater.installGate!.complete();
    expect(await installation, isFalse);
  });

  test(
    'stale and unowned APK paths cannot replace the active release',
    () async {
      final updater = _Updater();
      final service = _service(updater);
      addTearDown(service.dispose);
      final firstPath = await service.downloadUpdate(_update(), (_) {});
      final second = _update(version: '2.0.0');
      final secondPath = await service.downloadUpdate(second, (_) {});
      final before = service.currentState;

      for (final path in [firstPath, '/tmp/unowned.apk']) {
        await expectLater(
          service.installDownloadedUpdate(path),
          throwsStateError,
        );
      }

      expect(updater.installations, 0);
      expect(service.currentState, same(before));
      expect(service.downloadedPathFor(second), secondPath);
    },
  );

  testWidgets('failed dialog installation retries by downloading again', (
    tester,
  ) async {
    final updater = _Updater()..failInstall = true;
    final service = _service(updater);
    addTearDown(service.dispose);
    final update = _update();
    await tester.runAsync(() => service.downloadUpdate(update, (_) {}));
    await tester.pumpWidget(_dialog(service, update));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Install'));
    await tester.pumpAndSettle();

    final error = service.currentState.error!;
    expect(service.downloadedPathFor(update), isNull);
    expect(find.text(error), findsOneWidget);
    expect(find.textContaining('private installer failure'), findsNothing);
    expect(find.text('Retry'), findsOneWidget);
    expect(updater.downloads, 1);
    expect(updater.installations, 1);

    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();

    expect(updater.downloads, 2);
    expect(updater.installations, 1);
    expect(service.downloadedPathFor(update), '/tmp/v1.0.0.apk');
    expect(find.text('Install'), findsOneWidget);
    expect(find.text(error), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('reopening after a shared failure preserves its safe error', (
    tester,
  ) async {
    final updater = _Updater()..failDownload = true;
    final service = _service(updater);
    addTearDown(service.dispose);
    final update = _update();
    await tester.runAsync(() async {
      await expectLater(
        service.downloadUpdate(update, (_) {}),
        throwsStateError,
      );
    });

    await tester.pumpWidget(_dialog(service, update));
    await tester.pumpAndSettle();

    expect(find.text(service.currentState.error!), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    expect(find.textContaining('private failure detail'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('an observing dialog receives a shared download failure', (
    tester,
  ) async {
    final updater = _Updater()..downloadGate = Completer<void>();
    final service = _service(updater);
    addTearDown(service.dispose);
    final update = _update();
    late Future<String> operation;
    await tester.runAsync(() async {
      operation = service.downloadUpdate(update, (_) {});
    });
    await tester.pumpWidget(_dialog(service, update));
    await tester.pump();
    expect(find.text('Downloading update… 42%'), findsOneWidget);

    await tester.runAsync(() async {
      updater.failDownload = true;
      updater.downloadGate!.complete();
      await expectLater(operation, throwsStateError);
    });
    await tester.pumpAndSettle();

    expect(find.text(service.currentState.error!), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    expect(find.textContaining('private failure detail'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
}
