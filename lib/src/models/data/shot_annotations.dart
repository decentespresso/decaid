import 'package:reaprime/src/models/data/shot_snapshot.dart';
import 'package:reaprime/src/models/data/utils.dart';

class ShotAnnotations {
  final double? actualDoseWeight;
  final double? actualYield;

  final double? drinkTds;
  final double? drinkEy;

  final double? enjoyment;
  final String? espressoNotes;

  final Map<String, dynamic>? extras;

  const ShotAnnotations({
    this.actualDoseWeight,
    this.actualYield,
    this.drinkTds,
    this.drinkEy,
    this.enjoyment,
    this.espressoNotes,
    this.extras,
  });

  factory ShotAnnotations.fromJson(Map<String, dynamic> json) {
    return ShotAnnotations(
      actualDoseWeight: parseOptionalDouble(json['actualDoseWeight']),
      actualYield: parseOptionalDouble(json['actualYield']),
      drinkTds: parseOptionalDouble(json['drinkTds']),
      drinkEy: parseOptionalDouble(json['drinkEy']),
      enjoyment: parseOptionalDouble(json['enjoyment']),
      espressoNotes: json['espressoNotes'] as String?,
      extras: json['extras'] as Map<String, dynamic>?,
    );
  }

  factory ShotAnnotations.fromLegacyJson(Map<String, dynamic> shotJson) {
    return ShotAnnotations(
      espressoNotes: shotJson['shotNotes'] as String?,
      extras: shotJson['metadata'] as Map<String, dynamic>?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      if (actualDoseWeight != null) 'actualDoseWeight': actualDoseWeight,
      if (actualYield != null) 'actualYield': actualYield,
      if (drinkTds != null) 'drinkTds': drinkTds,
      if (drinkEy != null) 'drinkEy': drinkEy,
      if (enjoyment != null) 'enjoyment': enjoyment,
      if (espressoNotes != null) 'espressoNotes': espressoNotes,
      if (extras != null) 'extras': extras,
    };
  }

  ShotAnnotations copyWith({
    double? actualDoseWeight,
    double? actualYield,
    double? drinkTds,
    double? drinkEy,
    double? enjoyment,
    String? espressoNotes,
    Map<String, dynamic>? extras,
  }) {
    return ShotAnnotations(
      actualDoseWeight: actualDoseWeight ?? this.actualDoseWeight,
      actualYield: actualYield ?? this.actualYield,
      drinkTds: drinkTds ?? this.drinkTds,
      drinkEy: drinkEy ?? this.drinkEy,
      enjoyment: enjoyment ?? this.enjoyment,
      espressoNotes: espressoNotes ?? this.espressoNotes,
      extras: extras ?? this.extras,
    );
  }

  @override
  String toString() =>
      'ShotAnnotations('
      'dose: $actualDoseWeight→$actualYield, '
      'tds: $drinkTds, ey: $drinkEy, '
      'enjoyment: $enjoyment)';

  static ShotAnnotations? deriveForFinishedShot({
    required List<ShotSnapshot> measurements,
    double? targetDoseWeight,
    double? preferredYield,
  }) {
    final yield_ = (preferredYield != null && preferredYield > 0)
        ? (preferredYield * 10).roundToDouble() / 10
        : finalScaleWeight(measurements);
    final dose = (targetDoseWeight != null && targetDoseWeight > 0)
        ? targetDoseWeight
        : null;
    if (yield_ == null && dose == null) return null;
    return ShotAnnotations(actualDoseWeight: dose, actualYield: yield_);
  }

  static double? finalScaleWeight(List<ShotSnapshot> measurements) {
    for (final snapshot in measurements.reversed) {
      final weight = snapshot.scale?.weight;
      if (weight != null && weight > 0) {
        return (weight * 10).roundToDouble() / 10;
      }
    }
    return null;
  }
}
