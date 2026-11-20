import 'dart:async';
import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:reaprime/build_info.dart';
import 'package:reaprime/src/plugins/plugin_loader_service.dart';
import 'package:reaprime/src/plugins/plugin_source_service.dart';
import 'package:reaprime/src/services/android_updater.dart';
import 'package:reaprime/src/services/apk_installer.dart';
import 'package:reaprime/src/services/app_update_state.dart';
import 'package:reaprime/src/services/update_check_service.dart';
import 'package:reaprime/src/settings/settings_controller.dart';
import 'package:reaprime/src/webui_support/webui_storage.dart';

import 'helpers/mock_settings_service.dart';

class _FakeLoader extends Fake implements PluginLoaderService {}

class _RecordingPluginSourceService extends PluginSourceService {
  _RecordingPluginSourceService() : super(_FakeLoader());

  int updateCalls = 0;

  @override
  Future<void> updateAllPlugins() async {
    updateCalls++;
  }
}

class _RecordingWebUIStorage extends WebUIStorage {
  _RecordingWebUIStorage(super.settingsController);

  int updateCalls = 0;

  @override
  Future<void> updateAllSkins() async {
    updateCalls++;
  }
}

class _FakeUpdater extends AndroidUpdater {
  _FakeUpdater(this.downloadPath) : super(owner: 'tadelv', repo: 'reaprime');

  UpdateInfo? nextCheck;
  Completer<UpdateInfo?>? checkGate;
  bool throwOnCheck = false;
  bool throwOnDownload = false;
  String downloadPath;
  ApkInstallOutcome installResult = ApkInstallOutcome.installerLaunched;
  bool permissionGranted = true;
  Object? installFailure;
  List<double> progressToEmit = const [];

  int checkCalls = 0;
  UpdateChannel? lastChannel;
  int downloadCalls = 0;
  int installCalls = 0;
  int permissionChecks = 0;
  List<bool> requestedPermissions = const [];

  Completer<void>? downloadGate;
  Completer<ApkInstallOutcome>? installGate;
  final installStarted = Completer<void>();

  @override
  Future<UpdateInfo?> checkForUpdate(
    String currentVersion, {
    UpdateChannel channel = UpdateChannel.stable,
  }) async {
    checkCalls++;
    lastChannel = channel;
    if (throwOnCheck) throw Exception('check boom');
    if (checkGate case final gate?) return gate.future;
    return nextCheck;
  }

  @override
  Future<String> downloadUpdate(
    UpdateInfo updateInfo, {
    Function(double progress)? onProgress,
    Directory? cacheDir,
  }) async {
    downloadCalls++;
    if (downloadGate != null) await downloadGate!.future;
    if (throwOnDownload) throw Exception('download boom');
    for (final p in progressToEmit) {
      onProgress?.call(p);
    }
    await File(downloadPath).writeAsBytes([1, 2, 3]);
    return downloadPath;
  }

  @override
  Future<ApkInstallOutcome> installUpdate(
    String apkPath, {
    bool requestPermission = true,
  }) async {
    installCalls++;
    requestedPermissions = [...requestedPermissions, requestPermission];
    if (!installStarted.isCompleted) installStarted.complete();
    if (installFailure case final error?) throw error;
    if (installGate case final gate?) return gate.future;
    if (!permissionGranted && !requestPermission) {
      return ApkInstallOutcome.permissionRequired;
    }
    return installResult;
  }

  @override
  Future<bool> canInstallPackages() async {
    permissionChecks++;
    return permissionGranted;
  }

  @override
  void dispose() {}
}

class _PermissionInstaller extends ApkInstaller {
  _PermissionInstaller() : super(platformIsAndroid: true);

  bool allowed = false;
  int permissionRequests = 0;
  int installs = 0;
  final permissionReturned = Completer<void>();

  @override
  Future<bool> isValidApk(String path) async => true;

  @override
  Future<bool> canInstallPackages() async => allowed;

  @override
  Future<void> requestInstallPermission() async {
    permissionRequests++;
    await permissionReturned.future;
  }

  @override
  Future<bool> installApk(String apkPath) async {
    installs++;
    return true;
  }
}

class _CoordinatedUpdater extends AndroidUpdater {
  _CoordinatedUpdater(this.installer, this.downloadPath)
    : super(
        owner: 'tadelv',
        repo: 'reaprime',
        apkInstaller: installer,
        platformIsAndroid: true,
      );

  final _PermissionInstaller installer;
  final String downloadPath;
  UpdateInfo? nextCheck;
  int checkCalls = 0;
  int downloadCalls = 0;

  @override
  Future<UpdateInfo?> checkForUpdate(
    String currentVersion, {
    UpdateChannel channel = UpdateChannel.stable,
  }) async {
    checkCalls++;
    return nextCheck;
  }

