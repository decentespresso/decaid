import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/services/android_updater.dart';
import 'package:reaprime/src/services/app_update_state.dart';
import 'package:reaprime/src/services/update_check_service.dart';
import 'package:reaprime/src/settings/settings_controller.dart';
import 'package:reaprime/src/webui_support/webui_storage.dart';

import 'helpers/mock_settings_service.dart';

class _Updater extends AndroidUpdater {
  _Updater(this.downloadPath) : super(owner: 'test', repo: 'test');

  String downloadPath;
  UpdateInfo? nextCheck;
  Completer<void>? checkGate;
  Completer<void>? downloadGate;
  Completer<void>? installGate;
  bool failCheck = false;
  bool failInstall = false;
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
    if (failCheck) throw StateError('private check detail');
    return nextCheck;
  }

  @override
  Future<String> downloadUpdate(
    UpdateInfo update, {
    Function(double)? onProgress,
    Directory? cacheDir,
  }) async {
    downloads++;
    if (downloadGate != null) await downloadGate!.future;
    await File(downloadPath).writeAsBytes([1, 2, 3]);
    return downloadPath;
  }

  @override
  Future<bool> installUpdate(String path) async {
    installations++;
    if (installGate != null) await installGate!.future;
    if (failInstall) throw StateError('private installer detail');
    return true;
  }

  @override
  void dispose() {}
}

class _Settings extends MockSettingsService {
  String? boundary;
  Completer<void>? gate;
  bool fail = false;

  Future<void> _wait(String current) async {
    if (boundary != current) return;
    await gate!.future;
    if (fail) throw StateError('private settings detail');
  }

  @override
  Future<UpdateChannel> updateChannel() async {
    await _wait('channel');
    return super.updateChannel();
  }

  @override
  Future<void> setLastUpdateCheckTime(DateTime time) async {
    await _wait('timestamp');
    return super.setLastUpdateCheckTime(time);
  }

  @override
  Future<String?> skippedVersion() async {
    await _wait('skipped');
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

Future<Object?> _result(Future<Object?> operation) =>
    operation.then<Object?>((value) => value, onError: (Object error) => error);

void main() {
  late Directory directory;
  late _Updater updater;
  late _Settings settings;
  late UpdateCheckService service;
  late UpdateInfo update;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('update-ownership-');
    updater = _Updater('${directory.path}/update.apk');
    settings = _Settings();
    service = UpdateCheckService(
      settingsService: settings,
      webUIStorage: WebUIStorage(SettingsController(settings)),
      updater: updater,
      platformIsAndroid: true,
      platformIsMacOS: false,
      externallyManaged: false,
    );
    update = _update();
    updater.nextCheck = update;
    await service.checkForUpdate();
  });

  tearDown(() async {
    service.dispose();
    await directory.delete(recursive: true);
  });

  for (final boundary in ['channel', 'release', 'timestamp', 'skipped']) {
    for (final operation in ['download', 'installation']) {
      for (final fail in [false, true]) {
        test(
          'a late ${fail ? 'failed' : 'successful'} $boundary check cannot replace a $operation',
          () async {
            final path = operation == 'installation'
                ? await service.downloadUpdate(update, (_) {})
                : updater.downloadPath;
            final checkGate = Completer<void>();
            settings.boundary = boundary;
            settings.gate = checkGate;
            settings.fail = fail;
            updater.nextCheck = _update(version: '2.0.0');
            if (boundary == 'release') {
              updater.checkGate = checkGate;
              updater.failCheck = fail;
            }
            final checking = _result(service.checkForUpdate());
            await Future<void>.delayed(Duration.zero);
            final operationGate = Completer<void>();
            if (operation == 'download') {
              updater.downloadGate = operationGate;
            } else {
              updater.installGate = operationGate;
            }
            final updating = _result(
              operation == 'download'
                  ? service.downloadUpdate(update, (_) {})
                  : service.installUpdate(path),
            );
            await Future<void>.delayed(Duration.zero);
            final before = service.currentState;
            checkGate.complete();
            final result = await checking;
            final after = service.currentState;
            operationGate.complete();
            final operationResult = await updating;

            expect(result, same(update));
            expect(
              before.phase,
              operation == 'download'
                  ? AppUpdatePhase.downloading
                  : AppUpdatePhase.installing,
            );
            expect(after, same(before));
            expect(service.availableUpdate, same(update));
            expect(operationResult, operation == 'download' ? path : isTrue);
          },
        );
      }
    }
  }

