import 'dart:async';
import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/build_info.dart';
import 'package:reaprime/src/plugins/plugin_loader_service.dart';
import 'package:reaprime/src/plugins/plugin_source_service.dart';
import 'package:reaprime/src/services/android_updater.dart';
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
  _FakeUpdater() : super(owner: 'tadelv', repo: 'reaprime');

  UpdateInfo? nextCheck;
  bool throwOnCheck = false;
  bool throwOnDownload = false;
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

  @override
  Future<UpdateInfo?> checkForUpdate(
    String currentVersion, {
    UpdateChannel channel = UpdateChannel.stable,
  }) async {
    checkCalls++;
    lastChannel = channel;
    if (throwOnCheck) throw Exception('check boom');
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
    return '/tmp/update.apk';
  }

  @override
  Future<ApkInstallOutcome> installUpdate(
    String apkPath, {
    bool requestPermission = true,
  }) async {
    installCalls++;
    requestedPermissions = [...requestedPermissions, requestPermission];
    if (installFailure case final error?) throw error;
    if (installGate case final gate?) return gate.future;
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

UpdateInfo _update({String version = '9.9.9'}) => UpdateInfo(
  version: version,
  downloadUrl: 'https://example.com/app.apk',
  releaseNotes: 'shiny',
  isPrerelease: false,
  tagName: 'v$version',
);

void main() {
  late _FakeUpdater updater;
  late MockSettingsService settingsService;
  late _RecordingWebUIStorage webUIStorage;
  late _RecordingPluginSourceService pluginSourceService;

  UpdateCheckService build({
    bool isAndroid = true,
    bool isMacOS = false,
    bool externallyManaged = false,
  }) {
    updater = _FakeUpdater();
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
      expect(downloadingProgress.first, 0.0);
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
        await Future<void>.delayed(Duration.zero);
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
        updater: _FakeUpdater(),
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
}
