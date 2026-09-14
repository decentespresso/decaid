import 'package:reaprime/src/controllers/connection/scan_report_builder.dart';
import 'package:reaprime/src/models/adapter_state.dart';
import 'package:reaprime/src/models/device/de1_interface.dart';
import 'package:reaprime/src/models/device/scale.dart';
import 'package:reaprime/src/models/scan_report.dart';

enum ConnectionSelectionSessionState { active, completed, cancelled }

class ConnectionSelectionSession {
  final List<De1Interface> machines;
  final List<Scale> scales;
  final String? preferredMachineId;
  final String? preferredScaleId;

  /// Scales a client is holding open for its own purposes. Brewing never
  /// selects one: with two scales in range this is the only thing standing
  /// between the shot and being weighed on the wrong one.
  final Set<String> auxiliaryScaleIds;
  final ScanReportBuilder scanReport;

  ConnectionSelectionSessionState _state =
      ConnectionSelectionSessionState.active;

  ConnectionSelectionSession({
    required List<De1Interface> machines,
    required List<Scale> scales,
    required this.preferredMachineId,
    required this.preferredScaleId,
    Set<String> auxiliaryScaleIds = const {},
    required this.scanReport,
  }) : auxiliaryScaleIds = Set.unmodifiable(auxiliaryScaleIds),
       machines = List.unmodifiable(machines),
       scales = List.unmodifiable(scales);

  ConnectionSelectionSessionState get state => _state;
  bool get isActive => _state == ConnectionSelectionSessionState.active;

  bool acceptsMachine(De1Interface machine) =>
      isActive &&
      machines.any((candidate) => candidate.deviceId == machine.deviceId);

  bool acceptsScale(Scale scale) =>
      isActive &&
      !isAuxiliaryScale(scale.deviceId) &&
      scales.any((candidate) => candidate.deviceId == scale.deviceId);

  bool isAuxiliaryScale(String deviceId) =>
      auxiliaryScaleIds.contains(deviceId);

  ScanReport? finish({
    required ScanTerminationReason reason,
    required AdapterState adapterStateAtEnd,
  }) {
    if (!isActive) return null;
    _state = reason == ScanTerminationReason.cancelledByUser
        ? ConnectionSelectionSessionState.cancelled
        : ConnectionSelectionSessionState.completed;
    return scanReport.build(
      preferredMachineId: preferredMachineId,
      preferredScaleId: preferredScaleId,
      terminationReason: reason,
      adapterStateAtEnd: adapterStateAtEnd,
    );
  }

  De1Interface? resolveMachine(String deviceId) {
    return machines.cast<De1Interface?>().firstWhere(
      (candidate) => candidate?.deviceId == deviceId,
      orElse: () => null,
    );
  }

  Scale? resolveScale(String deviceId) {
    return scales.cast<Scale?>().firstWhere(
      (candidate) => candidate?.deviceId == deviceId,
      orElse: () => null,
    );
  }

  void invalidate() {
    if (isActive) {
      _state = ConnectionSelectionSessionState.cancelled;
    }
  }
}
