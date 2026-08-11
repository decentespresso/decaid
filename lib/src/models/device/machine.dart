import 'package:reaprime/src/models/device/device.dart';

abstract class Machine extends Device {
  Stream<MachineSnapshot> get currentSnapshot;

  MachineInfo get machineInfo;

  Future<void> requestState(MachineState newState);
}

class MachineInfo {
  final String version;
  final String model;
  final String serialNumber;
  final bool groupHeadControllerPresent;
  final Map<String, dynamic> extra;

  MachineInfo({
    required this.version,
    required this.model,
    required this.serialNumber,
    required this.groupHeadControllerPresent,
    required this.extra,
  });

  Map<String, dynamic> toJson() {
    return {
      'version': version,
      'model': model,
      'serialNumber': serialNumber,
      'GHC': groupHeadControllerPresent,
      'extra': extra,
    };
  }
}

class MachineSnapshot {
  final DateTime timestamp;
  final MachineStateSnapshot state;
  final double flow;
  final double pressure;
  final double targetFlow;
  final double targetPressure;
  final double mixTemperature;
  final double groupTemperature;
  final double targetMixTemperature;
  final double targetGroupTemperature;
  final int profileFrame;
  final int steamTemperature;
  final double? weight;
  final double? weightFlow;
  final double? milkTemperature;

  MachineSnapshot({
    required this.timestamp,
    required this.state,
    required this.flow,
    required this.pressure,
    required this.targetFlow,
    required this.targetPressure,
    required this.mixTemperature,
    required this.groupTemperature,
    required this.targetMixTemperature,
    required this.targetGroupTemperature,
    required this.profileFrame,
    required this.steamTemperature,
    this.weight,
    this.weightFlow,
    this.milkTemperature,
  });

  MachineSnapshot copyWith({
    DateTime? timestamp,
    MachineStateSnapshot? state,
    double? flow,
    double? pressure,
    double? targetFlow,
    double? targetPressure,
    double? mixTemperature,
    double? groupTemperature,
    double? targetMixTemperature,
    double? targetGroupTemperature,
    int? profileFrame,
    int? steamTemperature,
    double? weight,
    double? weightFlow,
    double? milkTemperature,
  }) {
    return MachineSnapshot(
      timestamp: timestamp ?? this.timestamp,
      state: state ?? this.state,
      flow: flow ?? this.flow,
      pressure: pressure ?? this.pressure,
      targetFlow: targetFlow ?? this.targetFlow,
      targetPressure: targetPressure ?? this.targetPressure,
      mixTemperature: mixTemperature ?? this.mixTemperature,
      groupTemperature: groupTemperature ?? this.groupTemperature,
      targetMixTemperature: targetMixTemperature ?? this.targetMixTemperature,
      targetGroupTemperature:
          targetGroupTemperature ?? this.targetGroupTemperature,
      profileFrame: profileFrame ?? this.profileFrame,
      steamTemperature: steamTemperature ?? this.steamTemperature,
      weight: weight ?? this.weight,
      weightFlow: weightFlow ?? this.weightFlow,
      milkTemperature: milkTemperature ?? this.milkTemperature,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'timestamp': timestamp.toIso8601String(),
      'state': {'state': state.state.name, 'substate': state.substate.name},
      'flow': flow,
      'pressure': pressure,
      'targetFlow': targetFlow,
      'targetPressure': targetPressure,
      'mixTemperature': mixTemperature,
      'groupTemperature': groupTemperature,
      'targetMixTemperature': targetMixTemperature,
      'targetGroupTemperature': targetGroupTemperature,
      'profileFrame': profileFrame,
      'steamTemperature': steamTemperature,
      'weight': weight,
      'weightFlow': weightFlow,
      'milkTemperature': milkTemperature,
    };
  }

  factory MachineSnapshot.fromJson(Map<String, dynamic> json) {
    return MachineSnapshot(
      timestamp: DateTime.parse(json["timestamp"]),
      state: MachineStateSnapshot(
        state: MachineState.values.firstWhere(
          (e) => e.name == json["state"]["state"],
        ),
        substate: MachineSubstate.values.firstWhere(
          (e) => e.name == json["state"]["substate"],
        ),
      ),
      flow: json["flow"],
      pressure: json["pressure"],
      targetFlow: json["targetFlow"],
      targetPressure: json["targetPressure"],
      mixTemperature: json["mixTemperature"],
      groupTemperature: json["groupTemperature"],
      targetMixTemperature: json["targetMixTemperature"],
      targetGroupTemperature: json["targetGroupTemperature"],
      profileFrame: json["profileFrame"],
      steamTemperature: json["steamTemperature"],
      weight: (json["weight"] as num?)?.toDouble(),
      weightFlow: (json["weightFlow"] as num?)?.toDouble(),
      milkTemperature: (json["milkTemperature"] as num?)?.toDouble(),
    );
  }
}

enum MachineState {
  booting,
  busy,
  idle,
  schedIdle,
  sleeping,
  heating,
  preheating,
  espresso,
  hotWater,
  flush,
  steam,
  steamRinse,
  skipStep,
  cleaning,
  descaling,
  calibration,
  selfTest,
  airPurge,
  needsWater,
  error,
  fwUpgrade,
}

enum MachineSubstate {
  idle,
  preparingForShot,
  preinfusion,
  pouring,
  pouringDone,
  cleaningStart,
  cleaningGroup,
  cleanSoaking,
  cleaningSteam,

  errorNaN,
  errorInf,
  errorGeneric,
  errorAcc,
  errorTSensor,
  errorPSensor,
  errorWLevel,
  errorDip,
  errorAssertion,
  errorUnsafe,
  errorInvalidParam,
  errorFlash,
  errorOOM,
  errorDeadline,
  errorHiCurrent,
  errorLoCurrent,
  errorBootFill,
  errorNoAC,
}

class MachineStateSnapshot {
  const MachineStateSnapshot({required this.state, required this.substate});
  final MachineState state;
  final MachineSubstate substate;
}
