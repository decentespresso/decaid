import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/device_controller.dart';
import 'package:reaprime/src/controllers/scan_state_guardian.dart';
import 'package:reaprime/src/launcher/launcher_view.dart';
import 'package:reaprime/src/launcher/widgets/connect_device_hero_card.dart';
import 'package:reaprime/src/settings/settings_controller.dart';
import 'package:reaprime/src/webui_support/webui_service.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import '../helpers/mock_connection_manager.dart';
import '../helpers/mock_de1_controller.dart';
import '../helpers/mock_device_discovery_service.dart';
import '../helpers/mock_device_scanner.dart';
import '../helpers/mock_scale_controller.dart';
import '../helpers/mock_settings_service.dart';

void main() {
  late MockDe1Controller de1Controller;
  late MockScaleController scaleController;
  late MockConnectionManager connectionManager;
  late ScanStateGuardian guardian;
  late MockBleDiscoveryService bleService;
  late SettingsController settingsController;
  late WebUIService webUIService;

  setUp(() async {
    settingsController = SettingsController(MockSettingsService());
    await settingsController.loadSettings();
    de1Controller = MockDe1Controller(controller: DeviceController([]));
    scaleController = MockScaleController();
    connectionManager = MockConnectionManager(
      deviceScanner: MockDeviceScanner(),
      de1Controller: de1Controller,
      scaleController: scaleController,
      settingsController: settingsController,
    );
    bleService = MockBleDiscoveryService();
    guardian = ScanStateGuardian(bleService: bleService);
    webUIService = WebUIService();
  });

  tearDown(() {
    connectionManager.dispose();
    guardian.dispose();
    bleService.dispose();
  });

  Widget buildLauncher() => ShadApp(
    home: LauncherView(
      de1Controller: de1Controller,
      scaleController: scaleController,
      webUIService: webUIService,
      connectionManager: connectionManager,
      deviceController: DeviceController([]),
      settingsController: settingsController,
      scanStateGuardian: guardian,
    ),
  );

  testWidgets('hero shows when no machine connected', (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    de1Controller.de1Subject.add(null);
    await tester.pumpWidget(buildLauncher());
    await tester.pump();

    expect(find.byType(ConnectDeviceHeroCard), findsOneWidget);
  });

  testWidgets('hero hidden when a machine is connected', (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    de1Controller.de1Subject.add(FakeDe1());
    await tester.pumpWidget(buildLauncher());
    await tester.pump();

    expect(find.byType(ConnectDeviceHeroCard), findsNothing);
  });

  testWidgets('plugins destination is always visible', (tester) async {
    await tester.pumpWidget(buildLauncher());
    await tester.pump();

    expect(find.text('Plugins'), findsOneWidget);
  });
}
