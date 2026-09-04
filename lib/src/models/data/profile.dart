import 'package:flutter/widgets.dart';
import 'package:equatable/equatable.dart';
import 'utils.dart';

@immutable
class Profile extends Equatable {
  final String? version;
  final String title;
  final String notes;
  final String author;
  final BeverageType beverageType;
  final List<ProfileStep> steps;
  final double? targetVolume;
  final double? targetWeight;
  final int targetVolumeCountStart;
  final double tankTemperature;

  const Profile({
    required this.version,
    required this.title,
    required this.notes,
    required this.author,
    required this.beverageType,
    required this.steps,
    this.targetVolume,
    this.targetWeight,
    required this.targetVolumeCountStart,
    required this.tankTemperature,
  });

  @override
  List<Object?> get props => [
    version,
    title,
    notes,
    author,
    beverageType,
    steps,
    targetVolume,
    targetWeight,
    targetVolumeCountStart,
    tankTemperature,
  ];

  static const unknownTitle = 'Unknown profile';

  factory Profile.fromJson(Map<String, dynamic> json) =>
      Profile._parse(json, requireExecutable: true);

  factory Profile.fromRecordedJson(Map<String, dynamic> json) =>
      Profile._parse(json, requireExecutable: false);

  static Profile _parse(
    Map<String, dynamic> json, {
    required bool requireExecutable,
  }) {
    final title = parseOptionalString(json['title']);
    final rawSteps = json['steps'];
    if (requireExecutable) {
      if (title == null || title.isEmpty) {
        throw ArgumentError('Profile must have a non-empty "title"');
      }
      if (rawSteps is! List || rawSteps.isEmpty) {
        throw ArgumentError('Profile must have a non-empty "steps" array');
      }
      if (json['tank_temperature'] == null) {
        throw ArgumentError('Profile must have "tank_temperature"');
      }
      if (json['target_volume_count_start'] == null) {
        throw ArgumentError('Profile must have "target_volume_count_start"');
      }
    }
    return Profile(
      version: parseOptionalString(json['version']),
      title: title == null || title.isEmpty ? unknownTitle : title,
      notes: parseOptionalString(json['notes']) ?? '',
      author: parseOptionalString(json['author']) ?? '',
      beverageType: _parseBeverageType(json['beverage_type']),
      steps: rawSteps is List
          ? rawSteps
                .map(
                  (step) => ProfileStep.fromJson(step as Map<String, dynamic>),
                )
                .toList()
          : const [],
      targetVolume: parseOptionalDouble(json['target_volume']),
      targetWeight: parseOptionalDouble(json['target_weight']),
      targetVolumeCountStart: parseInt(json['target_volume_count_start'] ?? 0),
      tankTemperature: parseDouble(json['tank_temperature'] ?? 0),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'version': version,
      'title': title,
      'notes': notes,
      'author': author,
      'beverage_type': beverageType.name,
      'steps': steps.map((step) => step.toJson()).toList(),
      'target_volume': targetVolume,
      'target_weight': targetWeight,
      'target_volume_count_start': targetVolumeCountStart,
      'tank_temperature': tankTemperature,
    };
  }

  Profile copyWith({
    String? version,
    String? title,
    String? notes,
    String? author,
    BeverageType? beverageType,
    List<ProfileStep>? steps,
    double? targetVolume,
    double? targetWeight,
    int? targetVolumeCountStart,
    double? tankTemperature,
  }) {
    return Profile(
      version: version ?? this.version,
      title: title ?? this.title,
      notes: notes ?? this.notes,
      author: author ?? this.author,
      beverageType: beverageType ?? this.beverageType,
      steps: steps ?? this.steps,
      targetVolume: targetVolume ?? this.targetVolume,
      targetWeight: targetWeight ?? this.targetWeight,
      targetVolumeCountStart:
          targetVolumeCountStart ?? this.targetVolumeCountStart,
      tankTemperature: tankTemperature ?? this.tankTemperature,
    );
  }

  Profile adjustTemperature(double offset) {
    return copyWith(
      steps: steps
          .map((step) => step.copyWith(temperature: step.temperature + offset))
          .toList(),
    );
  }
}

enum BeverageType { espresso, calibrate, cleaning, manual, pourover }

BeverageType _parseBeverageType(dynamic value) {
  if (value == null || value.toString().isEmpty) return BeverageType.espresso;
  final name = value.toString().toLowerCase();
  for (final type in BeverageType.values) {
    if (type.name == name) return type;
  }
  return BeverageType.espresso;
}

enum TransitionType { fast, smooth }

enum TemperatureSensor { coffee, water }

enum ExitType { pressure, flow }

enum ExitCondition { over, under }

class StepLimiter extends Equatable {
  final double value;
  final double range;

  const StepLimiter({required this.value, required this.range});

  factory StepLimiter.fromJson(Map<String, dynamic> json) {
    return StepLimiter(
      value: parseDouble(json["value"]),
      range: parseDouble(json["range"]),
    );
  }

  Map<String, dynamic> toJson() {
    return {'value': value, 'range': range};
  }

  @override
  List<Object?> get props => [value, range];
}

abstract class ProfileStep extends Equatable {
  final String name;
  final TransitionType transition;
  final StepExitCondition? exit;
  final double volume;
  final double seconds;
  final double? weight;
  final double temperature;
  final TemperatureSensor sensor;
  final StepLimiter? limiter;

