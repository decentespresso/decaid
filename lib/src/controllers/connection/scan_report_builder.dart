import 'package:reaprime/src/models/adapter_state.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/scan_report.dart';

class MatchedDeviceTracker {
  final String deviceName;
  final String deviceId;
  final DeviceType deviceType;
  bool connectionAttempted = false;
  ConnectionResult? connectionResult;

  MatchedDeviceTracker({
    required this.deviceName,
    required this.deviceId,
    required this.deviceType,
  });

  MatchedDevice toMatchedDevice() => MatchedDevice(
    deviceName: deviceName,
    deviceId: deviceId,
    deviceType: deviceType,
    connectionAttempted: connectionAttempted,
    connectionResult: connectionResult,
  );
}

class ScanReportBuilder {
  final DateTime scanStartTime;

  Duration? _measuredScanDuration;
  final Map<String, MatchedDeviceTracker> _trackers = {};

  AdapterState _adapterStateAtStart = AdapterState.unknown;

  ScanReportBuilder({required this.scanStartTime});

  void recordAdapterStateAtStart(AdapterState state) {
    _adapterStateAtStart = state;
  }

  void recordScanDuration(Duration duration) {
    _measuredScanDuration = duration;
  }

  void seed(Device d) {
    _trackers.putIfAbsent(
      d.deviceId,
      () => MatchedDeviceTracker(
        deviceName: d.name,
        deviceId: d.deviceId,
        deviceType: d.type,
      ),
    );
  }

  void markAttempted(String deviceId) {
    _trackers[deviceId]?.connectionAttempted = true;
  }

  void recordResult(String deviceId, ConnectionResult result) {
    _trackers[deviceId]?.connectionResult = result;
  }

  ScanReport build({
    required String? preferredMachineId,
    required String? preferredScaleId,
    required ScanTerminationReason terminationReason,
    required AdapterState adapterStateAtEnd,
  }) {
    final matchedDevices = _trackers.values
        .map((t) => t.toMatchedDevice())
        .toList();
    return ScanReport(
      totalBleDevicesSeen: matchedDevices.length,
      matchedDevices: matchedDevices,
      scanDuration:
          _measuredScanDuration ?? DateTime.now().difference(scanStartTime),
      adapterStateAtStart: _adapterStateAtStart,
      adapterStateAtEnd: adapterStateAtEnd,
      scanTerminationReason: terminationReason,
      preferredMachineId: preferredMachineId,
      preferredScaleId: preferredScaleId,
    );
  }

  static String format(ScanReport report) {
    final buf = StringBuffer('Scan report: ');
    buf.write('${report.matchedDevices.length} devices matched, ');
    buf.write('duration=${report.scanDuration.inMilliseconds}ms, ');
    buf.write('termination=${report.scanTerminationReason.name}');

    if (report.preferredMachineId != null) {
      final found = report.matchedDevices.any(
        (d) => d.deviceId == report.preferredMachineId,
      );
      buf.write(
        ', preferred machine ${report.preferredMachineId} '
        '${found ? "found" : "NOT found"}',
      );
    }
    if (report.preferredScaleId != null) {
      final found = report.matchedDevices.any(
        (d) => d.deviceId == report.preferredScaleId,
      );
      buf.write(
        ', preferred scale ${report.preferredScaleId} '
        '${found ? "found" : "NOT found"}',
      );
    }

    for (final d in report.matchedDevices) {
      buf.write('\n  ${d.deviceName} (${d.deviceId}, ${d.deviceType.name})');
      if (d.connectionAttempted) {
        final result = d.connectionResult;
        if (result == null) {
          buf.write(' — connection attempted, no result');
        } else if (result.success) {
          buf.write(' — connected');
        } else if (result.error != null) {
          buf.write(' — connection failed: ${result.error}');
        } else {
          buf.write(' — skipped');
        }
      }
    }

    return buf.toString();
  }
}
