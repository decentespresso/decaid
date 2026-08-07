import 'package:reaprime/src/models/device/de1_interface.dart';
import 'package:reaprime/src/models/device/scale.dart';

sealed class MachinePolicyAction {
  const MachinePolicyAction();
}

final class ConnectMachineAction extends MachinePolicyAction {
  final De1Interface machine;
  const ConnectMachineAction(this.machine);
}

final class MachinePickerAction extends MachinePolicyAction {
  const MachinePickerAction();
}

final class NoMachineAction extends MachinePolicyAction {
  final bool hasOtherMachines;
  const NoMachineAction({required this.hasOtherMachines});
}

MachinePolicyAction resolveMachinePolicy({
  required List<De1Interface> machines,
  required String? preferredMachineId,
}) {
  if (preferredMachineId != null) {
    final match = machines
        .where((machine) => machine.deviceId == preferredMachineId)
        .firstOrNull;
    if (match != null) return ConnectMachineAction(match);
    if (machines.isNotEmpty) return const MachinePickerAction();
    return const NoMachineAction(hasOtherMachines: false);
  }
  if (machines.isEmpty) {
    return const NoMachineAction(hasOtherMachines: false);
  }
  if (machines.length == 1) return ConnectMachineAction(machines.first);
  return const MachinePickerAction();
}

sealed class ScalePolicyAction {
  const ScalePolicyAction();
}

final class ConnectScaleAction extends ScalePolicyAction {
  final Scale scale;
  const ConnectScaleAction(this.scale);
}

final class ScalePickerAction extends ScalePolicyAction {
  const ScalePickerAction();
}

final class NoScaleAction extends ScalePolicyAction {
  const NoScaleAction();
}

ScalePolicyAction resolveScalePolicy({
  required List<Scale> scales,
  required String? preferredScaleId,
}) {
  if (preferredScaleId != null) {
    final match = scales
        .where((s) => s.deviceId == preferredScaleId)
        .firstOrNull;
    if (match != null) return ConnectScaleAction(match);
    if (scales.isNotEmpty) return const ScalePickerAction();
    return const NoScaleAction();
  }
  if (scales.length == 1) return ConnectScaleAction(scales.first);
  if (scales.length > 1) return const ScalePickerAction();
  return const NoScaleAction();
}
