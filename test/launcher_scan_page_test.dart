import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/connection_manager.dart';
import 'package:reaprime/src/controllers/device_controller.dart';
import 'package:reaprime/src/controllers/scan_state_guardian.dart';
import 'package:reaprime/src/launcher/launcher_scan_page.dart';
import 'package:reaprime/src/settings/settings_controller.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import 'helpers/mock_connection_manager.dart';
import 'helpers/mock_de1_controller.dart';
import 'helpers/mock_device_discovery_service.dart';
import 'helpers/mock_device_scanner.dart';
import 'helpers/mock_scale_controller.dart';
import 'helpers/mock_settings_service.dart';

void main() {
  late MockConnectionManager mockCm;
  late DeviceController deviceController;
  late SettingsController settingsController;
  late ScanStateGuardian scanStateGuardian;

  setUp(() async {
    final scanner = MockDeviceScanner();
    final de1 = MockDe1Controller(controller: DeviceController([]));
    final scale = MockScaleController();
    final settings = SettingsController(MockSettingsService());
    await settings.loadSettings();

    mockCm = MockConnectionManager(
      deviceScanner: scanner,
      de1Controller: de1,
      scaleController: scale,
      settingsController: settings,
    );

    final discovery = MockBleDiscoveryService();
    deviceController = DeviceController([discovery]);
    await deviceController.initialize();
    settingsController = settings;
    scanStateGuardian = ScanStateGuardian(bleService: discovery);
  });

  Widget buildPage() {
    return ShadApp(
      home: LauncherScanPage(
        connectionManager: mockCm,
        deviceController: deviceController,
        settingsController: settingsController,
        scanStateGuardian: scanStateGuardian,
      ),
    );
  }

  testWidgets('opens with scanAndConnect, not connect', (tester) async {
    await tester.pumpWidget(buildPage());
    await tester.pump();

    expect(mockCm.scanAndConnectCallCount, 1);
    expect(
      mockCm.connectCallCount - mockCm.scanAndConnectCallCount,
      0,
      reason: 'all connect calls should be scanAndConnect',
    );
  });

  testWidgets('cancel calls cancelActiveScan', (tester) async {
    mockCm.emitStatus(
      ConnectionStatus(
        phase: ConnectionPhase.idle,
        pendingAmbiguity: AmbiguityReason.machinePicker,
        foundMachines: [],
      ),
    );

    await tester.pumpWidget(buildPage());
    await tester.pump();

    final cancelFinder = find.text('Cancel');
    expect(cancelFinder, findsOneWidget);

    await tester.tap(cancelFinder);
    await tester.pump();

    expect(mockCm.cancelActiveScanCallCount, 1);
  });
}