  const ProfileStep({
    required this.name,
    required this.transition,
    this.exit,
    required this.volume,
    required this.seconds,
    this.weight,
    required this.temperature,
    required this.sensor,
    this.limiter,
  });

  double getTarget();

  factory ProfileStep.fromJson(Map<String, dynamic> json) {
    if (json.containsKey('pump') && json['pump'] == 'pressure') {
      return ProfileStepPressure.fromJson(json);
    } else if (json.containsKey('pump') && json['pump'] == 'flow') {
      return ProfileStepFlow.fromJson(json);
    } else {
      throw Exception(
        'Invalid step type. Must include either "pressure" or "flow".',
      );
    }
  }

  Map<String, dynamic> toJson();

  ProfileStep copyWith({double? temperature});
}

class ProfileStepPressure extends ProfileStep {
  final double pressure;

  const ProfileStepPressure({
    required super.name,
    required super.transition,
    super.exit,
    required super.volume,
    required super.seconds,
    super.weight,
    required super.temperature,
    required super.sensor,
    super.limiter,
    required this.pressure,
  });

  @override
  double getTarget() => pressure;

  factory ProfileStepPressure.fromJson(Map<String, dynamic> json) {
    return ProfileStepPressure(
      name: json['name'],
      transition: TransitionType.values.byName(json['transition']),
      exit: json['exit'] != null
          ? StepExitCondition.fromJson(json['exit'])
          : null,
      volume: parseDouble(json['volume']),
      seconds: parseDouble(json['seconds']),
      weight: parseOptionalDouble(json['weight']),
      temperature: parseDouble(json['temperature']),
      sensor: TemperatureSensor.values.byName(json['sensor']),
      limiter: json['limiter'] != null
          ? StepLimiter.fromJson(json['limiter'])
          : null,
      pressure: parseDouble(json['pressure']),
    );
  }

  @override
  Map<String, dynamic> toJson() {
    final data = {
      'name': name,
      'pump': 'pressure',
      'transition': transition.name,
      'exit': exit?.toJson(),
      'volume': volume,
      'seconds': seconds,
      'weight': weight,
      'temperature': temperature,
      'sensor': sensor.name,
      'pressure': pressure,
      'limiter': limiter?.toJson(),
    };
    return data;
  }

  @override
  ProfileStep copyWith({double? temperature}) {
    return ProfileStepPressure(
      name: name,
      transition: transition,
      exit: exit,
      volume: volume,
      seconds: seconds,
      weight: weight,
      temperature: temperature ?? this.temperature,
      sensor: sensor,
      pressure: pressure,
      limiter: limiter,
    );
  }

  @override
  List<Object?> get props => [
    name,
    transition,
    exit,
    volume,
    seconds,
    weight,
    temperature,
    sensor,
    pressure,
    limiter,
  ];
}

class ProfileStepFlow extends ProfileStep {
  final double flow;

  const ProfileStepFlow({
    required super.name,
    required super.transition,
    super.exit,
    required super.volume,
    required super.seconds,
    super.weight,
    required super.temperature,
    required super.sensor,
    super.limiter,
    required this.flow,
  });

  @override
  double getTarget() => flow;

  factory ProfileStepFlow.fromJson(Map<String, dynamic> json) {
    return ProfileStepFlow(
      name: json['name'],
      transition: TransitionType.values.byName(json['transition']),
      exit: json['exit'] != null
          ? StepExitCondition.fromJson(json['exit'])
          : null,
      volume: parseDouble(json['volume']),
      seconds: parseDouble(json['seconds']),
      weight: parseOptionalDouble(json['weight']),
      temperature: parseDouble(json['temperature']),
      sensor: TemperatureSensor.values.byName(json['sensor']),
      limiter: json['limiter'] != null
          ? StepLimiter.fromJson(json['limiter'])
          : null,
      flow: parseDouble(json['flow']),
    );
  }

  @override
  Map<String, dynamic> toJson() {
    final data = {
      'name': name,
      'pump': 'flow',
      'transition': transition.name,
      'exit': exit?.toJson(),
      'volume': volume,
      'seconds': seconds,
      'weight': weight,
      'temperature': temperature,
      'sensor': sensor.name,
      'flow': flow,
      'limiter': limiter?.toJson(),
    };
    return data;
  }

  @override
  ProfileStep copyWith({double? temperature}) {
    return ProfileStepFlow(
      name: name,
      transition: transition,
      exit: exit,
      volume: volume,
      seconds: seconds,
      weight: weight,
      temperature: temperature ?? this.temperature,
      sensor: sensor,
      flow: flow,
      limiter: limiter,
    );
  }

  @override
  List<Object?> get props => [
    name,
    transition,
    exit,
    volume,
    seconds,
    weight,
    temperature,
    sensor,
    flow,
    limiter,
  ];
}

class StepExitCondition extends Equatable {
  final ExitType type;
  final ExitCondition condition;
  final double value;

  const StepExitCondition({
    required this.type,
    required this.condition,
    required this.value,
  });

  factory StepExitCondition.fromJson(Map<String, dynamic> json) {
    return StepExitCondition(
      type: ExitType.values.byName(json['type']),
      condition: ExitCondition.values.byName(json['condition']),
      value: parseDouble(json['value']),
    );
  }

  Map<String, dynamic> toJson() {
    return {'type': type.name, 'condition': condition.name, 'value': value};
  }

  @override
  List<Object?> get props => [type, condition, value];
}
