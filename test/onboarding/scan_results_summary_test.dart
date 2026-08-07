import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/adapter_state.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/scan_report.dart';
import 'package:reaprime/src/onboarding_feature/widgets/scan_results_summary.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

ScanReport _makeReport({
  int totalBleDevicesSeen = 0,
  List<MatchedDevice> matchedDevices = const [],
  String? preferredMachineId,
}) {
  return ScanReport(
    totalBleDevicesSeen: totalBleDevicesSeen,
    matchedDevices: matchedDevices,
    scanDuration: const Duration(seconds: 10),
    adapterStateAtStart: AdapterState.poweredOn,
    adapterStateAtEnd: AdapterState.poweredOn,
    scanTerminationReason: ScanTerminationReason.completed,
    preferredMachineId: preferredMachineId,
  );
}

Widget _buildWidget(
  ScanReport report, {
  VoidCallback? onScanAgain,
  VoidCallback? onTroubleshoot,
  VoidCallback? onExportLogs,
  VoidCallback? onContinueToDashboard,
  VoidCallback? onTryDemoMode,
}) {
  return ShadApp(
    home: Scaffold(
      body: SingleChildScrollView(
        child: ScanResultsSummary(
          report: report,
          onScanAgain: onScanAgain ?? () {},
          onTroubleshoot: onTroubleshoot ?? () {},
          onExportLogs: onExportLogs ?? () {},
          onContinueToDashboard: onContinueToDashboard ?? () {},
          onTryDemoMode: onTryDemoMode ?? () {},
        ),
      ),
    ),
  );
}

void main() {
  group('ScanResultsSummary', () {
    testWidgets(
      'shows "no BLE devices detected" when totalBleDevicesSeen is 0',
      (tester) async {
        final report = _makeReport(totalBleDevicesSeen: 0);
        await tester.pumpWidget(_buildWidget(report));
        await tester.pump();

        expect(
          find.text('No Bluetooth devices were detected at all'),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'shows "devices found but none matched" when seen > 0 but no matches',
      (tester) async {
        final report = _makeReport(totalBleDevicesSeen: 5);
        await tester.pumpWidget(_buildWidget(report));
        await tester.pump();

        expect(
          find.text('5 BLE devices found, but none matched a Decent machine'),
          findsOneWidget,
        );
      },
    );

    testWidgets('shows preferred machine not found message', (tester) async {
      final report = _makeReport(
        totalBleDevicesSeen: 3,
        preferredMachineId: 'abc',
        matchedDevices: [],
      );
      await tester.pumpWidget(_buildWidget(report));
      await tester.pump();

      expect(
        find.text("Your preferred machine wasn't found during the scan"),
        findsOneWidget,
      );
    });

    testWidgets('shows connection failure details', (tester) async {
      final report = _makeReport(
        totalBleDevicesSeen: 2,
        matchedDevices: [
          MatchedDevice(
            deviceName: 'DE1-Cafe',
            deviceId: 'id-1',
            deviceType: DeviceType.machine,
            connectionAttempted: true,
            connectionResult: ConnectionResult.failed('Timeout after 10s'),
          ),
        ],
      );
      await tester.pumpWidget(_buildWidget(report));
      await tester.pump();

      expect(
        find.text('Found DE1-Cafe but connection failed: Timeout after 10s'),
        findsOneWidget,
      );
    });

    testWidgets('has all five action buttons', (tester) async {
      final report = _makeReport();
      await tester.pumpWidget(_buildWidget(report));
      await tester.pump();

      expect(find.text('Scan Again'), findsOneWidget);
      expect(find.text('Try Demo Mode'), findsOneWidget);
      expect(find.text('Troubleshoot'), findsOneWidget);
      expect(find.text('Export Logs'), findsOneWidget);
      expect(find.text('Continue to Dashboard'), findsOneWidget);
    });

    testWidgets('tapping Try Demo Mode calls callback', (tester) async {
      var called = false;
      final report = _makeReport();
      await tester.pumpWidget(
        _buildWidget(report, onTryDemoMode: () => called = true),
      );
      await tester.pump();

      await tester.tap(find.text('Try Demo Mode'));
      expect(called, isTrue);
    });

    testWidgets('tapping Scan Again calls callback', (tester) async {
      var called = false;
      final report = _makeReport();
      await tester.pumpWidget(
        _buildWidget(report, onScanAgain: () => called = true),
      );
      await tester.pump();

      await tester.tap(find.text('Scan Again'));
      expect(called, isTrue);
    });

    testWidgets('tapping Troubleshoot calls callback', (tester) async {
      var called = false;
      final report = _makeReport();
      await tester.pumpWidget(
        _buildWidget(report, onTroubleshoot: () => called = true),
      );
      await tester.pump();

      await tester.tap(find.text('Troubleshoot'));
      expect(called, isTrue);
    });

    testWidgets('tapping Export Logs calls callback', (tester) async {
      var called = false;
      final report = _makeReport();
      await tester.pumpWidget(
        _buildWidget(report, onExportLogs: () => called = true),
      );
      await tester.pump();

      await tester.tap(find.text('Export Logs'));
      expect(called, isTrue);
    });

    testWidgets('tapping Continue to Dashboard calls callback', (tester) async {
      var called = false;
      final report = _makeReport();
      await tester.pumpWidget(
        _buildWidget(report, onContinueToDashboard: () => called = true),
      );
      await tester.pump();

      await tester.tap(find.text('Continue to Dashboard'));
      expect(called, isTrue);
    });

    testWidgets(
      'preferred machine message takes priority over generic no-match',
      (tester) async {
        final report = _makeReport(
          totalBleDevicesSeen: 3,
          preferredMachineId: 'abc',
          matchedDevices: [],
        );
        await tester.pumpWidget(_buildWidget(report));
        await tester.pump();

        expect(
          find.text("Your preferred machine wasn't found during the scan"),
          findsOneWidget,
        );
        expect(
          find.text('3 BLE devices found, but none matched a Decent machine'),
          findsNothing,
        );
      },
    );

    testWidgets(
      'connection failure takes priority over preferred machine message',
      (tester) async {
        final report = _makeReport(
          totalBleDevicesSeen: 2,
          preferredMachineId: 'other-id',
          matchedDevices: [
            MatchedDevice(
              deviceName: 'DE1-Cafe',
              deviceId: 'id-1',
              deviceType: DeviceType.machine,
              connectionAttempted: true,
              connectionResult: ConnectionResult.failed('Timeout'),
            ),
          ],
        );
        await tester.pumpWidget(_buildWidget(report));
        await tester.pump();

        expect(
          find.text('Found DE1-Cafe but connection failed: Timeout'),
          findsOneWidget,
        );
      },
    );
  });
}
