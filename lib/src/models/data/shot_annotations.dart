import 'package:reaprime/src/models/data/shot_snapshot.dart';
import 'package:reaprime/src/models/data/utils.dart';

/// Post-shot annotations replacing ShotRecord.shotNotes and ShotRecord.metadata.
/// All fields nullable — populated progressively after a shot.
class ShotAnnotations {
  final double? actualDoseWeight;
  final double? actualYield;

  final double? drinkTds;
  final double? drinkEy;

  // Rating & notes
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

  /// Creates ShotAnnotations from legacy ShotRecord JSON that has
  /// shotNotes and metadata fields.
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

  /// Pre-fills the annotations a freshly-pulled shot can know on its own, the
  /// same way de1app does at shot end:
  ///
  /// - [actualYield] from the scale's final reading (de1app captures
  ///   `final_espresso_weight` into `drink_weight` when flow stops), rounded
  ///   to 0.1 g. Null when no scale was recording — we never write a
  ///   misleading 0 g yield.
  /// - [actualDoseWeight] defaulted to the planned/target dose. The DE1 has no
  ///   dose sensor, so de1app carries the weighed/entered dose onto the shot
  ///   (`grinder_dose_weight`); the barista adjusts it later if they dosed
  ///   differently. Null when no positive target dose was set.
  ///
  /// TDS, EY, enjoyment and notes are intentionally left null — those are
  /// manual post-shot entries in de1app too. Returns null when nothing could
  /// be derived, so callers can persist a shot without an empty annotations
  /// block.
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

  /// The final beverage weight: the last positive scale reading recorded
  /// during the shot, mirroring de1app's `final_espresso_weight`. Recording
  /// stops when the shot finishes, so the tail of [measurements] is the
  /// settled cup weight; scanning from the end for the last positive sample
  /// skips the placement spike at the start and any trailing zero/dropout.
  /// Returns null when no scale samples carry a weight.
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
