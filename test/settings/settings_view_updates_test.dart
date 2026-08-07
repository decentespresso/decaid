import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/de1_controller.dart';
import 'package:reaprime/src/controllers/device_controller.dart';
import 'package:reaprime/src/controllers/presence_controller.dart';
import 'package:reaprime/src/services/android_updater.dart';
import 'package:reaprime/src/services/macos_updater.dart';
import 'package:reaprime/src/services/update_check_service.dart';
import 'package:reaprime/src/settings/settings_controller.dart';
import 'package:reaprime/src/settings/settings_view.dart';
import 'package:reaprime/src/webui_support/webui_storage.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import '../helpers/mock_settings_service.dart';

/// The SettingsView branches on the injected `macosUpdater.isSupported`
/// capability, so both the macOS (Sparkle) and the Dart-service paths run on
/// every test host. The harness's Dart service uses `platformIsMacOS: false`
/// so its reactions (immediate checks, timers) stay observable.
class _RecordingUpdater extends AndroidUpdater {
  _RecordingUpdater() : super(owner: 'tadelv', repo: 'reaprime');
  int checkCalls = 0;

  @override
  Future<UpdateInfo?> checkForUpdate(
    String v, {
    UpdateChannel channel = UpdateChannel.stable,
  }) async {
    checkCalls++;
    return null;
  }

  @override
  void dispose() {}
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
  final webUIStorage = WebUIStorage(settingsController);
  final updater = _RecordingUpdater();
  final updateCheckService = UpdateCheckService(
    settingsService: MockSettingsService(),
    webUIStorage: webUIStorage,
    updater: updater,
    platformIsAndroid: false,
    platformIsMacOS: serviceIsMacOS,
  );
  if (initializeService) {
    await updateCheckService.initialize();
  }

  final macosUpdater = MacOSUpdater(supported: macos);
  try {
    await macosUpdater.configure(
      automaticChecks: settingsController.automaticUpdateCheck,
      channel: settingsController.updateChannel,
    );
  } catch (_) {}

  // ShadApp provides no ScaffoldMessenger (WidgetsApp-based); SettingsView's
  // own Scaffold supplies the Material ancestor, so only the messenger needs
  // wrapping here.
  await tester.pumpWidget(
    ShadApp(
      home: ScaffoldMessenger(
        child: SettingsView(
          controller: settingsController,
          updateCheckService: updateCheckService,
          macosUpdater: macosUpdater,
          presenceController: presenceController,
          webUIStorage: webUIStorage,
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

void main() {
  group('SettingsView updates', () {
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

      // Toggle OFF: Sparkle scheduling stops AND the Dart timer must stop.
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
      expect(updater.checkCalls, 1); // no periodic check after disable

      // Toggle ON: both surfaces update and the Dart timer restarts. No
      // immediate check (the last one is fresh); the timer firing at +13h is
      // the proof the periodic scheduler is back.
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
          // A real macOS service would no-op app checks; the degraded path
          // must never route through it or claim "latest version".
          serviceIsMacOS: true,
        );

        await tester.tap(find.text('Check for updates'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));

        expect(calls.where((c) => c.method == 'checkForUpdates'), isEmpty);
        expect(updater.checkCalls, 0);

        // Explicit manual-download prompt, not a false "latest version".
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
        expect(find.textContaining('Update check failed'), findsOneWidget);

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

      // Initial switch value is on; toggle off, then on, then off so no
      // periodic timer is left pending.
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

      // The fake updater reports no update; the "latest version" Snackbar is
      // queued behind the "checking" one. Let the first expire, then the
      // second becomes visible.
      await tester.pump(const Duration(seconds: 4));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('You are on the latest version'), findsOneWidget);

      // Let the second Snackbar expire so no timer is left pending.
      await tester.pump(const Duration(seconds: 4));
      await tester.pump(const Duration(milliseconds: 300));
    });
  });
}
