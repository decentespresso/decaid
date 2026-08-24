import 'package:reaprime/src/models/data/profile.dart';
import 'package:reaprime/src/models/data/utils.dart';
import 'package:reaprime/src/models/data/workflow_context.dart';
import 'package:uuid/uuid.dart';

class Workflow {
  final String id;
  final String name;
  final String description;
  final Profile profile;
  final WorkflowContext? context;
  final SteamSettings steamSettings;
  final HotWaterData hotWaterData;
  final RinseData rinseData;

  final WorkflowMachine? machine;

  Workflow({
    required this.id,
    required this.name,
    this.description = '',
    required this.profile,
    this.context,
    required this.steamSettings,
    required this.hotWaterData,
    required this.rinseData,
    this.machine,
  });

  factory Workflow.fromJson(Map<String, dynamic> json) {
    WorkflowContext? ctx;
    if (json['context'] != null) {
      ctx = WorkflowContext.fromJson(json['context'] as Map<String, dynamic>);
    }

    final dose = json['doseData'] as Map<String, dynamic>?;
    final grinder = json['grinderData'] as Map<String, dynamic>?;
    final coffee = json['coffeeData'] as Map<String, dynamic>?;

    if (ctx != null && (grinder != null || coffee != null || dose != null)) {
      ctx = ctx.copyWith(
        targetDoseWeight:
            ctx.targetDoseWeight ?? parseOptionalDouble(dose?['doseIn']),
        targetYield: ctx.targetYield ?? parseOptionalDouble(dose?['doseOut']),
        grinderSetting: ctx.grinderSetting ?? grinder?['setting'] as String?,
        grinderModel: ctx.grinderModel ?? grinder?['model'] as String?,
        coffeeName: ctx.coffeeName ?? coffee?['name'] as String?,
        coffeeRoaster: ctx.coffeeRoaster ?? coffee?['roaster'] as String?,
      );
    } else if (ctx == null &&
        (dose != null || grinder != null || coffee != null)) {
      ctx = WorkflowContext(
        targetDoseWeight: dose != null
            ? parseOptionalDouble(dose['doseIn'])
            : null,
        targetYield: dose != null ? parseOptionalDouble(dose['doseOut']) : null,
        grinderSetting: grinder?['setting'] as String?,
        grinderModel: grinder?['model'] as String?,
        coffeeName: coffee?['name'] as String?,
        coffeeRoaster: coffee?['roaster'] as String?,
      );
    }

    return Workflow(
      id: json['id'],
      name: json['name'],
      description: json['description'],
      profile: Profile.fromJson(json['profile']),
      context: ctx,
      steamSettings: json['steamSettings'] != null
          ? SteamSettings.fromJson(json['steamSettings'])
          : SteamSettings.defaults(),
      hotWaterData: json['hotWaterData'] != null
          ? HotWaterData.fromJson(json['hotWaterData'])
          : HotWaterData.defaults(),
      rinseData: json['rinseData'] != null
          ? RinseData.fromJson(json['rinseData'])
          : RinseData.defaults(),
      machine: json['machine'] != null
          ? WorkflowMachine.fromJson(json['machine'] as Map<String, dynamic>)
          : null,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'description': description,
      'profile': profile.toJson(),
      if (context != null) 'context': context!.toJson(),
      'steamSettings': steamSettings.toJson(),
      'hotWaterData': hotWaterData.toJson(),
      'rinseData': rinseData.toJson(),
      if (machine != null) 'machine': machine!.toJson(),
    };
  }

  Workflow copyWith({
    String? id,
    String? name,
    String? description,
    Profile? profile,
    WorkflowContext? context,
    SteamSettings? steamSettings,
    HotWaterData? hotWaterData,
    RinseData? rinseData,
    WorkflowMachine? machine,
    bool clearMachine = false,
  }) {
    return Workflow(
      id: id ?? Uuid().v4(),
      name: name ?? this.name,
      description: description ?? this.description,
      profile: profile ?? this.profile,
      context: context ?? this.context,
      steamSettings: steamSettings ?? this.steamSettings,
      hotWaterData: hotWaterData ?? this.hotWaterData,
      rinseData: rinseData ?? this.rinseData,
      machine: clearMachine ? null : machine ?? this.machine,
    );
  }
}

enum WorkflowMachineProvenanceStatus {
  captured,
  unavailable,
  unknown;

  static WorkflowMachineProvenanceStatus? fromJson(Object? value) =>
      switch (value) {
        null => null,
        'captured' => captured,
        'unavailable' => unavailable,
        _ => unknown,
      };
}

class WorkflowMachine {
  final WorkflowMachineProvenanceStatus? provenanceStatus;
  final double? flowCalibration;
  final String? serialNumber;
  final String? model;
  final String? firmwareVersion;

  const WorkflowMachine({
    this.provenanceStatus,
    this.flowCalibration,
    this.serialNumber,
    this.model,
    this.firmwareVersion,
  });

  WorkflowMachine copyWith({
    WorkflowMachineProvenanceStatus? provenanceStatus,
    double? flowCalibration,
    String? serialNumber,
    String? model,
    String? firmwareVersion,
  }) => WorkflowMachine(
    provenanceStatus: provenanceStatus ?? this.provenanceStatus,
    flowCalibration: flowCalibration ?? this.flowCalibration,
    serialNumber: serialNumber ?? this.serialNumber,
    model: model ?? this.model,
    firmwareVersion: firmwareVersion ?? this.firmwareVersion,
  );

