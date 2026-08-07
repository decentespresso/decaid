import 'package:reaprime/src/models/data/utils.dart';
import 'package:uuid/uuid.dart';

enum GrinderSettingType {
  numeric,
  preset;

  static GrinderSettingType fromString(String s) {
    if (s == 'values' || s == 'preset') return GrinderSettingType.preset;
    return GrinderSettingType.values.firstWhere(
      (e) => e.name == s,
      orElse: () => GrinderSettingType.numeric,
    );
  }
}

class Grinder {
  final String id;
  final String model;
  final String? burrs;
  final double? burrSize;
  final String? burrType;
  final String? notes;
  final bool archived;

  final GrinderSettingType settingType;
  final List<String>? settingValues;
  final double? settingSmallStep;
  final double? settingBigStep;
  final double? rpmSmallStep;
  final double? rpmBigStep;

  final DateTime createdAt;
  final DateTime updatedAt;
  final Map<String, dynamic>? extras;

  const Grinder({
    required this.id,
    required this.model,
    this.burrs,
    this.burrSize,
    this.burrType,
    this.notes,
    this.archived = false,
    this.settingType = GrinderSettingType.numeric,
    this.settingValues,
    this.settingSmallStep,
    this.settingBigStep,
    this.rpmSmallStep,
    this.rpmBigStep,
    required this.createdAt,
    required this.updatedAt,
    this.extras,
  });

  factory Grinder.create({
    required String model,
    String? burrs,
    double? burrSize,
    String? burrType,
    String? notes,
    GrinderSettingType settingType = GrinderSettingType.numeric,
    List<String>? settingValues,
    double? settingSmallStep,
    double? settingBigStep,
    double? rpmSmallStep,
    double? rpmBigStep,
    Map<String, dynamic>? extras,
  }) {
    final now = DateTime.now();
    return Grinder(
      id: const Uuid().v4(),
      model: model,
      burrs: burrs,
      burrSize: burrSize,
      burrType: burrType,
      notes: notes,
      settingType: settingType,
      settingValues: settingValues,
      settingSmallStep: settingSmallStep,
      settingBigStep: settingBigStep,
      rpmSmallStep: rpmSmallStep,
      rpmBigStep: rpmBigStep,
      createdAt: now,
      updatedAt: now,
      extras: extras,
    );
  }

  factory Grinder.fromJson(Map<String, dynamic> json) {
    return Grinder(
      id: json['id'] as String,
      model: json['model'] as String,
      burrs: json['burrs'] as String?,
      burrSize: parseOptionalDouble(json['burrSize']),
      burrType: json['burrType'] as String?,
      notes: json['notes'] as String?,
      archived: json['archived'] as bool? ?? false,
      settingType: json['settingType'] != null
          ? GrinderSettingType.fromString(json['settingType'] as String)
          : GrinderSettingType.numeric,
      settingValues: (json['settingValues'] as List?)?.cast<String>(),
      settingSmallStep: parseOptionalDouble(json['settingSmallStep']),
      settingBigStep: parseOptionalDouble(json['settingBigStep']),
      rpmSmallStep: parseOptionalDouble(json['rpmSmallStep']),
      rpmBigStep: parseOptionalDouble(json['rpmBigStep']),
      createdAt: DateTime.parse(json['createdAt'] as String),
      updatedAt: DateTime.parse(json['updatedAt'] as String),
      extras: json['extras'] as Map<String, dynamic>?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'model': model,
      if (burrs != null) 'burrs': burrs,
      if (burrSize != null) 'burrSize': burrSize,
      if (burrType != null) 'burrType': burrType,
      if (notes != null) 'notes': notes,
      'archived': archived,
      'settingType': settingType.name,
      if (settingValues != null) 'settingValues': settingValues,
      if (settingSmallStep != null) 'settingSmallStep': settingSmallStep,
      if (settingBigStep != null) 'settingBigStep': settingBigStep,
      if (rpmSmallStep != null) 'rpmSmallStep': rpmSmallStep,
      if (rpmBigStep != null) 'rpmBigStep': rpmBigStep,
      'createdAt': createdAt.toIso8601String(),
      'updatedAt': updatedAt.toIso8601String(),
      if (extras != null) 'extras': extras,
    };
  }

  Grinder copyWith({
    String? model,
    String? burrs,
    double? burrSize,
    String? burrType,
    String? notes,
    bool? archived,
    GrinderSettingType? settingType,
    List<String>? settingValues,
    double? settingSmallStep,
    double? settingBigStep,
    double? rpmSmallStep,
    double? rpmBigStep,
    Map<String, dynamic>? extras,
  }) {
    return Grinder(
      id: id,
      model: model ?? this.model,
      burrs: burrs ?? this.burrs,
      burrSize: burrSize ?? this.burrSize,
      burrType: burrType ?? this.burrType,
      notes: notes ?? this.notes,
      archived: archived ?? this.archived,
      settingType: settingType ?? this.settingType,
      settingValues: settingValues ?? this.settingValues,
      settingSmallStep: settingSmallStep ?? this.settingSmallStep,
      settingBigStep: settingBigStep ?? this.settingBigStep,
      rpmSmallStep: rpmSmallStep ?? this.rpmSmallStep,
      rpmBigStep: rpmBigStep ?? this.rpmBigStep,
      createdAt: createdAt,
      updatedAt: DateTime.now(),
      extras: extras ?? this.extras,
    );
  }

  @override
  String toString() => 'Grinder($model, id: $id)';
}
