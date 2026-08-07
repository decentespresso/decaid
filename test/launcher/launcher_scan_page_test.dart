import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/connection_manager.dart';
import 'package:reaprime/src/controllers/device_controller.dart';
import 'package:reaprime/src/controllers/scan_state_guardian.dart';
import 'package:reaprime/src/launcher/launcher_scan_page.dart';
import 'package:reaprime/src/settings/settings_controller.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import '../helpers/mock_connection_manager.dart';
import '../helpers/mock_de1_controller.dart';
import '../helpers/mock_device_discovery_service.dart';
import '../helpers/mock_device_scanner.dart';
import '../helpers/mock_scale_controller.dart';
import '../helpers/mock_settings_service.dart';

/// DeviceController that records stopScan calls.
class _SpyDeviceController extends DeviceController {
  int stopScanCalls = 0;
  _SpyDeviceController() : super([]);
  @override
  void stopScan() {
    stopScanCalls++;
    super.stopScan();
  }
}

void main() {
  late MockConnectionManager connectionManager;
  late _SpyDeviceController deviceController;
  late ScanStateGuardian guardian;
  late MockBleDiscoveryService bleService;
  late SettingsController settingsController;

  setUp(() async {
    settingsController = SettingsController(MockSettingsService());
    await settingsController.loadSettings();
    connectionManager = MockConnectionManager(
      deviceScanner: MockDeviceScanner(),
      de1Controller: MockDe1Controller(controller: DeviceController([])),
      scaleController: MockScaleController(),
      settingsController: settingsController,
    );
    deviceController = _SpyDeviceController();
    bleService = MockBleDiscoveryService();
    guardian = ScanStateGuardian(bleService: bleService);
  });

  tearDown(() {
    connectionManager.dispose();
    guardian.dispose();
    bleService.dispose();
  });

  Widget host() => ShadApp(
    home: Builder(
      builder: (context) => Scaffold(
        body: Center(
          child: ElevatedButton(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => LauncherScanPage(
                  connectionManager: connectionManager,
                  deviceController: deviceController,
                  settingsController: settingsController,
                  scanStateGuardian: guardian,
                ),
              ),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );

  testWidgets('pops back to launcher when phase reaches ready', (tester) async {
    await tester.pumpWidget(host());
    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump();

    expect(find.byType(LauncherScanPage), findsOneWidget);

    connectionManager.emitStatus(
      const ConnectionStatus(phase: ConnectionPhase.ready),
    );
    await tester.pumpAndSettle();

    expect(find.byType(LauncherScanPage), findsNothing);
    expect(find.text('open'), findsOneWidget);
  });

  testWidgets('cancel stops the scan and pops', (tester) async {
    await tester.pumpWidget(host());
    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump();

    connectionManager.emitStatus(
      const ConnectionStatus(
        phase: ConnectionPhase.idle,
        foundMachines: [],
        pendingAmbiguity: AmbiguityReason.machinePicker,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(deviceController.stopScanCalls, greaterThanOrEqualTo(1));
    expect(find.byType(LauncherScanPage), findsNothing);
  });
}
