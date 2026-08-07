import 'package:reaprime/src/controllers/connection_manager.dart';
import 'package:reaprime/src/models/device/device.dart';

enum TransportConditionDisposition { hidden, notice, blocking }

TransportConditionDisposition resolveTransportCondition(
  ConnectionStatus status,
  TransportCondition condition,
) {
  final deviceType =
      status.pendingAmbiguity == AmbiguityReason.scalePicker ||
          status.phase == ConnectionPhase.connectingScale ||
          status.intent == ConnectionIntent.scaleRecovery
      ? DeviceType.scale
      : DeviceType.machine;
  if (!condition.affectedDeviceTypes.contains(deviceType)) {
    return TransportConditionDisposition.hidden;
  }

  final targetTransport = status.activeTargetTransport;
  if (targetTransport != null) {
    return targetTransport == condition.transportType
        ? TransportConditionDisposition.blocking
        : TransportConditionDisposition.notice;
  }

  final candidates = deviceType == DeviceType.machine
      ? status.foundMachines
      : status.foundScales;
  if (candidates.isNotEmpty) {
    return candidates.any(
          (candidate) => candidate.transportType != condition.transportType,
        )
        ? TransportConditionDisposition.notice
        : TransportConditionDisposition.blocking;
  }

  if (status.phase == ConnectionPhase.scanning &&
      status.intent != ConnectionIntent.scaleRecovery) {
    return TransportConditionDisposition.notice;
  }
  if (status.phase == ConnectionPhase.ready) {
    return TransportConditionDisposition.notice;
  }
  return TransportConditionDisposition.blocking;
}
