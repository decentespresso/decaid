import 'package:flutter/material.dart';
import 'package:reaprime/src/models/scan_report.dart';
import 'package:reaprime/src/widgets/accessible_button.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

/// Displays a human-readable summary of scan results when no devices
/// are successfully connected. Derives a contextual message from the
/// [ScanReport] and offers action buttons for next steps.
class ScanResultsSummary extends StatelessWidget {
  final ScanReport report;
  final VoidCallback onScanAgain;
  final VoidCallback onTroubleshoot;
  final VoidCallback onExportLogs;
  final VoidCallback onContinueToDashboard;
  final VoidCallback onTryDemoMode;

  const ScanResultsSummary({
    super.key,
    required this.report,
    required this.onScanAgain,
    required this.onTroubleshoot,
    required this.onExportLogs,
    required this.onContinueToDashboard,
    required this.onTryDemoMode,
  });

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final (icon, heading, message) = _deriveContent();

    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 600),
      child: ShadCard(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            spacing: 24,
            children: [
              ExcludeSemantics(
                child: Icon(
                  icon,
                  size: 64,
                  color: theme.colorScheme.primary.withValues(alpha: 0.7),
                ),
              ),
              Column(
                spacing: 8,
                children: [
                  Text(
                    heading,
                    style: theme.textTheme.h3,
                    textAlign: TextAlign.center,
                  ),
                  Text(
                    message,
                    style: theme.textTheme.muted,
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
              Column(
                spacing: 12,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  AccessibleButton(
                    label: 'Scan Again',
                    onTap: onScanAgain,
                    child: ShadButton(
                      onPressed: onScanAgain,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        spacing: 8,
                        children: [
                          Icon(LucideIcons.refreshCw, size: 16),
                          Text('Scan Again'),
                        ],
                      ),
                    ),
                  ),
                  AccessibleButton(
                    label: 'Try Demo Mode',
                    onTap: onTryDemoMode,
                    child: ShadButton.outline(
                      onPressed: onTryDemoMode,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        spacing: 8,
                        children: [
                          Icon(LucideIcons.gamepad2, size: 16),
                          Text('Try Demo Mode'),
                        ],
                      ),
                    ),
                  ),
                  Row(
                    spacing: 12,
                    children: [
                      Expanded(
                        child: AccessibleButton(
                          label: 'Troubleshoot',
                          onTap: onTroubleshoot,
                          child: ShadButton.outline(
                            onPressed: onTroubleshoot,
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              spacing: 8,
                              children: [
                                Icon(LucideIcons.wrench, size: 16),
                                Text('Troubleshoot'),
                              ],
                            ),
                          ),
                        ),
                      ),
                      Expanded(
                        child: AccessibleButton(
                          label: 'Export Logs',
                          onTap: onExportLogs,
                          child: ShadButton.outline(
                            onPressed: onExportLogs,
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              spacing: 8,
                              children: [
                                Icon(LucideIcons.fileText, size: 16),
                                Text('Export Logs'),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                  AccessibleButton(
                    label: 'Continue to Dashboard',
                    onTap: onContinueToDashboard,
                    child: ShadButton.secondary(
                      onPressed: onContinueToDashboard,
                      child: const Text('Continue to Dashboard'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Derives icon, heading, and message from the scan report.
  ///
  /// Priority order:
  /// 1. No BLE devices seen at all
  /// 2. Matched device with failed connection
  /// 3. Preferred machine not found
  /// 4. Devices seen but none matched
  (IconData, String, String) _deriveContent() {
    if (report.totalBleDevicesSeen == 0) {
      return (
        LucideIcons.bluetoothOff,
        'No Bluetooth Devices Found',
        'No Bluetooth devices were detected at all',
      );
    }

    final failedDevice = report.matchedDevices
        .where(
          (d) =>
              d.connectionAttempted &&
              d.connectionResult != null &&
              !d.connectionResult!.success &&
              d.connectionResult!.error != null,
        )
        .firstOrNull;

    if (failedDevice != null) {
      return (
        LucideIcons.unplug,
        'Connection Failed',
        'Found ${failedDevice.deviceName} but connection failed: ${failedDevice.connectionResult!.error}',
      );
    }

    if (report.preferredMachineId != null &&
        !report.matchedDevices.any(
          (d) => d.deviceId == report.preferredMachineId,
        )) {
      return (
        LucideIcons.searchX,
        'Preferred Machine Not Found',
        "Your preferred machine wasn't found during the scan",
      );
    }

    return (
      LucideIcons.searchX,
      'No Decent Machines Found',
      '${report.totalBleDevicesSeen} BLE devices found, but none matched a Decent machine',
    );
  }
}
