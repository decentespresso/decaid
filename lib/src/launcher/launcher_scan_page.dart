import 'package:flutter/material.dart';
import 'package:reaprime/src/controllers/connection_manager.dart';
import 'package:reaprime/src/controllers/device_controller.dart';
import 'package:reaprime/src/controllers/scan_state_guardian.dart';
import 'package:reaprime/src/device_discovery_feature/scan_flow_view.dart';
import 'package:reaprime/src/settings/settings_controller.dart';

class LauncherScanPage extends StatelessWidget {
  static const routeName = '/launcher-scan';

  const LauncherScanPage({
    super.key,
    required this.connectionManager,
    required this.deviceController,
    required this.settingsController,
    required this.scanStateGuardian,
  });

  final ConnectionManager connectionManager;
  final DeviceController deviceController;
  final SettingsController settingsController;
  final ScanStateGuardian scanStateGuardian;

  void _cancelAndExit(BuildContext context) {
    connectionManager.cancelActiveScan();
    deviceController.stopScan();
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) {
          _cancelAndExit(context);
        }
      },
      child: ScanFlowView(
        connectionManager: connectionManager,
        deviceController: deviceController,
        settingsController: settingsController,
        scanStateGuardian: scanStateGuardian,
        initialConnectionIntent: () => connectionManager.scanAndConnect(),
        onConnected: () => Navigator.of(context).pop(),
        onExit: () => _cancelAndExit(context),
        exitLabel: 'Cancel',
      ),
    );
  }
}
