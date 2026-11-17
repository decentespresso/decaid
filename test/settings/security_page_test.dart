import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:reaprime/src/account/account_page.dart';
import 'package:reaprime/src/controllers/de1_controller.dart';
import 'package:reaprime/src/controllers/device_controller.dart';
import 'package:reaprime/src/controllers/presence_controller.dart';
import 'package:reaprime/src/settings/security_page.dart';
import 'package:reaprime/src/settings/settings_controller.dart';
import 'package:reaprime/src/settings/settings_view.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';

import '../helpers/mock_settings_service.dart';

class _ControlledSettingsService extends MockSettingsService {
  int writeAttempts = 0;
  Completer<void>? writeGate;
  bool failWrite = false;

  @override
  Future<void> setRequireExtensionManagementAuthorization(bool value) async {
    writeAttempts++;
    final gate = writeGate;
    if (gate != null) await gate.future;
    if (failWrite) {
      throw StateError('simulated extension management policy write failure');
    }
    await super.setRequireExtensionManagementAuthorization(value);
  }
}

class _RecordingLauncher extends Fake
    with MockPlatformInterfaceMixin
    implements UrlLauncherPlatform {
  final List<Uri> launched = [];
  final List<PreferredLaunchMode> modes = [];

  @override
  Future<bool> canLaunch(String url) async => true;

  @override
  Future<bool> launchUrl(String url, LaunchOptions options) async {
    launched.add(Uri.parse(url));
    modes.add(options.mode);
    return true;
  }

  @override
  Future<bool> supportsMode(PreferredLaunchMode mode) async => true;
}

