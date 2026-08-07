import 'package:reaprime/src/models/device/machine.dart';

const Duration kHotWaterArmTimeout = Duration(seconds: 10);

class HotWaterStopState {
  final double targetWeight;

  final double configuredFlow;

  final double lookaheadSeconds;

  final bool activeSeen;

  final bool stopRequested;

  const HotWaterStopState({
    required this.targetWeight,
    required this.configuredFlow,
    required this.lookaheadSeconds,
    this.activeSeen = false,
    this.stopRequested = false,
  });

  HotWaterStopState copyWith({bool? activeSeen, bool? stopRequested}) {
    return HotWaterStopState(
      targetWeight: targetWeight,
      configuredFlow: configuredFlow,
      lookaheadSeconds: lookaheadSeconds,
      activeSeen: activeSeen ?? this.activeSeen,
      stopRequested: stopRequested ?? this.stopRequested,
    );
  }
}

class HotWaterStopInput {
  final MachineState? machineState;

  final Duration sinceArmed;

  final bool tareSettled;

  final bool freshScale;

  final double? weight;

  final double? weightFlow;

  const HotWaterStopInput({
    required this.machineState,
    required this.sinceArmed,
    required this.tareSettled,
    required this.freshScale,
    required this.weight,
    required this.weightFlow,
  });
}

enum HotWaterStopAction { wait, clear, stop }

class HotWaterStopDecision {
  final HotWaterStopAction action;

  final HotWaterStopState? state;

  final double weight;
  final double projectedWeight;

  const HotWaterStopDecision._(
    this.action,
    this.state, {
    this.weight = 0,
    this.projectedWeight = 0,
  });

  factory HotWaterStopDecision.wait(HotWaterStopState state) =>
      HotWaterStopDecision._(HotWaterStopAction.wait, state);

  factory HotWaterStopDecision.clear() =>
      const HotWaterStopDecision._(HotWaterStopAction.clear, null);

  factory HotWaterStopDecision.stop(
    HotWaterStopState state, {
    required double weight,
    required double projectedWeight,
  }) => HotWaterStopDecision._(
    HotWaterStopAction.stop,
    state,
    weight: weight,
    projectedWeight: projectedWeight,
  );
}

HotWaterStopDecision nextHotWaterStop(
  HotWaterStopState state,
  HotWaterStopInput input,
) {
  var next = state;
  if (input.machineState == MachineState.hotWater) {
    next = next.copyWith(activeSeen: true);
  } else if (next.activeSeen || input.sinceArmed > kHotWaterArmTimeout) {
    return HotWaterStopDecision.clear();
  }

  if (!next.activeSeen || next.stopRequested) {
    return HotWaterStopDecision.wait(next);
  }
  if (!input.freshScale) return HotWaterStopDecision.wait(next);
  if (!input.tareSettled) return HotWaterStopDecision.wait(next);

  final weight = _finite(input.weight) ?? 0.0;
  final flow = _positive(input.weightFlow) ?? next.configuredFlow;
  final projectedWeight = weight + flow * next.lookaheadSeconds;
  if (projectedWeight < next.targetWeight) {
    return HotWaterStopDecision.wait(next);
  }

  next = next.copyWith(stopRequested: true);
  return HotWaterStopDecision.stop(
    next,
    weight: weight,
    projectedWeight: projectedWeight,
  );
}

double? _finite(double? value) =>
    (value != null && value.isFinite) ? value : null;

double? _positive(double? value) =>
    (value != null && value.isFinite && value > 0) ? value : null;