  for (final result in ['none', 'newer', 'error', 'quiet error']) {
    test('a late $result check cannot replace a completed download', () async {
      updater.checkGate = Completer<void>();
      final checking = _result(
        service.checkForUpdate(quiet: result == 'quiet error'),
      );
      await Future<void>.delayed(Duration.zero);
      final download = await _result(service.downloadUpdate(update, (_) {}));
      final before = service.currentState;
      updater.nextCheck = result == 'newer' ? _update(version: '2.0.0') : null;
      updater.failCheck = result.endsWith('error');
      updater.checkGate!.complete();
      final checked = await checking;

      expect(download, updater.downloadPath);
      expect(checked, same(update));
      expect(before.phase, AppUpdatePhase.available);
      expect(service.currentState, same(before));
      expect(service.availableUpdate, same(update));
    });
  }

  for (final replacement in ['new version', 'replaced asset', 'removed']) {
    test('a confirmed $replacement rejects stale operations', () async {
      final path = await service.downloadUpdate(update, (_) {});
      final next = switch (replacement) {
        'new version' => _update(version: '2.0.0'),
        'replaced asset' => _update(url: 'https://example.com/replaced.apk'),
        _ => null,
      };
      updater.nextCheck = next;
      await service.checkForUpdate();
      final before = service.currentState;

      await expectLater(
        service.downloadUpdate(update, (_) {}),
        throwsStateError,
      );
      await expectLater(service.installUpdate(path), throwsStateError);

      expect(service.currentState, same(before));
      expect(service.availableUpdate, same(next));
      expect(updater.downloads, 1);
      expect(updater.installations, 0);
    });
  }

  test(
    'a rejected stale download does not fence a valid pending check',
    () async {
      updater.nextCheck = _update(version: '2.0.0');
      await service.checkForUpdate();
      final next = _update(version: '3.0.0');
      updater.nextCheck = next;
      updater.checkGate = Completer<void>();
      final checking = service.checkForUpdate();
      await Future<void>.delayed(Duration.zero);

      await expectLater(
        service.downloadUpdate(update, (_) {}),
        throwsStateError,
      );
      updater.checkGate!.complete();
      await checking;

      expect(service.availableUpdate, same(next));
      expect(service.currentState.phase, AppUpdatePhase.available);
      expect(updater.downloads, 0);
    },
  );

  test(
    'valid cached reuse finishes checking and allows another check',
    () async {
      final path = await service.downloadUpdate(update, (_) {});
      updater.checkGate = Completer<void>();
      final checking = service.checkForUpdate();
      await Future<void>.delayed(Duration.zero);

      final reused = await _result(service.downloadUpdate(update, (_) {}));
      final phase = service.currentState.phase;
      updater.checkGate!.complete();
      await checking;
      updater.checkGate = null;
      await service.requestCheck();

      expect(reused, path);
      expect(phase, AppUpdatePhase.available);
      expect(service.currentState.phase, AppUpdatePhase.available);
      expect(updater.checks, 3);
      expect(updater.downloads, 1);
    },
  );

