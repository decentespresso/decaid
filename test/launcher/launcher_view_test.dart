import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/device_controller.dart';
import 'package:reaprime/src/controllers/scan_state_guardian.dart';
import 'package:reaprime/src/launcher/launcher_scan_page.dart';
import 'package:reaprime/src/launcher/launcher_view.dart';
import 'package:reaprime/src/launcher/widgets/browser_hero_card.dart';
import 'package:reaprime/src/launcher/widgets/connect_device_hero_card.dart';
import 'package:reaprime/src/launcher/widgets/skin_unavailable_card.dart';
import 'package:reaprime/src/models/device/device.dart' as device;
import 'package:reaprime/src/settings/settings_controller.dart';
import 'package:reaprime/src/skin_feature/skin_view.dart';
import 'package:reaprime/src/webui_support/webui_service.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import '../helpers/mock_connection_manager.dart';
import '../helpers/mock_device_scanner.dart';
import '../helpers/mock_de1_controller.dart';
import '../helpers/mock_scale_controller.dart';
import '../helpers/mock_settings_service.dart';

class _FakeWebUIService extends WebUIService {
  _FakeWebUIService({required this.serving});

  final bool serving;

  @override
  bool get isServing => serving;

  @override
  String deviceIp() => '192.168.1.42';
}

