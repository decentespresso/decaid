import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:reaprime/src/controllers/de1_controller.dart';
import 'package:reaprime/src/controllers/device_controller.dart';
import 'package:reaprime/src/controllers/presence_controller.dart';
import 'package:reaprime/src/services/android_updater.dart';
import 'package:reaprime/src/services/macos_updater.dart';
import 'package:reaprime/src/services/update_check_service.dart';
import 'package:reaprime/src/settings/settings_controller.dart';
import 'package:reaprime/src/settings/settings_view.dart';
import 'package:reaprime/src/settings/update_dialog.dart';
import 'package:reaprime/src/webui_support/webui_storage.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';

import '../helpers/mock_settings_service.dart';

class _Launcher extends Fake
    with MockPlatformInterfaceMixin
    implements UrlLauncherPlatform {
  final launches = <String>[];

  @override
  Future<bool> launchUrl(String url, LaunchOptions options) async {
    launches.add(url);
    return true;
  }
}

class _RecordingUpdater extends AndroidUpdater {
  _RecordingUpdater() : super(owner: 'tadelv', repo: 'reaprime');
  int checkCalls = 0;
  Object? checkError;
  UpdateInfo? updateInfo;
  Completer<String>? downloadGate;
  int downloadCalls = 0;
  int installCalls = 0;

  @override
  Future<UpdateInfo?> checkForUpdate(
    String v, {
    UpdateChannel channel = UpdateChannel.stable,
  }) async {
    checkCalls++;
    if (checkError != null) throw checkError!;
    return updateInfo;
  }

  @override
  Future<String> downloadUpdate(
    UpdateInfo info, {
    Function(double)? onProgress,
    Directory? cacheDir,
  }) {
    downloadCalls++;
    onProgress?.call(0.42);
    return downloadGate?.future ?? Future.value('/tmp/update.apk');
  }

  @override
  Future<bool> installUpdate(String path) async {
    installCalls++;
    return false;
  }

  @override
  void dispose() {}
}

class _OfflineContentStorage extends WebUIStorage {
  _OfflineContentStorage(super.settingsController);

  Object? downloadError;
  int downloadCalls = 0;

  @override
  Future<void> downloadRemoteSkins() async {
    downloadCalls++;
    if (downloadError != null) throw downloadError!;
  }
}

const _channel = MethodChannel('net.tadel.reaprime/macos_updater');