  for (final invalid in ['missing', 'empty', 'directory']) {
    test('a $invalid cached APK is downloaded again', () async {
      final path = await service.downloadUpdate(update, (_) {});
      final cached = File(path);
      if (invalid == 'empty') {
        await cached.writeAsBytes([]);
      } else {
        await cached.delete();
        if (invalid == 'directory') await Directory(path).create();
      }
      updater.downloadPath = '${directory.path}/fresh.apk';

      final fresh = await service.downloadUpdate(update, (_) {});

      expect(updater.downloads, 2);
      expect(fresh, updater.downloadPath);
      expect(service.downloadedPath, fresh);
      expect(service.currentState.phase, AppUpdatePhase.available);
    });

    test('a $invalid cached APK cannot open the native installer', () async {
      final path = await service.downloadUpdate(update, (_) {});
      final cached = File(path);
      if (invalid == 'empty') {
        await cached.writeAsBytes([]);
      } else {
        await cached.delete();
        if (invalid == 'directory') await Directory(path).create();
      }
      updater.downloadPath = '${directory.path}/fresh.apk';

      await expectLater(service.installUpdate(path), throwsStateError);

      expect(updater.installations, 0);
      expect(service.downloadedPath, isNull);
      expect(service.installationStarted, isFalse);
      expect(service.currentState.phase, AppUpdatePhase.error);
      expect(service.currentState.error, isNotNull);
      await service.downloadUpdate(update, (_) {});
      expect(updater.downloads, 2);
      expect(service.downloadedPath, updater.downloadPath);
    });
  }

  test('installation cache inspection errors are safe and retryable', () async {
    final path = await service.downloadUpdate(update, (_) {});

    await IOOverrides.runZoned(
      () => expectLater(
        service.installUpdate(path),
        throwsA(isA<FileSystemException>()),
      ),
      stat: (_) async =>
          throw const FileSystemException('private installer cache detail'),
    );

    expect(updater.installations, 0);
    expect(service.downloadedPath, isNull);
    expect(service.installationStarted, isFalse);
    expect(service.currentState.phase, AppUpdatePhase.error);
    expect(
      service.currentState.error,
      isNot(contains('private installer cache detail')),
    );
    await service.downloadUpdate(update, (_) {});
    expect(updater.downloads, 2);
    expect(service.downloadedPath, updater.downloadPath);
  });

  test(
    'a native exception retains a validated APK for explicit retry',
    () async {
      final path = await service.downloadUpdate(update, (_) {});
      updater.failInstall = true;

      await expectLater(service.installUpdate(path), throwsStateError);

      expect(updater.installations, 1);
      expect(service.downloadedPath, path);
      expect(service.currentState.phase, AppUpdatePhase.error);
      expect(
        service.currentState.error,
        isNot(contains('private installer detail')),
      );
      updater.failInstall = false;
      expect(await service.installUpdate(path), isTrue);
      expect(updater.installations, 2);
      expect(updater.downloads, 1);
    },
  );

  test('installation owns the operation while inspecting its cache', () async {
    final path = await service.downloadUpdate(update, (_) {});
    final cached = await File(path).stat();
    updater.checkGate = Completer<void>();
    updater.nextCheck = _update(version: '2.0.0');
    final checking = service.checkForUpdate();
    await Future<void>.delayed(Duration.zero);
    final statGate = Completer<FileStat>();
    final installation = IOOverrides.runZoned(
      () => service.installUpdate(path),
      stat: (_) => statGate.future,
    );
    await Future<void>.delayed(Duration.zero);
    final callsBeforeInspection = updater.installations;
    final before = service.currentState;
    updater.checkGate!.complete();
    final result = await checking;
    final after = service.currentState;
    statGate.complete(cached);
    await installation;

    expect(callsBeforeInspection, 0);
    expect(result, same(update));
    expect(before.phase, AppUpdatePhase.installing);
    expect(after, same(before));
    expect(service.availableUpdate, same(update));
    expect(updater.installations, 1);
  });

  test(
    'cache inspection errors discard the path and allow a fresh retry',
    () async {
      await service.downloadUpdate(update, (_) {});

      await IOOverrides.runZoned(
        () => expectLater(
          service.downloadUpdate(update, (_) {}),
          throwsA(isA<FileSystemException>()),
        ),
        stat: (_) async =>
            throw const FileSystemException('private cache detail'),
      );

      expect(service.downloadedPath, isNull);
      expect(service.currentState.phase, AppUpdatePhase.error);
      expect(
        service.currentState.error,
        isNot(contains('private cache detail')),
      );
      await service.downloadUpdate(update, (_) {});
      expect(updater.downloads, 2);
      expect(service.downloadedPath, updater.downloadPath);
    },
  );
}