  Map<String, dynamic> toJson() => {
    if (provenanceStatus != null) 'provenanceStatus': provenanceStatus!.name,
    if (flowCalibration != null) 'flowCalibration': flowCalibration,
    if (serialNumber != null) 'serialNumber': serialNumber,
    if (model != null) 'model': model,
    if (firmwareVersion != null) 'firmwareVersion': firmwareVersion,
  };

  factory WorkflowMachine.fromJson(Map<String, dynamic> json) =>
      WorkflowMachine(
        provenanceStatus: WorkflowMachineProvenanceStatus.fromJson(
          json['provenanceStatus'],
        ),
        flowCalibration: parseOptionalDouble(json['flowCalibration']),
        serialNumber: parseOptionalString(json['serialNumber']),
        model: parseOptionalString(json['model']),
        firmwareVersion: parseOptionalString(json['firmwareVersion']),
      );

  @override
  bool operator ==(Object other) =>
      other is WorkflowMachine &&
      other.provenanceStatus == provenanceStatus &&
      other.flowCalibration == flowCalibration &&
      other.serialNumber == serialNumber &&
      other.model == model &&
      other.firmwareVersion == firmwareVersion;

  @override
  int get hashCode => Object.hash(
    provenanceStatus,
    flowCalibration,
    serialNumber,
    model,
    firmwareVersion,
  );
}

class SteamSettings {
  int targetTemperature;
  int duration;
  double flow;
  double stopAtTemperature;

  SteamSettings({
    required this.targetTemperature,
    required this.duration,
    required this.flow,
    this.stopAtTemperature = 0.0,
  });

  SteamSettings copyWith({
    int? targetTemperature,
    int? duration,
    double? flow,
    double? stopAtTemperature,
  }) {
    return SteamSettings(
      targetTemperature: targetTemperature ?? this.targetTemperature,
      duration: duration ?? this.duration,
      flow: flow ?? this.flow,
      stopAtTemperature: stopAtTemperature ?? this.stopAtTemperature,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'targetTemperature': targetTemperature,
      'duration': duration,
      'flow': flow,
      'stopAtTemperature': stopAtTemperature,
    };
  }

  factory SteamSettings.fromJson(Map<String, dynamic> json) {
    return SteamSettings(
      targetTemperature: parseInt(json['targetTemperature']),
      duration: parseInt(json['duration']),
      flow: parseDouble(json['flow']),
      stopAtTemperature: json.containsKey('stopAtTemperature')
          ? parseDouble(json['stopAtTemperature'])
          : 0.0,
    );
  }

  factory SteamSettings.defaults() {
    return SteamSettings(
      targetTemperature: 150,
      duration: 50,
      flow: 0.8,
      stopAtTemperature: 0.0,
    );
  }

  @override
  bool operator ==(Object other) {
    if (other is! SteamSettings) {
      return false;
    }

    return other.targetTemperature == targetTemperature &&
        other.flow == flow &&
        other.duration == duration &&
        other.stopAtTemperature == stopAtTemperature;
  }

  @override
  int get hashCode =>
      targetTemperature.hashCode ^
      flow.hashCode ^
      duration.hashCode ^
      stopAtTemperature.hashCode;
}

class HotWaterData {
  int targetTemperature;
  int duration;
  int volume;
  double flow;

  HotWaterData({
    required this.targetTemperature,
    required this.duration,
    required this.volume,
    required this.flow,
  });

  HotWaterData copyWith({
    int? targetTemperature,
    int? duration,
    int? volume,
    double? flow,
  }) {
    return HotWaterData(
      targetTemperature: targetTemperature ?? this.targetTemperature,
      duration: duration ?? this.duration,
      volume: volume ?? this.volume,
      flow: flow ?? this.flow,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'targetTemperature': targetTemperature,
      'duration': duration,
      'volume': volume,
      'flow': flow,
    };
  }

  factory HotWaterData.fromJson(Map<String, dynamic> json) {
    return HotWaterData(
      targetTemperature: parseInt(json['targetTemperature']),
      duration: parseInt(json['duration']),
      volume: parseInt(json['volume']),
      flow: parseDouble(json['flow']),
    );
  }

  factory HotWaterData.defaults() {
    return HotWaterData(
      targetTemperature: 75,
      duration: 30,
      volume: 50,
      flow: 10,
    );
  }

  @override
  bool operator ==(Object other) {
    if (other is! HotWaterData) {
      return false;
    }

    return other.targetTemperature == targetTemperature &&
        other.flow == flow &&
        other.duration == duration &&
        other.volume == volume;
  }

  @override
  int get hashCode =>
      targetTemperature.hashCode ^
      flow.hashCode ^
      duration.hashCode ^
      volume.hashCode;
}

class RinseData {
  int targetTemperature;
  int duration;
  double flow;

  RinseData({
    required this.targetTemperature,
    required this.duration,
    required this.flow,
  });

  Map<String, dynamic> toJson() {
    return {
      'targetTemperature': targetTemperature,
      'duration': duration,
      'flow': flow,
    };
  }

  factory RinseData.fromJson(Map<String, dynamic> json) {
    return RinseData(
      targetTemperature: parseInt(json['targetTemperature']),
      duration: parseInt(json['duration']),
      flow: parseDouble(json['flow']),
    );
  }

  factory RinseData.defaults() {
    return RinseData(targetTemperature: 90, duration: 10, flow: 6.0);
  }

  @override
  bool operator ==(Object other) {
    if (other is! RinseData) {
      return false;
    }

    return other.targetTemperature == targetTemperature &&
        other.flow == flow &&
        other.duration == duration;
  }

  @override
  int get hashCode =>
      targetTemperature.hashCode ^ flow.hashCode ^ duration.hashCode;
}