Future<(UpdateCheckService, _RecordingUpdater)> _pumpSettingsView(
  WidgetTester tester,
  List<MethodCall> calls, {
  required bool macos,
  bool initializeService = false,
  bool sparkleConfigureFails = false,
  bool sparkleCheckThrows = false,
  bool serviceIsMacOS = false,
  bool externallyManaged = false,
  bool serviceIsAndroid = false,
  UpdateInfo? requestedUpdate,
  _RecordingUpdater? recordingUpdater,
  Future<void> Function(UpdateCheckService)? prepareService,
}) async {
  TestWidgetsFlutterBinding.ensureInitialized();
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_channel, (call) async {
        calls.add(call);
        if (sparkleConfigureFails && call.method == 'configure') {
          throw PlatformException(code: 'configure_failed');
        }
        if (sparkleCheckThrows && call.method == 'checkForUpdates') {
          throw PlatformException(code: 'check_failed');
        }
        return null;
      });

  final settingsController = SettingsController(MockSettingsService());
  await settingsController.loadSettings();

  final presenceController = PresenceController(
    de1Controller: De1Controller(controller: DeviceController(const [])),
    settingsController: settingsController,
  );
  final webUIStorage = _OfflineContentStorage(settingsController);
  final updater = recordingUpdater ?? _RecordingUpdater();
  final updateCheckService = UpdateCheckService(
    settingsService: MockSettingsService(),
    webUIStorage: webUIStorage,
    updater: updater,
    platformIsAndroid: serviceIsAndroid,
    platformIsMacOS: serviceIsMacOS,
    externallyManaged: externallyManaged,
  );
  if (initializeService) {
    await updateCheckService.initialize();
  }
  if (prepareService != null) {
    await tester.runAsync(() => prepareService(updateCheckService));
  }

  final macosUpdater = MacOSUpdater(supported: macos);
  try {
    await macosUpdater.configure(
      automaticChecks: settingsController.automaticUpdateCheck,
      channel: settingsController.updateChannel,
    );
  } catch (_) {}

  await tester.pumpWidget(
    ShadApp(
      home: ScaffoldMessenger(
        child: SettingsView(
          controller: settingsController,
          updateCheckService: updateCheckService,
          macosUpdater: macosUpdater,
          presenceController: presenceController,
          webUIStorage: webUIStorage,
          requestedUpdate: requestedUpdate,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();

  addTearDown(() {
    updateCheckService.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
  });

  return (updateCheckService, updater);
}

UpdateInfo _requestedUpdate({String version = '99.0.0', String? url}) =>
    UpdateInfo(
      version: version,
      downloadUrl: url ?? 'https://example.test/$version.apk',
      releaseNotes: '',
      isPrerelease: false,
      tagName: 'v$version',
    );

void main() {
  group('SettingsView updates', () {
    testWidgets(
      'requested update opens the canonical dialog without downloading',
      (tester) async {
        final requested = _requestedUpdate(
          url: 'https://example.test/old-link.apk',
        );
        final available = _requestedUpdate();
        final updater = _RecordingUpdater()..updateInfo = available;
        final (service, _) = await _pumpSettingsView(
          tester,
          [],
          macos: false,
          serviceIsAndroid: true,
          requestedUpdate: requested,
          recordingUpdater: updater,
          prepareService: (service) async {
            await service.checkForUpdate();
          },
        );

        final dialog = tester.widget<UpdateDialog>(find.byType(UpdateDialog));
        expect(dialog.updateInfo, same(available));
        expect(dialog.updateService, same(service));
        expect(updater.checkCalls, 1);
        expect(updater.downloadCalls, 0);
        expect(updater.installCalls, 0);
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        expect(find.byType(SettingsView), findsOneWidget);
        expect(find.text('Settings'), findsOneWidget);
      },
    );

    testWidgets('open updater release notes follow a newly confirmed release', (
      tester,
    ) async {
      final original = UrlLauncherPlatform.instance;
      final launcher = _Launcher();
      UrlLauncherPlatform.instance = launcher;
      addTearDown(() => UrlLauncherPlatform.instance = original);
      final initial = _requestedUpdate(version: '98.0.0');
      final latest = _requestedUpdate();
      final updater = _RecordingUpdater()..updateInfo = initial;
      final (service, _) = await _pumpSettingsView(
        tester,
        [],
        macos: false,
        serviceIsAndroid: true,
        requestedUpdate: initial,
        recordingUpdater: updater,
        prepareService: (service) async {
          await service.checkForUpdate();
        },
      );
      expect(find.text('Version 98.0.0'), findsOneWidget);

      updater.updateInfo = latest;
      await tester.runAsync(() => service.checkForUpdate());
      await tester.pumpAndSettle();
      expect(find.text('Version 99.0.0'), findsOneWidget);
      await tester.tap(find.text("What's new"));
      await tester.pumpAndSettle();

      expect(launcher.launches, [service.getReleaseUrl(latest)]);
      expect(updater.downloadCalls, 0);
      expect(updater.installCalls, 0);
    });

    testWidgets(
      'stale requested version revalidates and selects the latest update',
      (tester) async {
        final requested = _requestedUpdate(version: '97.0.0');
        final known = _requestedUpdate(version: '98.0.0');
        final current = _requestedUpdate();
        final updater = _RecordingUpdater()..updateInfo = known;
        await _pumpSettingsView(
          tester,
          [],
          macos: false,
          serviceIsAndroid: true,
          requestedUpdate: requested,
          recordingUpdater: updater,
          prepareService: (service) async {
            await service.checkForUpdate();
            updater.updateInfo = current;
          },
        );

        expect(
          tester.widget<UpdateDialog>(find.byType(UpdateDialog)).updateInfo,
          same(current),
        );
        expect(updater.checkCalls, 2);
        expect(updater.downloadCalls, 0);
        expect(updater.installCalls, 0);
      },
    );

    for (final hadKnownUpdate in [false, true]) {
      testWidgets(
        'requested update with known=$hadKnownUpdate cannot open an obsolete dialog',
        (tester) async {
          final updater = _RecordingUpdater();
          await _pumpSettingsView(
            tester,
            [],
            macos: false,
            serviceIsAndroid: true,
            requestedUpdate: _requestedUpdate(),
            recordingUpdater: updater,
            prepareService: (service) async {
              if (hadKnownUpdate) {
                updater.updateInfo = _requestedUpdate(version: '98.0.0');
                await service.checkForUpdate();
                updater.updateInfo = null;
              }
            },
          );

          expect(find.byType(UpdateDialog), findsNothing);
          expect(find.text('Update Available'), findsNothing);
          expect(
            find.text('No app update is currently available'),
            findsOneWidget,
          );
          expect(updater.checkCalls, hadKnownUpdate ? 2 : 1);
          expect(updater.downloadCalls, 0);
          expect(updater.installCalls, 0);
        },
      );
    }

    testWidgets(
      'requested desktop update shows release details but no install controls',
      (tester) async {
        final update = _requestedUpdate();
        final updater = _RecordingUpdater()..updateInfo = update;
        await _pumpSettingsView(
          tester,
          [],
          macos: false,
          requestedUpdate: update,
          recordingUpdater: updater,
          prepareService: (service) async {
            await service.checkForUpdate();
          },
        );

        expect(find.byType(UpdateDialog), findsNothing);
        expect(find.text('Update Available'), findsOneWidget);
        expect(
          find.textContaining('Version 99.0.0 is available'),
          findsOneWidget,
        );
        expect(find.text('Later'), findsOneWidget);
        expect(find.text("What's new"), findsOneWidget);
        expect(find.text('Download'), findsNothing);
        expect(find.text('Install'), findsNothing);
        expect(updater.downloadCalls, 0);
        expect(updater.installCalls, 0);
      },
    );

    testWidgets(
      'requested Settings re-entry reveals shared progress and cached APK',
      (tester) async {
        final update = _requestedUpdate();
        final updater = _RecordingUpdater()..downloadGate = Completer<String>();
        late Future<String> operation;
        final (service, _) = await _pumpSettingsView(
          tester,
          [],
          macos: false,
          serviceIsAndroid: true,
          requestedUpdate: update,
          recordingUpdater: updater,
          prepareService: (service) async {
            operation = service.downloadUpdate(update, (_) {});
          },
        );
        final settings = tester.widget<SettingsView>(find.byType(SettingsView));
        Widget page() => ShadApp(home: ScaffoldMessenger(child: settings));
        expect(find.text('Downloading update… 42%'), findsOneWidget);
        expect(updater.downloadCalls, 1);
        expect(updater.checkCalls, 0);
        expect(updater.installCalls, 0);
        await tester.pumpWidget(const SizedBox());
        await tester.pumpWidget(page());
        await tester.pumpAndSettle();
        expect(find.text('Downloading update… 42%'), findsOneWidget);
        expect(
          tester.widget<UpdateDialog>(find.byType(UpdateDialog)).updateService,
          same(service),
        );
        expect(updater.downloadCalls, 1);

        await tester.runAsync(() async {
          updater.downloadGate!.complete('/tmp/shared.apk');
          await operation;
        });
        await tester.pumpAndSettle();
        expect(find.text('Install'), findsOneWidget);
        await tester.pumpWidget(const SizedBox());
        await tester.pumpWidget(page());
        await tester.pumpAndSettle();
        expect(find.text('Install'), findsOneWidget);
        expect(updater.downloadCalls, 1);
        expect(updater.installCalls, 0);
      },
    );

    testWidgets('skin Retry remains accessible after the app-update dialog', (
      tester,
    ) async {
      final (_, updater) = await _pumpSettingsView(tester, [], macos: false);
      updater.updateInfo = UpdateInfo(
        version: '99.0.0',
        downloadUrl: 'https://example.test/update.apk',
        releaseNotes: '',
        isPrerelease: false,
        tagName: 'v99.0.0',
      );
      final storage =
          tester.widget<SettingsView>(find.byType(SettingsView)).webUIStorage!
              as _OfflineContentStorage;
      storage.downloadError = const SocketException('private host lookup');

      await tester.tap(find.text('Check for updates'));
      await tester.pumpAndSettle();
      expect(find.text('Update Available'), findsOneWidget);
      expect(storage.downloadCalls, 0);
      await tester.pump(const Duration(seconds: 10));
      await tester.tap(find.text('Later'));
      await tester.pumpAndSettle();

      expect(
        find.text(
          "Couldn't download the skins. Check your internet connection and try again.",
        ),
        findsOneWidget,
      );
      expect(find.text('Retry').hitTestable(), findsOneWidget);
      expect(storage.downloadCalls, 1);
      storage.downloadError = null;
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(storage.downloadCalls, 2);
      expect(updater.checkCalls, 1);
      expect(tester.takeException(), isNull);
    });

    testWidgets('shows device management entry', (tester) async {
      final calls = <MethodCall>[];
      await _pumpSettingsView(tester, calls, macos: false);

      expect(find.text('Devices'), findsOneWidget);
    });

    testWidgets('macOS manual check delegates to Sparkle without a Snackbar', (
      tester,
    ) async {
      final calls = <MethodCall>[];
      await _pumpSettingsView(tester, calls, macos: true);

      await tester.tap(find.text('Check for updates'));
      await tester.pumpAndSettle();

      expect(calls.where((c) => c.method == 'checkForUpdates'), hasLength(1));
      expect(find.text('Checking for updates...'), findsNothing);
      expect(find.text('You are on the latest version'), findsNothing);
    });

    testWidgets('macOS automatic-check toggle calls setAutomaticChecks', (
      tester,
    ) async {
      final calls = <MethodCall>[];
      await _pumpSettingsView(tester, calls, macos: true);

      await tester.tap(
        find.widgetWithText(ShadSwitch, 'Automatic update checks'),
      );
      await tester.pumpAndSettle();

      expect(
        calls.where((c) => c.method == 'setAutomaticChecks'),
        hasLength(1),
      );
      expect(
        (calls.lastWhere((c) => c.method == 'setAutomaticChecks').arguments
            as Map)['enabled'],
        isFalse,
      );
    });

    testWidgets('macOS channel change calls setChannel', (tester) async {
      final calls = <MethodCall>[];
      await _pumpSettingsView(tester, calls, macos: true);

      await tester.tap(find.text('Update channel'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Beta'));
      await tester.pumpAndSettle();

      expect(calls.where((c) => c.method == 'setChannel'), hasLength(1));
      expect(
        (calls.lastWhere((c) => c.method == 'setChannel').arguments
            as Map)['channel'],
        'beta',
      );
    });

    testWidgets('macOS toggle after initialization drives Sparkle and the Dart '
        'skin scheduler', (tester) async {
      final calls = <MethodCall>[];
      final (_, updater) = await _pumpSettingsView(
        tester,
        calls,
        macos: true,
        initializeService: true,
      );

      expect(updater.checkCalls, 1);

      await tester.tap(
        find.widgetWithText(ShadSwitch, 'Automatic update checks'),
      );
      await tester.pump();
      expect(
        (calls.lastWhere((c) => c.method == 'setAutomaticChecks').arguments
            as Map)['enabled'],
        isFalse,
      );
      await tester.pump(const Duration(hours: 13));
      expect(updater.checkCalls, 1);

      await tester.tap(
        find.widgetWithText(ShadSwitch, 'Automatic update checks'),
      );
      await tester.pump();
      expect(
        (calls.lastWhere((c) => c.method == 'setAutomaticChecks').arguments
            as Map)['enabled'],
        isTrue,
      );
      expect(updater.checkCalls, 1);
      await tester.pump(const Duration(hours: 13));
      expect(updater.checkCalls, 2);

      await tester.tap(
        find.widgetWithText(ShadSwitch, 'Automatic update checks'),
      );
      await tester.pump(const Duration(hours: 13));
      expect(updater.checkCalls, 2);
    });

    testWidgets(
      'macOS manual check with Sparkle unavailable shows the manual-download '
      'dialog instead of a false latest-version claim',
      (tester) async {
        final calls = <MethodCall>[];
        final (_, updater) = await _pumpSettingsView(
          tester,
          calls,
          macos: true,
          sparkleConfigureFails: true,
          serviceIsMacOS: true,
        );

        await tester.tap(find.text('Check for updates'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));

        expect(calls.where((c) => c.method == 'checkForUpdates'), isEmpty);
        expect(updater.checkCalls, 0);

        expect(find.text('Checking for updates...'), findsNothing);
        expect(find.text('You are on the latest version'), findsNothing);
        expect(find.text('Auto-update unavailable'), findsOneWidget);
        expect(find.text('Open Releases'), findsOneWidget);
      },
    );

    testWidgets(
      'macOS manual check shows failure feedback when Sparkle throws',
      (tester) async {
        final calls = <MethodCall>[];
        await _pumpSettingsView(
          tester,
          calls,
          macos: true,
          sparkleCheckThrows: true,
        );

        await tester.tap(find.text('Check for updates'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));

        expect(calls.where((c) => c.method == 'checkForUpdates'), hasLength(1));
        expect(
          find.textContaining("Couldn't check for app updates"),
          findsOneWidget,
        );

        await tester.pump(const Duration(seconds: 4));
        await tester.pump(const Duration(milliseconds: 300));
      },
    );

    testWidgets('macOS toggle still updates the Dart scheduler when Sparkle '
        'configure failed', (tester) async {
      final calls = <MethodCall>[];
      final (_, updater) = await _pumpSettingsView(
        tester,
        calls,
        macos: true,
        sparkleConfigureFails: true,
      );

      await tester.tap(
        find.widgetWithText(ShadSwitch, 'Automatic update checks'),
      );
      await tester.pump();
      expect(updater.checkCalls, 0);

      await tester.tap(
        find.widgetWithText(ShadSwitch, 'Automatic update checks'),
      );
      await tester.pump();
      expect(updater.checkCalls, 1);

      await tester.tap(
        find.widgetWithText(ShadSwitch, 'Automatic update checks'),
      );
      await tester.pump();

      expect(calls.where((c) => c.method == 'setAutomaticChecks'), isEmpty);
    });

    testWidgets('externally managed builds hide application update controls', (
      tester,
    ) async {
      final calls = <MethodCall>[];
      await _pumpSettingsView(
        tester,
        calls,
        macos: false,
        externallyManaged: true,
      );

      expect(find.text('Update channel'), findsNothing);
      expect(find.text('Check for updates'), findsNothing);
      expect(find.text('Automatic skin and plugin updates'), findsOneWidget);
      expect(
        find.text('Check for skin and plugin updates every 12 hours'),
        findsOneWidget,
      );
    });

    testWidgets('externally managed macOS hides application update controls '
        'even when Sparkle is available', (tester) async {
      final calls = <MethodCall>[];
      await _pumpSettingsView(
        tester,
        calls,
        macos: true,
        externallyManaged: true,
      );

      expect(find.text('Update channel'), findsNothing);
      expect(find.text('Check for updates'), findsNothing);
      expect(find.text('Automatic skin and plugin updates'), findsOneWidget);
      expect(
        find.text('Check for skin and plugin updates every 12 hours'),
        findsOneWidget,
      );
      expect(calls.where((c) => c.method == 'checkForUpdates'), isEmpty);
    });

    testWidgets('externally managed macOS content toggle does not drive '
        'Sparkle even when Sparkle is available', (tester) async {
      final calls = <MethodCall>[];
      await _pumpSettingsView(
        tester,
        calls,
        macos: true,
        externallyManaged: true,
      );

      await tester.tap(
        find.widgetWithText(ShadSwitch, 'Automatic skin and plugin updates'),
      );
      await tester.pumpAndSettle();

      expect(calls.where((c) => c.method == 'setAutomaticChecks'), isEmpty);
      expect(calls.where((c) => c.method == 'setChannel'), isEmpty);
    });

    testWidgets('non-macOS manual check keeps the existing Snackbar flow', (
      tester,
    ) async {
      final calls = <MethodCall>[];
      await _pumpSettingsView(tester, calls, macos: false);

      await tester.tap(find.text('Check for updates'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Checking for updates...'), findsOneWidget);

      expect(calls.where((c) => c.method == 'checkForUpdates'), isEmpty);

      await tester.pump(const Duration(seconds: 4));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('You are on the latest version'), findsOneWidget);

      await tester.pump(const Duration(seconds: 4));
      await tester.pump(const Duration(milliseconds: 300));
    });

    testWidgets(
      'connection failures keep friendly Retry after rate-limit integration',
      (tester) async {
        final (_, updater) = await _pumpSettingsView(tester, [], macos: false);
        updater.checkError = const SocketException('private host lookup');
        await tester.tap(find.text('Check for updates'));
        await tester.pump();
        for (var i = 0; i < 20 && find.text('Retry').evaluate().isEmpty; i++) {
          await tester.pump(const Duration(seconds: 1));
        }
        expect(
          find.text(
            "Couldn't check for app updates. Check your internet connection and try again.",
          ),
          findsOneWidget,
        );
        await tester.pumpAndSettle();
        updater.checkError = null;
        await tester.tap(find.text('Retry'));
        await tester.pumpAndSettle();
        expect(updater.checkCalls, 2);
        expect(
          find.textContaining("Couldn't check for app updates"),
          findsNothing,
        );
      },
    );

    testWidgets('rate-limited manual check offers the releases page', (
      tester,
    ) async {
      final calls = <MethodCall>[];
      final (_, updater) = await _pumpSettingsView(tester, calls, macos: false);
      updater.checkError = UpdateCheckException(
        'GitHub rejected releases request (HTTP 403)',
        rateLimited: true,
        resetAt: DateTime.utc(2030, 1, 1, 12),
      );

      await tester.tap(find.text('Check for updates'));
      await tester.pump();
      for (
        var i = 0;
        i < 20 && find.text('Open releases').evaluate().isEmpty;
        i++
      ) {
        await tester.pump(const Duration(seconds: 1));
      }

      expect(find.textContaining('GitHub rate limit reached'), findsOneWidget);
      expect(find.textContaining('Update checks resume at'), findsOneWidget);
      expect(find.text('Open releases'), findsOneWidget);

      await tester.pump(const Duration(seconds: 10));
      await tester.pump(const Duration(milliseconds: 300));
    });
  });
}
