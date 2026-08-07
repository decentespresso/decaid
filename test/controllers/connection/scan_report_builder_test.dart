import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/connection/scan_report_builder.dart';
import 'package:reaprime/src/models/adapter_state.dart';
import 'package:reaprime/src/models/scan_report.dart';

void main() {
  group('ScanReportBuilder adapter state (comms-harden #27)', () {
    test('build() uses the recorded start state + supplied end state', () {
      final builder = ScanReportBuilder(scanStartTime: DateTime.now())
        ..recordAdapterStateAtStart(AdapterState.poweredOff);

      final report = builder.build(
        preferredMachineId: null,
        preferredScaleId: null,
        terminationReason: ScanTerminationReason.completed,
        adapterStateAtEnd: AdapterState.poweredOn,
      );

      expect(report.adapterStateAtStart, AdapterState.poweredOff);
      expect(report.adapterStateAtEnd, AdapterState.poweredOn);
    });

    test(
      'build() defaults adapterStateAtStart to unknown when not recorded',
      () {
        final builder = ScanReportBuilder(scanStartTime: DateTime.now());

        final report = builder.build(
          preferredMachineId: null,
          preferredScaleId: null,
          terminationReason: ScanTerminationReason.completed,
          adapterStateAtEnd: AdapterState.unknown,
        );

        expect(report.adapterStateAtStart, AdapterState.unknown);
      },
    );
  });

  group('ScanReportBuilder scan duration', () {
    test('build() prefers the scanner-measured duration over wall time', () {
      final builder = ScanReportBuilder(
        scanStartTime: DateTime.now().subtract(const Duration(minutes: 5)),
      )..recordScanDuration(const Duration(seconds: 15));

      final report = builder.build(
        preferredMachineId: null,
        preferredScaleId: null,
        terminationReason: ScanTerminationReason.completed,
        adapterStateAtEnd: AdapterState.poweredOn,
      );

      expect(report.scanDuration, const Duration(seconds: 15));
    });

    test('build() falls back to wall time since scanStartTime', () {
      final builder = ScanReportBuilder(
        scanStartTime: DateTime.now().subtract(const Duration(seconds: 30)),
      );

      final report = builder.build(
        preferredMachineId: null,
        preferredScaleId: null,
        terminationReason: ScanTerminationReason.completed,
        adapterStateAtEnd: AdapterState.poweredOn,
      );

      expect(report.scanDuration.inSeconds, greaterThanOrEqualTo(30));
    });
  });
}