  @override
  Future<String> downloadUpdate(
    UpdateInfo updateInfo, {
    Function(double progress)? onProgress,
    Directory? cacheDir,
  }) async {
    downloadCalls++;
    await File(downloadPath).writeAsBytes([1, 2, 3]);
    return downloadPath;
  }
}

UpdateInfo _update({String version = '9.9.9'}) => UpdateInfo(
  version: version,
  downloadUrl: 'https://example.com/app.apk',
  releaseNotes: 'shiny',
  isPrerelease: false,
  tagName: 'v$version',
);

Future<void> _waitFor(bool Function() condition) async {
  while (!condition()) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  late Directory directory;
  late _FakeUpdater updater;
  late MockSettingsService settingsService;
  late _RecordingWebUIStorage webUIStorage;
  late _RecordingPluginSourceService pluginSourceService;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('update-service-');
  });

  tearDown(() => directory.delete(recursive: true));

  UpdateCheckService build({
    bool isAndroid = true,
    bool isMacOS = false,
    bool externallyManaged = false,
  }) {
    updater = _FakeUpdater('${directory.path}/update.apk');
    settingsService = MockSettingsService();
    final settingsController = SettingsController(settingsService);
    webUIStorage = _RecordingWebUIStorage(settingsController);
    pluginSourceService = _RecordingPluginSourceService();
    return UpdateCheckService(
      settingsService: settingsService,
      webUIStorage: webUIStorage,
      pluginSourceService: pluginSourceService,
      updater: updater,
      platformIsAndroid: isAndroid,
      platformIsMacOS: isMacOS,
      externallyManaged: externallyManaged,
    );
  }

  group('checkForUpdate', () {
    test('a manual check waits for its result during another check', () async {
      final svc = build();
      addTearDown(svc.dispose);
      final gate = Completer<UpdateInfo?>();
      updater.checkGate = gate;
      final background = svc.checkForUpdate(quiet: true);
      var manualCompleted = false;
      final manual = svc.checkForUpdate().then((result) {
        manualCompleted = true;
        return result;
      });
      await Future<void>.delayed(Duration.zero);
      expect(manualCompleted, isFalse);
      gate.complete(_update());
      await background;
      expect((await manual)?.version, '9.9.9');
    });

    test('uses the selected update channel', () async {
      final svc = build();
      await settingsService.setUpdateChannel(UpdateChannel.beta);

      await svc.checkForUpdate();

      expect(updater.lastChannel, UpdateChannel.beta);
      svc.dispose();
    });

    test('emits available with details when an update is found', () async {
      final svc = build();
      updater.nextCheck = _update(version: '9.9.9');

      await svc.checkForUpdate();

      final s = svc.currentState;
      expect(updater.checkCalls, 1);
      expect(svc.availableUpdate?.version, '9.9.9');
      expect(svc.hasAvailableUpdate, isTrue);
      expect(s.phase, AppUpdatePhase.available);
      expect(s.latestVersion, '9.9.9');
      expect(s.releaseNotes, 'shiny');
      expect(s.installable, isTrue);
      expect(s.releaseUrl, contains('tag/v9.9.9'));
      svc.dispose();
    });

    test('emits idle when no update is available', () async {
      final svc = build();
      updater.nextCheck = null;

      await svc.checkForUpdate();

      expect(svc.currentState.phase, AppUpdatePhase.idle);
      expect(svc.currentState.installable, isFalse);
      svc.dispose();
    });

    test('builds a release URL for a manually returned update', () {
      final svc = build();

      expect(
        svc.getReleaseUrl(_update(version: '1.2.3')),
        'https://github.com/decentespresso/decaid/releases/tag/v1.2.3',
      );
      svc.dispose();
    });

    test('a loud check emits error and rethrows', () async {
      final svc = build();
      updater.throwOnCheck = true;

      await expectLater(svc.checkForUpdate(), throwsA(isA<Exception>()));

      expect(svc.currentState.phase, AppUpdatePhase.error);
      expect(svc.currentState.error, isNotNull);
      expect(svc.currentState.error, isNotEmpty);
      svc.dispose();
    });

    test('a quiet check settles back to idle without error', () async {
      final svc = build();
      updater.throwOnCheck = true;
      final phases = <AppUpdatePhase>[];
      final sub = svc.updateState.listen((s) => phases.add(s.phase));

      final result = await svc.checkForUpdate(quiet: true);
      await Future.delayed(Duration.zero);

      expect(result, isNull);
      expect(
        phases,
        containsAllInOrder(<AppUpdatePhase>[
          AppUpdatePhase.checking,
          AppUpdatePhase.idle,
        ]),
      );
      expect(phases, isNot(contains(AppUpdatePhase.error)));
      expect(svc.currentState.phase, AppUpdatePhase.idle);
      expect(svc.currentState.error, isNull);
      await sub.cancel();
      svc.dispose();
    });

    test('a quiet failure keeps an already known update', () async {
      final svc = build();
      updater.nextCheck = _update();
      await svc.checkForUpdate();
      updater.throwOnCheck = true;

      await svc.checkForUpdate(quiet: true);

      expect(svc.currentState.phase, AppUpdatePhase.available);
      expect(svc.currentState.latestVersion, '9.9.9');
      expect(svc.currentState.error, isNull);
      svc.dispose();
    });

    test('canCheck is true off macOS', () {
      final svc = build();

      expect(svc.canCheck, isTrue);
      svc.dispose();
    });

    test('installable is false on non-Android even with an update', () async {
      final svc = build(isAndroid: false);
      updater.nextCheck = _update();

      await svc.checkForUpdate();

      expect(svc.currentState.phase, AppUpdatePhase.available);
      expect(svc.currentState.installable, isFalse);
      expect(svc.canInstall, isFalse);
      svc.dispose();
    });
  });

  group('downloadAndInstall', () {
    test(
      'returning from the installer permits an explicit cached retry',
      () async {
        final svc = build();
        addTearDown(svc.dispose);
        updater.nextCheck = _update();
        await svc.downloadAndInstall();

        svc.onAppResumed();
        svc.onAppResumed();

        expect(svc.installationStarted, isFalse);
        expect(svc.currentState.phase, AppUpdatePhase.available);
        expect(svc.downloadedPath, updater.downloadPath);
        expect(updater.installCalls, 1);
        await svc.checkForUpdate();
        expect(updater.checkCalls, 2);
        await svc.installUpdate(svc.downloadedPath!);
        expect(updater.installCalls, 2);
        expect(updater.downloadCalls, 1);
      },
    );

    test(
      'resume during a pending installer call cannot duplicate it',
      () async {
        final svc = build();
        addTearDown(svc.dispose);
        updater.nextCheck = _update();
        updater.installGate = Completer<ApkInstallOutcome>();
        await svc.checkForUpdate();
        final path = await svc.downloadUpdate(svc.availableUpdate!, (_) {});
        final first = svc.installUpdate(path);

        svc.onAppResumed();
        final second = svc.installUpdate(path);
        await updater.installStarted.future;
        expect(updater.installCalls, 1);
        updater.installGate!.complete(ApkInstallOutcome.installerLaunched);
        expect(await first, ApkInstallOutcome.installerLaunched);
        expect(await second, ApkInstallOutcome.installerLaunched);
        expect(svc.installationStarted, isFalse);
        expect(svc.currentState.phase, AppUpdatePhase.available);
        await svc.installUpdate(path);
        expect(updater.installCalls, 2);
      },
    );

    test('a download without measured progress stays indeterminate', () async {
      final svc = build();
      addTearDown(svc.dispose);
      updater.nextCheck = _update();
      updater.downloadGate = Completer<void>();
      await svc.checkForUpdate();
      final download = svc.downloadUpdate(svc.availableUpdate!, (_) {});

      expect(svc.currentState.phase, AppUpdatePhase.downloading);
      expect(svc.currentState.progress, isNull);
      updater.downloadGate!.complete();
      await download;
      expect(svc.currentState.phase, AppUpdatePhase.available);
    });

    test('a missing cached APK is rejected before install and can be downloaded again', () async {
      final cache = await Directory.systemTemp.createTemp(
        'decaid-update-test-',
      );
      addTearDown(() => cache.delete(recursive: true));
      final svc = build();
      addTearDown(svc.dispose);
      updater.nextCheck = _update();
      updater.downloadPath = '${cache.path}/removed.apk';
      await svc.checkForUpdate();
      final path = await svc.downloadUpdate(svc.availableUpdate!, (_) {});
      await File(path).delete();

      await expectLater(svc.installUpdate(path), throwsStateError);
      expect(updater.installCalls, 0);
      expect(svc.downloadedPath, isNull);
      await svc.downloadUpdate(svc.availableUpdate!, (_) {});
      expect(updater.downloadCalls, 2);
    });

    test('local repeated install requests launch the installer once', () async {
      final svc = build();
      updater.nextCheck = _update();
      updater.installGate = Completer<ApkInstallOutcome>();
      await svc.checkForUpdate();
      final path = await svc.downloadUpdate(svc.availableUpdate!, (_) {});

      final first = svc.installUpdate(path);
      final second = svc.installUpdate(path);
      await updater.installStarted.future;
      expect(updater.installCalls, 1);
      updater.installGate!.complete(ApkInstallOutcome.installerLaunched);
      expect(await first, ApkInstallOutcome.installerLaunched);
      expect(await second, ApkInstallOutcome.installerLaunched);
      expect(
        await svc.installUpdate(path),
        ApkInstallOutcome.installerLaunched,
      );
      expect(updater.installCalls, 1);
      expect(svc.installationStarted, isTrue);
      svc.dispose();
    });

    test(
      'repeated resumes after a launch never relaunch the installer',
      () async {
        final svc = build();
        addTearDown(svc.dispose);
        updater.nextCheck = _update();
        await svc.downloadAndInstall();
        expect(updater.installCalls, 1);

        svc.onAppResumed();
        svc.onAppResumed();
        svc.onAppResumed();

        expect(updater.installCalls, 1);
        expect(svc.currentState.phase, AppUpdatePhase.available);
        expect(svc.currentState.error, isNull);
      },
    );

    test('a replaced release cannot install the previous APK', () async {
      final svc = build();
      addTearDown(svc.dispose);
      updater.nextCheck = _update(version: '9.9.9');
      await svc.checkForUpdate();
      final path = await svc.downloadUpdate(svc.availableUpdate!, (_) {});

      updater.nextCheck = _update(version: '10.0.0');
      await svc.checkForUpdate();

      expect(svc.availableUpdate?.version, '10.0.0');
      expect(svc.downloadedPath, isNull);
      await expectLater(svc.installUpdate(path), throwsStateError);
      expect(updater.installCalls, 0);
    });

    test(
      'an emptied cached APK is rejected and recovered by a download',
      () async {
        final svc = build();
        addTearDown(svc.dispose);
        updater.nextCheck = _update();
        await svc.checkForUpdate();
        final path = await svc.downloadUpdate(svc.availableUpdate!, (_) {});
        await File(path).writeAsBytes([]);

        await expectLater(svc.installUpdate(path), throwsStateError);
        expect(updater.installCalls, 0);
        expect(svc.downloadedPath, isNull);

        await svc.downloadUpdate(svc.availableUpdate!, (_) {});
        expect(updater.downloadCalls, 2);
      },
    );

    test(
      'local download shares progress and waits for install confirmation',
      () async {
        final svc = build();
        updater.nextCheck = _update();
        updater.downloadGate = Completer<void>();
        await svc.checkForUpdate();

        final first = svc.downloadUpdate(svc.availableUpdate!, (_) {});
        final second = svc.downloadUpdate(svc.availableUpdate!, (_) {});
        await svc.checkForUpdate();

        expect(updater.checkCalls, 1);
        expect(updater.downloadCalls, 1);
        expect(svc.currentState.phase, AppUpdatePhase.downloading);
        updater.downloadGate!.complete();
        expect(await first, await second);
        expect(svc.downloadedPath, updater.downloadPath);
        expect(updater.installCalls, 0);
        expect(svc.currentState.phase, AppUpdatePhase.available);

        await svc.downloadAndInstall();
        expect(updater.downloadCalls, 1);
        expect(updater.installCalls, 1);
        svc.dispose();
      },
    );

    test(
      'permission retry keeps the downloaded APK without duplicate installs',
      () async {
        final svc = build();
        updater.nextCheck = _update();
        updater.installResult = ApkInstallOutcome.permissionRequired;
        await svc.downloadAndInstall();
        expect(svc.downloadedPath, updater.downloadPath);
        updater.installResult = ApkInstallOutcome.installerLaunched;

        await svc.downloadAndInstall();
        await svc.downloadAndInstall();

        expect(updater.downloadCalls, 1);
        expect(updater.installCalls, 2);
        svc.dispose();
      },
    );

    test('stale or unsupported local updates cannot download', () async {
      final svc = build();
      updater.nextCheck = _update(version: '10.0.0');
      await svc.checkForUpdate();
      await expectLater(
        svc.downloadUpdate(_update(), (_) {}),
        throwsStateError,
      );
      expect(updater.downloadCalls, 0);
      svc.dispose();

      final desktop = build(isAndroid: false);
      updater.nextCheck = _update();
      await desktop.checkForUpdate();
      await expectLater(
        desktop.downloadUpdate(desktop.availableUpdate!, (_) {}),
        throwsStateError,
      );
      expect(updater.downloadCalls, 0);
      desktop.dispose();
    });

    test('auto-checks, downloads, then installs', () async {
      final svc = build();
      updater.nextCheck = _update();
      updater.progressToEmit = [0.5, 1.0];

      final phases = <AppUpdatePhase>[];
      final sub = svc.updateState.listen((s) => phases.add(s.phase));

      await svc.downloadAndInstall();
      await Future.delayed(Duration.zero);

      expect(updater.checkCalls, 1);
      expect(updater.downloadCalls, 1);
      expect(updater.installCalls, 1);
      expect(svc.currentState.phase, AppUpdatePhase.installing);
      expect(
        phases,
        containsAllInOrder(<AppUpdatePhase>[
          AppUpdatePhase.checking,
          AppUpdatePhase.available,
          AppUpdatePhase.downloading,
          AppUpdatePhase.installing,
        ]),
      );

      await sub.cancel();
      svc.dispose();
    });

    test('settles idle when auto-check finds nothing (no download)', () async {
      final svc = build();
      updater.nextCheck = null;

      await svc.downloadAndInstall();

      expect(updater.downloadCalls, 0);
      expect(svc.currentState.phase, AppUpdatePhase.idle);
      svc.dispose();
    });

    test('throttles fine-grained progress to ~1% steps', () async {
      final svc = build();
      updater.nextCheck = _update();
      updater.progressToEmit = List.generate(1000, (i) => (i + 1) / 1000);

      final downloadingProgress = <double>[];
      final sub = svc.updateState.listen((s) {
        if (s.phase == AppUpdatePhase.downloading && s.progress != null) {
          downloadingProgress.add(s.progress!);
        }
      });

      await svc.downloadAndInstall();
      await Future.delayed(Duration.zero);
      await sub.cancel();

      expect(downloadingProgress.length, lessThan(110));
      expect(downloadingProgress.first, closeTo(0.001, 1e-9));
      expect(downloadingProgress.last, closeTo(1.0, 1e-9));
      svc.dispose();
    });

    test('permission denial retains a neutral available update', () async {
      final svc = build();
      updater.nextCheck = _update();
      updater.installResult = ApkInstallOutcome.permissionRequired;

      await svc.downloadAndInstall();

      expect(svc.currentState.phase, AppUpdatePhase.available);
      expect(svc.currentState.error, isNull);
      expect(updater.requestedPermissions, [true]);
      svc.dispose();
    });

    test('genuine installer failures remain errors', () async {
      final svc = build();
      updater.nextCheck = _update();
      updater.installFailure = StateError('installer unavailable');

      await svc.downloadAndInstall();

      expect(svc.currentState.phase, AppUpdatePhase.error);
      expect(svc.currentState.error, isNotNull);
      expect(updater.installCalls, 1);
      svc.dispose();
    });

    test(
      'disposing a pending installation cannot publish to closed state',
      () async {
        final svc = build();
        updater.nextCheck = _update();
        updater.installGate = Completer<ApkInstallOutcome>();
        final installation = svc.downloadAndInstall();
        await updater.installStarted.future;
        expect(updater.installCalls, 1);

        svc.dispose();
        updater.installGate!.complete(ApkInstallOutcome.cancelled);

        await expectLater(installation, completes);
      },
    );

    test('reports error when the download throws', () async {
      final svc = build();
      updater.nextCheck = _update();
      updater.throwOnDownload = true;

      await svc.downloadAndInstall();

      expect(svc.currentState.phase, AppUpdatePhase.error);
      expect(updater.installCalls, 0);
      svc.dispose();
    });

    test('coalesces a concurrent install (single in-flight op)', () async {
      final svc = build();
      updater.nextCheck = _update();
      updater.downloadGate = Completer<void>();

      final first = svc.downloadAndInstall();
      await Future.delayed(Duration.zero);
      await svc.downloadAndInstall();
      updater.downloadGate!.complete();
      await first;

      expect(updater.downloadCalls, 1);
      svc.dispose();
    });

    test('non-Android is a no-op', () async {
      final svc = build(isAndroid: false);
      updater.nextCheck = _update();

      await svc.downloadAndInstall();

      expect(updater.downloadCalls, 0);
      expect(updater.checkCalls, 0);
      svc.dispose();
    });
  });

  group('install attempt ownership', () {
    UpdateCheckService buildCoordinated(_CoordinatedUpdater coordinated) {
      settingsService = MockSettingsService();
      webUIStorage = _RecordingWebUIStorage(
        SettingsController(settingsService),
      );
      return UpdateCheckService(
        settingsService: settingsService,
        webUIStorage: webUIStorage,
        updater: coordinated,
        platformIsAndroid: true,
        platformIsMacOS: false,
        externallyManaged: false,
      );
    }

    test('removing the owning route cancels the permission attempt without a late launch', () async {
      final installer = _PermissionInstaller();
      final coordinated = _CoordinatedUpdater(
        installer,
        '${directory.path}/coordinated.apk',
      );
      addTearDown(coordinated.dispose);
      final svc = buildCoordinated(coordinated);
      addTearDown(svc.dispose);
      coordinated.nextCheck = _update();
      await svc.checkForUpdate();
      final path = await svc.downloadUpdate(svc.availableUpdate!, (_) {});

      final attempt = svc.installUpdate(path);
      await _waitFor(() => installer.permissionRequests == 1);
      expect(svc.currentState.phase, AppUpdatePhase.installing);

      svc.cancelInstallAttempt();

      installer.allowed = true;
      installer.permissionReturned.complete();
      await Future<void>.delayed(Duration.zero);

      expect(await attempt, ApkInstallOutcome.cancelled);
      expect(installer.installs, 0);
      expect(svc.downloadedPath, path);
      expect(coordinated.downloadCalls, 1);
      expect(svc.currentState.phase, AppUpdatePhase.available);
      expect(svc.currentState.error, isNull);

      expect(
        await svc.installUpdate(path),
        ApkInstallOutcome.installerLaunched,
      );
      expect(installer.installs, 1);
    });

    test(
      'a granted permission installs once and never claims completion',
      () async {
        final installer = _PermissionInstaller();
        final coordinated = _CoordinatedUpdater(
          installer,
          '${directory.path}/granted.apk',
        );
        addTearDown(coordinated.dispose);
        final svc = buildCoordinated(coordinated);
        addTearDown(svc.dispose);
        coordinated.nextCheck = _update();
        await svc.checkForUpdate();
        final path = await svc.downloadUpdate(svc.availableUpdate!, (_) {});

        final attempt = svc.installUpdate(path);
        await _waitFor(() => installer.permissionRequests == 1);

        installer.allowed = true;
        installer.permissionReturned.complete();

        expect(await attempt, ApkInstallOutcome.installerLaunched);
        expect(installer.installs, 1);
        expect(svc.currentState.phase, AppUpdatePhase.installing);
        expect(svc.currentState.error, isNull);
        expect(coordinated.downloadCalls, 1);
      },
    );

    test('cancelling during cache validation has no permission or installer side effect', () async {
      final installer = _PermissionInstaller();
      final coordinated = _CoordinatedUpdater(
        installer,
        '${directory.path}/validated.apk',
      );
      addTearDown(coordinated.dispose);
      final svc = buildCoordinated(coordinated);
      addTearDown(svc.dispose);
      coordinated.nextCheck = _update();
      await svc.checkForUpdate();
      final path = await svc.downloadUpdate(svc.availableUpdate!, (_) {});

      final attempt = svc.installUpdate(path);
      svc.cancelInstallAttempt();

      expect(await attempt, ApkInstallOutcome.cancelled);
      await Future<void>.delayed(Duration.zero);
      expect(installer.permissionRequests, 0);
      expect(installer.installs, 0);
      expect(svc.downloadedPath, path);
      expect(svc.currentState.phase, AppUpdatePhase.available);
    });
  });

  group('operation ownership', () {
    test(
      'a check finishing during a download cannot replace the release',
      () async {
        final svc = build();
        addTearDown(svc.dispose);
        updater.nextCheck = _update(version: '9.9.9');
        await svc.checkForUpdate();

        final lateCheck = Completer<UpdateInfo?>();
        updater.checkGate = lateCheck;
        final checking = svc.checkForUpdate();
        await _waitFor(() => updater.checkCalls == 2);
        final downloadGate = Completer<void>();
        updater.downloadGate = downloadGate;
        final download = svc.downloadUpdate(svc.availableUpdate!, (_) {});
        expect(svc.currentState.phase, AppUpdatePhase.downloading);

        lateCheck.complete(_update(version: '10.0.0'));

        expect((await checking)?.version, '9.9.9');
        expect(svc.availableUpdate?.version, '9.9.9');
        expect(svc.currentState.phase, AppUpdatePhase.downloading);

        downloadGate.complete();
        final path = await download;
        expect(svc.downloadedPath, path);
        expect(svc.availableUpdate?.version, '9.9.9');
      },
    );

    test(
      'a failed late check cannot publish an error over an active download',
      () async {
        final svc = build();
        addTearDown(svc.dispose);
        updater.nextCheck = _update(version: '9.9.9');
        await svc.checkForUpdate();

        final lateCheck = Completer<UpdateInfo?>();
        updater.checkGate = lateCheck;
        final checking = svc.checkForUpdate();
        await _waitFor(() => updater.checkCalls == 2);
        final downloadGate = Completer<void>();
        updater.downloadGate = downloadGate;
        final download = svc.downloadUpdate(svc.availableUpdate!, (_) {});

        lateCheck.completeError(StateError('check boom'));

        expect((await checking)?.version, '9.9.9');
        expect(svc.currentState.phase, AppUpdatePhase.downloading);
        expect(svc.currentState.error, isNull);

        downloadGate.complete();
        await download;
        expect(svc.currentState.phase, AppUpdatePhase.available);
      },
    );
  });

  group('remote installation preflight', () {
    test(
      'missing approval leaves state unchanged without any update work',
      () async {
        final svc = build();
        updater.permissionGranted = false;
        final before = svc.currentState;
        final states = <AppUpdateState>[];
        final subscription = svc.updateState.listen(states.add);
        await Future<void>.delayed(Duration.zero);
        final beforeCount = states.length;

        expect(await svc.requestRemoteInstall(), isFalse);

        expect(svc.currentState, same(before));
        expect(states.length, beforeCount);
        expect(updater.permissionChecks, 1);
        expect(updater.checkCalls, 0);
        expect(updater.downloadCalls, 0);
        expect(updater.installCalls, 0);
        expect(updater.requestedPermissions, isEmpty);
        await subscription.cancel();
        svc.dispose();
      },
    );

    test(
      'approved remote installation never requests local settings',
      () async {
        final svc = build();
        updater.nextCheck = _update();

        expect(await svc.requestRemoteInstall(), isTrue);

        expect(updater.permissionChecks, 1);
        expect(updater.checkCalls, 1);
        expect(updater.downloadCalls, 1);
        expect(updater.installCalls, 1);
        expect(updater.requestedPermissions, [false]);
        expect(svc.currentState.phase, AppUpdatePhase.installing);
        svc.dispose();
      },
    );

    test(
      'permission revoked during a remote download remains neutral',
      () async {
        final svc = build();
        updater.nextCheck = _update();
        updater.downloadGate = Completer<void>();
        final installation = svc.requestRemoteInstall();
        await Future<void>.delayed(Duration.zero);
        updater.permissionGranted = false;
        updater.installResult = ApkInstallOutcome.permissionRequired;
        updater.downloadGate!.complete();

        expect(await installation, isTrue);

        expect(updater.requestedPermissions, [false]);
        expect(svc.currentState.phase, AppUpdatePhase.available);
        expect(svc.currentState.error, isNull);
        svc.dispose();
      },
    );

    test(
      'unsupported builds are rejected without checking permission',
      () async {
        for (final isAndroid in [false, true]) {
          final svc = build(isAndroid: isAndroid, externallyManaged: isAndroid);
          expect(svc.canInstall, isFalse);
          expect(await svc.requestRemoteInstall(), isFalse);
          expect(updater.permissionChecks, 0);
          svc.dispose();
        }
      },
    );
  });

  group('externally managed builds', () {
    test('constructor defaults ownership to the build setting', () {
      final settings = MockSettingsService();
      final svc = UpdateCheckService(
        settingsService: settings,
        webUIStorage: WebUIStorage(SettingsController(settings)),
        updater: _FakeUpdater('${directory.path}/update.apk'),
        platformIsAndroid: true,
        platformIsMacOS: false,
      );

      expect(svc.externallyManaged, BuildInfo.appStore);
      svc.dispose();
    });

    test('canCheck is false', () {
      final managed = build(externallyManaged: true);
      expect(managed.canCheck, isFalse);
      managed.dispose();

      final managedMacOS = build(externallyManaged: true, isMacOS: true);
      expect(managedMacOS.canCheck, isFalse);
      managedMacOS.dispose();
    });

    test(
      'direct and debug checks cannot populate application update state',
      () async {
        final svc = build(externallyManaged: true);
        updater.nextCheck = _update();

        svc.debugForceUpdate();
        expect(svc.availableUpdate, isNull);
        expect(svc.hasAvailableUpdate, isFalse);
        expect(svc.currentState.phase, AppUpdatePhase.idle);

        final result = await svc.checkForUpdate();

        expect(result, isNull);
        expect(updater.checkCalls, 0);
        expect(await settingsService.lastUpdateCheckTime(), isNull);
        expect(svc.availableUpdate, isNull);
        expect(svc.hasAvailableUpdate, isFalse);
        expect(svc.currentState.phase, AppUpdatePhase.idle);
        svc.dispose();
      },
    );

    test(
      'automatic startup and periodic checks update skins and plugins only',
      () {
        fakeAsync((async) {
          final svc = build(externallyManaged: true);
          updater.nextCheck = _update();
          unawaited(settingsService.setLastUpdateCheckTime(DateTime.now()));

          unawaited(svc.initialize());
          async.flushMicrotasks();

          expect(updater.checkCalls, 0);
          expect(webUIStorage.updateCalls, 1);
          expect(pluginSourceService.updateCalls, 1);
          expect(svc.availableUpdate, isNull);
          expect(svc.hasAvailableUpdate, isFalse);
          expect(svc.currentState.phase, AppUpdatePhase.idle);

          async.elapse(const Duration(hours: 12));
          async.flushMicrotasks();

          expect(updater.checkCalls, 0);
          expect(webUIStorage.updateCalls, 2);
          expect(pluginSourceService.updateCalls, 2);
          expect(svc.availableUpdate, isNull);
          expect(svc.hasAvailableUpdate, isFalse);
          expect(svc.currentState.phase, AppUpdatePhase.idle);
          svc.dispose();
        });
      },
    );

    test('requestCheck cannot create an application update', () async {
      final svc = build(externallyManaged: true);
      updater.nextCheck = _update();

      await svc.requestCheck();

      expect(updater.checkCalls, 0);
      expect(svc.availableUpdate, isNull);
      expect(svc.hasAvailableUpdate, isFalse);
      expect(svc.currentState.phase, AppUpdatePhase.idle);
      svc.dispose();
    });
  });

  group('requestCheck', () {
    test('a failed manual check ends in an error frame, not idle', () async {
      final svc = build();
      updater.throwOnCheck = true;
      final phases = <AppUpdatePhase>[];
      final sub = svc.updateState.listen((s) => phases.add(s.phase));

      await svc.requestCheck();
      await Future.delayed(Duration.zero);

      expect(
        phases,
        containsAllInOrder(<AppUpdatePhase>[
          AppUpdatePhase.checking,
          AppUpdatePhase.error,
        ]),
      );
      expect(
        svc.currentState.error,
        "Couldn't check for app updates. Try again.",
      );
      await sub.cancel();
      svc.dispose();
    });

    test('coalesces while a check is in flight', () async {
      final svc = build();
      updater.nextCheck = _update();
      updater.downloadGate = Completer<void>();

      final op = svc.downloadAndInstall();
      await Future.delayed(Duration.zero);
      await svc.requestCheck();
      final checksDuring = updater.checkCalls;
      updater.downloadGate!.complete();
      await op;

      expect(checksDuring, 1);
      svc.dispose();
    });
  });

  group('periodic checks', () {
    test('a failing periodic check emits no error frame', () async {
      final svc = build();
      updater.throwOnCheck = true;
      final phases = <AppUpdatePhase>[];
      final sub = svc.updateState.listen((s) => phases.add(s.phase));

      await svc.enableAutomaticChecks();
      await Future.delayed(Duration.zero);

      expect(updater.checkCalls, 1);
      expect(phases, isNot(contains(AppUpdatePhase.error)));
      expect(svc.currentState.phase, AppUpdatePhase.idle);
      expect(svc.currentState.error, isNull);
      await sub.cancel();
      svc.dispose();
    });

    test('a failing periodic check does not throw', () async {
      final svc = build();
      updater.throwOnCheck = true;

      await expectLater(svc.enableAutomaticChecks(), completes);

      svc.dispose();
    });
  });

  group('macOS (Sparkle owns app updates)', () {
    test('canCheck is false', () {
      final svc = build(isMacOS: true);

      expect(svc.canCheck, isFalse);
      svc.dispose();
    });

    test('checkForUpdate is a no-op and leaves the state idle', () async {
      final svc = build(isMacOS: true);
      updater.nextCheck = _update();

      final result = await svc.checkForUpdate();

      expect(result, isNull);
      expect(updater.checkCalls, 0);
      expect(svc.currentState.phase, AppUpdatePhase.idle);
      expect(svc.currentState.installable, isFalse);
      svc.dispose();
    });

    test('requestCheck does not run the APK-based check', () async {
      final svc = build(isMacOS: true);

      await svc.requestCheck();

      expect(updater.checkCalls, 0);
      expect(svc.currentState.phase, AppUpdatePhase.idle);
      svc.dispose();
    });

    test('initialize schedules skin refresh without an APK check', () async {
      final svc = build(isMacOS: true);

      await svc.initialize();

      expect(updater.checkCalls, 0);
      svc.dispose();
    });
  });

  group('managed content', () {
    test(
      'a recent app check skips startup application and content updates',
      () async {
        final svc = build();
        updater.nextCheck = _update();
        await settingsService.setLastUpdateCheckTime(DateTime.now());

        await svc.initialize();

        expect(updater.checkCalls, 0);
        expect(webUIStorage.updateCalls, 0);
        expect(pluginSourceService.updateCalls, 0);
        expect(svc.availableUpdate, isNull);
        expect(svc.hasAvailableUpdate, isFalse);
        expect(svc.currentState.phase, AppUpdatePhase.idle);
        svc.dispose();
      },
    );

    test('enabling automatic checks also updates managed plugins', () async {
      final svc = build();

      await svc.enableAutomaticChecks();

      expect(pluginSourceService.updateCalls, 1);
      svc.dispose();
    });

    test('macOS still updates managed plugins', () async {
      final svc = build(isMacOS: true);

      await svc.enableAutomaticChecks();

      expect(pluginSourceService.updateCalls, 1);
      expect(webUIStorage.updateCalls, 1);
      svc.dispose();
    });
  });

  test('default updater checks the decentespresso/decaid releases', () async {
    final seen = <Uri>[];
    await http.runWithClient(
      () async {
        final settings = MockSettingsService();
        final svc = UpdateCheckService(
          settingsService: settings,
          webUIStorage: WebUIStorage(SettingsController(settings)),
          platformIsAndroid: true,
          platformIsMacOS: false,
          externallyManaged: false,
        );
        await svc.checkForUpdate();
        svc.dispose();
      },
      () => MockClient((request) async {
        seen.add(request.url);
        return http.Response('[]', 200);
      }),
    );
    expect(
      seen.first.toString(),
      'https://api.github.com/repos/decentespresso/decaid/releases',
    );
  });
}
