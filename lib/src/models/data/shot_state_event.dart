import 'package:clock/clock.dart';
import 'package:reaprime/src/models/device/machine.dart';

enum ShotState { idle, preheating, pouring, stopping, finished }

enum ShotDecisionKind { advance, stop, abort, terminal, finalize }

enum ShotDecisionReason {
  noScale,

  targetWeight,

  targetVolume,

  apiStop,

  appStop,

  machineEnded,

  profileAdvance,

  profileSkip,

  error,

  disconnected,

  stoppingBackstop,
}

class ShotDecision {
  final ShotDecisionKind kind;
  final ShotDecisionReason reason;
  final String? details;
  final Map<String, dynamic>? data;

  const ShotDecision({
    required this.kind,
    required this.reason,
    this.details,
    this.data,
  });

  Map<String, dynamic> toJson() => {
    'kind': kind.name,
    'reason': reason.name,
    'details': details,
    'data': data,
  };
}

class ShotStateEvent {
  final String event;

  final DateTime timestamp;

  final String? shotId;
  final ShotState state;
  final MachineState? machineState;
  final MachineSubstate? machineSubstate;
  final int? profileFrame;
  final bool scaleConnected;

  final bool scaleLost;
  final bool machineHasAutonomousSAW;
  final ShotDecision? decision;

  ShotStateEvent({
    required this.event,
    required this.timestamp,
    required this.state,
    this.shotId,
    this.machineState,
    this.machineSubstate,
    this.profileFrame,
    this.scaleConnected = false,
    this.scaleLost = false,
    this.machineHasAutonomousSAW = false,
    this.decision,
  });

  factory ShotStateEvent.idle() => ShotStateEvent(
    event: 'state',
    timestamp: clock.now(),
    state: ShotState.idle,
  );

  Map<String, dynamic> toJson() => {
    'event': event,
    'timestamp': timestamp.toIso8601String(),
    'shotId': shotId,
    'state': state.name,
    'machineState': machineState?.name,
    'machineSubstate': machineSubstate?.name,
    'profileFrame': profileFrame,
    'scaleConnected': scaleConnected,
    'scaleLost': scaleLost,
    'machineHasAutonomousSAW': machineHasAutonomousSAW,
    'decision': decision?.toJson(),
  };
}