void main() {
  late DeviceController deviceController;
  late MockDe1Controller de1Controller;
  late MockScaleController scaleController;
  late SettingsController settingsController;
  late MockConnectionManager connectionManager;
  late ScanStateGuardian scanStateGuardian;

  setUp(() {
    deviceController = DeviceController([]);
    de1Controller = MockDe1Controller(controller: deviceController);
    scaleController = MockScaleController();
    settingsController = SettingsController(MockSettingsService());
    connectionManager = MockConnectionManager(
      deviceScanner: MockDeviceScanner(),
      de1Controller: de1Controller,
      scaleController: scaleController,
      settingsController: settingsController,
    );
    scanStateGuardian = ScanStateGuardian();
  });

  tearDown(() async {
    scanStateGuardian.dispose();
    await connectionManager.dispose();
    await de1Controller.dispose();
    scaleController.dispose();
    deviceController.dispose();
    await de1Controller.de1Subject.close();
    await scaleController.connectionStateSubject.close();
  });

  Widget buildSubject({
    WebUIService? webUIService,
    bool supportsWebView = true,
    bool isDegradedAndroid = false,
    List<String>? routeNames,
  }) {
    return ShadApp(
      onGenerateRoute: (settings) {
        routeNames?.add(settings.name ?? '<unnamed>');
        return MaterialPageRoute<void>(
          settings: settings,
          builder: (_) => Scaffold(body: Text(settings.name ?? 'route')),
        );
      },
      home: LauncherView(
        de1Controller: de1Controller,
        scaleController: scaleController,
        webUIService: webUIService ?? _FakeWebUIService(serving: true),
        connectionManager: connectionManager,
        deviceController: deviceController,
        settingsController: settingsController,
        scanStateGuardian: scanStateGuardian,
        isDegradedAndroid: isDegradedAndroid,
        supportsWebView: supportsWebView,
      ),
    );
  }

  Finder buttonFor(String label) =>
      find.ancestor(of: find.text(label), matching: find.byType(ShadButton));

  void expectActionableButton(
    WidgetTester tester,
    String label,
    ShadButtonVariant variant,
  ) {
    final button = buttonFor(label);
    expect(button, findsOneWidget);
    expect(tester.widget<ShadButton>(button).variant, variant);
    expect(tester.getRect(button).height, greaterThanOrEqualTo(44));
    final semantics = tester.getSemantics(find.text(label));
    expect(semantics.label, contains(label));
    expect(semantics.flagsCollection.toStrings(), contains('isFocusable'));
    expect(
      semantics.getSemanticsData().hasAction(ui.SemanticsAction.tap),
      isTrue,
    );
  }

  testWidgets('disconnected serving launcher makes scan primary', (
    tester,
  ) async {
    final routeNames = <String>[];
    await tester.binding.setSurfaceSize(const Size(1340, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    scaleController.mockEmitConnectionState(device.ConnectionState.connected);
    await tester.pumpWidget(buildSubject(routeNames: routeNames));
    await tester.pump();

    expect(find.byType(ConnectDeviceHeroCard), findsOneWidget);
    expectActionableButton(
      tester,
      'Scan for devices',
      ShadButtonVariant.primary,
    );
    expectActionableButton(tester, 'Return to Skin', ShadButtonVariant.outline);
    expect(
      tester.getRect(buttonFor('Scan for devices')).width,
      greaterThan(400),
    );
    expect(tester.takeException(), isNull);

    await tester.binding.setSurfaceSize(const Size(320, 800));
    await tester.pump();
    expectActionableButton(
      tester,
      'Scan for devices',
      ShadButtonVariant.primary,
    );
    expectActionableButton(tester, 'Return to Skin', ShadButtonVariant.outline);
    expect(tester.takeException(), isNull);

    final scanButton = buttonFor('Scan for devices');
    expect(tester.getRect(scanButton).width, greaterThanOrEqualTo(44));
    final focus = tester.widget<Focus>(
      find.descendant(of: scanButton, matching: find.byType(Focus)).last,
    );
    focus.focusNode!.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(routeNames, contains(LauncherScanPage.routeName));
    tester.state<NavigatorState>(find.byType(Navigator).first).pop();
    await tester.pumpAndSettle();

    routeNames.clear();
    await tester.tap(find.text('Scan for devices'));
    await tester.pumpAndSettle();
    expect(routeNames, [LauncherScanPage.routeName]);
    expect(find.text(LauncherScanPage.routeName), findsOneWidget);
    tester.state<NavigatorState>(find.byType(Navigator).first).pop();
    await tester.pumpAndSettle();

    final returnButton = buttonFor('Return to Skin');
    final returnFocus = tester.widget<Focus>(
      find.descendant(of: returnButton, matching: find.byType(Focus)).last,
    );
    returnFocus.focusNode!.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(routeNames, contains(SkinView.routeName));
  });

  testWidgets(
    'connected machine restores primary skin and disconnects to outline',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1920, 1080));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(buildSubject());
      await tester.pump();

      expect(find.byType(ConnectDeviceHeroCard), findsOneWidget);
      expectActionableButton(
        tester,
        'Scan for devices',
        ShadButtonVariant.primary,
      );
      expectActionableButton(
        tester,
        'Return to Skin',
        ShadButtonVariant.outline,
      );
      final launcherElement = tester.element(find.byType(LauncherView));

      de1Controller.de1Subject.add(FakeDe1());
      await tester.pump();

      expect(
        identical(launcherElement, tester.element(find.byType(LauncherView))),
        isTrue,
      );
      expect(find.byType(ConnectDeviceHeroCard), findsNothing);
      expectActionableButton(
        tester,
        'Return to Skin',
        ShadButtonVariant.primary,
      );

      de1Controller.de1Subject.add(null);
      await tester.pump();

      expect(
        identical(launcherElement, tester.element(find.byType(LauncherView))),
        isTrue,
      );
      expect(find.byType(ConnectDeviceHeroCard), findsOneWidget);
      expectActionableButton(
        tester,
        'Scan for devices',
        ShadButtonVariant.primary,
      );
      expectActionableButton(
        tester,
        'Return to Skin',
        ShadButtonVariant.outline,
      );

      de1Controller.de1Subject.add(FakeDe1());
      await tester.pump();
      expect(
        identical(launcherElement, tester.element(find.byType(LauncherView))),
        isTrue,
      );
      expectActionableButton(
        tester,
        'Return to Skin',
        ShadButtonVariant.primary,
      );
      await tester.tap(find.text('Return to Skin'));
      await tester.pumpAndSettle();
      expect(find.text(SkinView.routeName), findsOneWidget);
    },
  );

  testWidgets(
    'unsupported webview uses browser hero for connected and disconnected machines',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(600, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        buildSubject(
          webUIService: _FakeWebUIService(serving: true),
          supportsWebView: false,
        ),
      );
      await tester.pump();

      expect(find.byType(ConnectDeviceHeroCard), findsOneWidget);
      expect(find.byType(BrowserHeroCard), findsOneWidget);
      expect(find.text('Return to Skin'), findsNothing);
      expect(tester.takeException(), isNull);

      de1Controller.de1Subject.add(FakeDe1());
      await tester.pump();

      expect(find.byType(ConnectDeviceHeroCard), findsNothing);
      expect(find.byType(BrowserHeroCard), findsOneWidget);
      expect(find.text('Return to Skin'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'no serving and degraded browser states are mounted without overflow',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1340, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        buildSubject(webUIService: _FakeWebUIService(serving: false)),
      );
      await tester.pump();
      expect(find.byType(SkinUnavailableCard), findsOneWidget);
      expect(find.text('Return to Skin'), findsNothing);
      expect(tester.takeException(), isNull);

      await tester.binding.setSurfaceSize(const Size(600, 800));
      de1Controller.de1Subject.add(FakeDe1());
      await tester.pumpWidget(
        buildSubject(
          webUIService: _FakeWebUIService(serving: true),
          isDegradedAndroid: true,
        ),
      );
      await tester.pump();
      expect(find.byType(BrowserHeroCard), findsOneWidget);
      expect(find.text('Open in your browser'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
