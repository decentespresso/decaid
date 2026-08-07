import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/scan_report.dart'
    show ScanTerminationReason;

export 'package:reaprime/src/models/scan_report.dart'
    show ScanTerminationReason;

class ScanResult {
  final List<Device> matchedDevices;
  final List<ServiceScanFailure> failedServices;
  final ScanTerminationReason terminationReason;
  final Duration duration;

  const ScanResult({
    required this.matchedDevices,
    required this.failedServices,
    required this.terminationReason,
    required this.duration,
  });
}

class ServiceScanFailure {
  final String serviceName;
  final Object error;
  final StackTrace stackTrace;

  const ServiceScanFailure({
    required this.serviceName,
    required this.error,
    required this.stackTrace,
  });
}