void main() {
  late _ControlledSettingsService settingsService;
  late SettingsController controller;

  const authorizationLabel = 'Require authorization for extension management';

  Future<void> useStoredMode({required bool requireAuthorization}) async {
    settingsService = _ControlledSettingsService();
    if (requireAuthorization) {
      await settingsService.setRequireExtensionManagementAuthorization(true);
    }
    settingsService.writeAttempts = 0;
    controller = SettingsController(settingsService);
    await controller.loadSettings();
  }

  Widget buildSecurityPage({List<String>? pushedRoutes}) {
    return ScaffoldMessenger(
      child: ShadApp(
        home: SecurityPage(controller: controller),
        onGenerateRoute: (settings) {
          pushedRoutes?.add(settings.name ?? '');
          return MaterialPageRoute<void>(
            builder: (_) => const Scaffold(body: Text('account page stub')),
          );
        },
      ),
    );
  }

  void useViewport(WidgetTester tester, Size size) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  Future<void> pumpSecurityPage(
    WidgetTester tester, {
    List<String>? pushedRoutes,
    Size size = const Size(900, 1600),
  }) async {
    useViewport(tester, size);
    await tester.pumpWidget(buildSecurityPage(pushedRoutes: pushedRoutes));
    await tester.pumpAndSettle();
  }

  ShadSwitch authorizationSwitch(WidgetTester tester) =>
      tester.widget<ShadSwitch>(find.byType(ShadSwitch));

  group('settings section', () {
    testWidgets('the settings view opens the security page', (tester) async {
      await useStoredMode(requireAuthorization: false);
      useViewport(tester, const Size(900, 1600));

      final presenceController = PresenceController(
        de1Controller: De1Controller(controller: DeviceController(const [])),
        settingsController: controller,
      );

      await tester.pumpWidget(
        ScaffoldMessenger(
          child: ShadApp(
            home: SettingsView(
              controller: controller,
              presenceController: presenceController,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('SECURITY'), findsOneWidget);
      expect(find.text('Security'), findsOneWidget);

      await tester.tap(find.text('Security'));
      await tester.pumpAndSettle();

      expect(find.byType(SecurityPage), findsOneWidget);
      expect(find.text('Compatibility mode (OFF)'), findsOneWidget);
    });
  });

  group('mode display', () {
    testWidgets('compatibility mode states the risk and the upgrade notice', (
      tester,
    ) async {
      await useStoredMode(requireAuthorization: false);
      await pumpSecurityPage(tester);

      expect(find.text('Compatibility mode (OFF)'), findsOneWidget);
      expect(authorizationSwitch(tester).value, isFalse);
      expect(find.text(authorizationLabel), findsOneWidget);

      expect(
        find.textContaining('anyone who can reach the management API'),
        findsOneWidget,
      );
      expect(
        find.textContaining('plugin that is allowed to call it'),
        findsOneWidget,
      );
      expect(
        find.textContaining('approve permission escalations'),
        findsOneWidget,
      );
      expect(
        find.textContaining('compatibility tradeoff, not a security guarantee'),
        findsOneWidget,
      );
      expect(
        find.textContaining(
          '0.9.3 removes the always-on extension-management protection',
        ),
        findsOneWidget,
      );
      expect(
        find.textContaining('both new and existing installations'),
        findsOneWidget,
      );
      expect(find.textContaining('Fleet and café operators'), findsOneWidget);
      expect(find.text('Protected mode (ON)'), findsNothing);
    });

    testWidgets('protected mode explains the scope and the HTTP limitation', (
      tester,
    ) async {
      await useStoredMode(requireAuthorization: true);
      await pumpSecurityPage(tester);

      expect(find.text('Protected mode (ON)'), findsOneWidget);
      expect(authorizationSwitch(tester).value, isTrue);
      expect(find.text(authorizationLabel), findsOneWidget);

      expect(find.textContaining('extensions:manage'), findsWidgets);
      expect(find.textContaining('bearer'), findsOneWidget);
      expect(find.textContaining('plain HTTP on port 8080'), findsOneWidget);
      expect(find.textContaining('#925'), findsOneWidget);
      expect(find.textContaining('#1135'), findsOneWidget);
      expect(
        find.textContaining('not covered by this setting'),
        findsOneWidget,
      );
      expect(find.text('Compatibility mode (OFF)'), findsNothing);
      expect(find.textContaining('0.9.3 removes'), findsNothing);
    });

    testWidgets('shows protected mode until the stored value is loaded', (
      tester,
    ) async {
      settingsService = _ControlledSettingsService();
      controller = SettingsController(settingsService);
      await pumpSecurityPage(tester);

      expect(find.text('Protected mode (ON)'), findsOneWidget);
      expect(authorizationSwitch(tester).value, isTrue);

      await controller.loadSettings();
      await tester.pumpAndSettle();

      expect(find.text('Compatibility mode (OFF)'), findsOneWidget);
      expect(authorizationSwitch(tester).value, isFalse);
    });
  });

  group('toggle', () {
    testWidgets('turning it on persists protected mode', (tester) async {
      await useStoredMode(requireAuthorization: false);
      await pumpSecurityPage(tester);

      await tester.tap(find.text(authorizationLabel));
      await tester.pumpAndSettle();

      expect(settingsService.writeAttempts, 1);
      expect(controller.requireExtensionManagementAuthorization, isTrue);
      expect(authorizationSwitch(tester).value, isTrue);
      expect(find.text('Protected mode (ON)'), findsOneWidget);
    });

    testWidgets('turning it off persists compatibility mode', (tester) async {
      await useStoredMode(requireAuthorization: true);
      await pumpSecurityPage(tester);

      await tester.tap(find.text(authorizationLabel));
      await tester.pumpAndSettle();

      expect(settingsService.writeAttempts, 1);
      expect(controller.requireExtensionManagementAuthorization, isFalse);
      expect(authorizationSwitch(tester).value, isFalse);
      expect(find.text('Compatibility mode (OFF)'), findsOneWidget);
    });

    testWidgets('repeat taps are ignored while the write is pending', (
      tester,
    ) async {
      await useStoredMode(requireAuthorization: false);
      final gate = Completer<void>();
      settingsService.writeGate = gate;
      await pumpSecurityPage(tester);

      await tester.tap(find.text(authorizationLabel));
      await tester.pump();

      expect(settingsService.writeAttempts, 1);
      expect(authorizationSwitch(tester).onChanged, isNull);
      expect(authorizationSwitch(tester).value, isFalse);

      await tester.tap(find.text(authorizationLabel), warnIfMissed: false);
      await tester.pump();

      expect(settingsService.writeAttempts, 1);
      expect(controller.requireExtensionManagementAuthorization, isFalse);

      gate.complete();
      await tester.pumpAndSettle();

      expect(settingsService.writeAttempts, 1);
      expect(controller.requireExtensionManagementAuthorization, isTrue);
      expect(authorizationSwitch(tester).onChanged, isNotNull);
      expect(authorizationSwitch(tester).value, isTrue);
      expect(find.text('Protected mode (ON)'), findsOneWidget);
    });

    testWidgets('a failed write keeps protected mode and reports an error', (
      tester,
    ) async {
      await useStoredMode(requireAuthorization: true);
      settingsService.failWrite = true;
      await pumpSecurityPage(tester);

      await tester.tap(find.text(authorizationLabel));
      await tester.pumpAndSettle();

      expect(settingsService.writeAttempts, 1);
      expect(controller.requireExtensionManagementAuthorization, isTrue);
      expect(authorizationSwitch(tester).value, isTrue);
      expect(authorizationSwitch(tester).onChanged, isNotNull);
      expect(find.text('Protected mode (ON)'), findsOneWidget);
      expect(
        find.text('Could not save the security setting. Try again.'),
        findsOneWidget,
      );
    });
  });

  group('links', () {
    for (final requireAuthorization in [false, true]) {
      final mode = requireAuthorization ? 'protected' : 'compatibility';

      testWidgets('API tokens opens the account page in $mode mode', (
        tester,
      ) async {
        await useStoredMode(requireAuthorization: requireAuthorization);
        final pushed = <String>[];
        await pumpSecurityPage(tester, pushedRoutes: pushed);

        await tester.tap(find.text('API tokens'));
        await tester.pumpAndSettle();

        expect(pushed, [AccountPage.routeName]);
        expect(find.text('account page stub'), findsOneWidget);
      });
    }

    testWidgets('the café hardening guide opens the live issue externally', (
      tester,
    ) async {
      await useStoredMode(requireAuthorization: false);
      final launcher = _RecordingLauncher();
      final previous = UrlLauncherPlatform.instance;
      UrlLauncherPlatform.instance = launcher;
      addTearDown(() => UrlLauncherPlatform.instance = previous);

      await pumpSecurityPage(tester);

      expect(find.textContaining('Future/planned guide'), findsOneWidget);
      expect(find.textContaining('#1192'), findsWidgets);

      await tester.tap(find.text('Café hardening guide'));
      await tester.pumpAndSettle();

      expect(launcher.launched, [
        Uri.parse('https://github.com/decentespresso/decaid/issues/1192'),
      ]);
      expect(launcher.modes, [PreferredLaunchMode.externalApplication]);
    });
  });

  group('narrow viewport', () {
    for (final requireAuthorization in [false, true]) {
      final mode = requireAuthorization ? 'protected' : 'compatibility';

      testWidgets('fits a 320 wide screen in $mode mode', (tester) async {
        await useStoredMode(requireAuthorization: requireAuthorization);
        await pumpSecurityPage(tester, size: const Size(320, 640));

        expect(tester.takeException(), isNull);
        expect(find.text(authorizationLabel), findsOneWidget);
        expect(find.text('API tokens'), findsOneWidget);
        expect(find.text('Café hardening guide'), findsOneWidget);
      });
    }
  });
}
