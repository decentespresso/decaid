import 'package:reaprime/src/models/data/utils.dart';

class WorkflowContext {
  final double? targetDoseWeight;
  final double? targetYield;
  final double? targetWaterVolume;

  final String? grinderId;
  final String? grinderModel;
  final String? grinderSetting;

  final String? beanBatchId;
  final String? coffeeName;
  final String? coffeeRoaster;

  final String? finalBeverageType;

  final String? baristaName;
  final String? drinkerName;

  final Map<String, dynamic>? extras;

  const WorkflowContext({
    this.targetDoseWeight,
    this.targetYield,
    this.targetWaterVolume,
    this.grinderId,
    this.grinderModel,
    this.grinderSetting,
    this.beanBatchId,
    this.coffeeName,
    this.coffeeRoaster,
    this.finalBeverageType,
    this.baristaName,
    this.drinkerName,
    this.extras,
  });

  double? get ratio =>
      (targetDoseWeight != null && targetDoseWeight != 0 && targetYield != null)
      ? targetYield! / targetDoseWeight!
      : null;

  factory WorkflowContext.fromJson(Map<String, dynamic> json) {
    return WorkflowContext(
      targetDoseWeight: parseOptionalDouble(json['targetDoseWeight']),
      targetYield: parseOptionalDouble(json['targetYield']),
      targetWaterVolume: parseOptionalDouble(json['targetWaterVolume']),
      grinderId: parseOptionalString(json['grinderId']),
      grinderModel: parseOptionalString(json['grinderModel']),
      grinderSetting: parseOptionalString(json['grinderSetting']),
      beanBatchId: parseOptionalString(json['beanBatchId']),
      coffeeName: parseOptionalString(json['coffeeName']),
      coffeeRoaster: parseOptionalString(json['coffeeRoaster']),
      finalBeverageType: parseOptionalString(json['finalBeverageType']),
      baristaName: parseOptionalString(json['baristaName']),
      drinkerName: parseOptionalString(json['drinkerName']),
      extras: json['extras'] as Map<String, dynamic>?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      if (targetDoseWeight != null) 'targetDoseWeight': targetDoseWeight,
      if (targetYield != null) 'targetYield': targetYield,
      if (targetWaterVolume != null) 'targetWaterVolume': targetWaterVolume,
      if (grinderId != null) 'grinderId': grinderId,
      if (grinderModel != null) 'grinderModel': grinderModel,
      if (grinderSetting != null) 'grinderSetting': grinderSetting,
      if (beanBatchId != null) 'beanBatchId': beanBatchId,
      if (coffeeName != null) 'coffeeName': coffeeName,
      if (coffeeRoaster != null) 'coffeeRoaster': coffeeRoaster,
      if (finalBeverageType != null) 'finalBeverageType': finalBeverageType,
      if (baristaName != null) 'baristaName': baristaName,
      if (drinkerName != null) 'drinkerName': drinkerName,
      if (extras != null) 'extras': extras,
    };
  }

  WorkflowContext clearGrinder() => WorkflowContext(
    targetDoseWeight: targetDoseWeight,
    targetYield: targetYield,
    targetWaterVolume: targetWaterVolume,
    grinderId: null,
    grinderModel: null,
    grinderSetting: grinderSetting,
    beanBatchId: beanBatchId,
    coffeeName: coffeeName,
    coffeeRoaster: coffeeRoaster,
    finalBeverageType: finalBeverageType,
    baristaName: baristaName,
    drinkerName: drinkerName,
    extras: extras,
  );

  WorkflowContext clearBeanBatch() => WorkflowContext(
    targetDoseWeight: targetDoseWeight,
    targetYield: targetYield,
    targetWaterVolume: targetWaterVolume,
    grinderId: grinderId,
    grinderModel: grinderModel,
    grinderSetting: grinderSetting,
    beanBatchId: null,
    coffeeName: null,
    coffeeRoaster: null,
    finalBeverageType: finalBeverageType,
    baristaName: baristaName,
    drinkerName: drinkerName,
    extras: extras,
  );

  WorkflowContext copyWith({
    double? targetDoseWeight,
    double? targetYield,
    double? targetWaterVolume,
    bool clearTargetWaterVolume = false,
    String? grinderId,
    String? grinderModel,
    String? grinderSetting,
    String? beanBatchId,
    String? coffeeName,
    String? coffeeRoaster,
    String? finalBeverageType,
    String? baristaName,
    String? drinkerName,
    Map<String, dynamic>? extras,
  }) {
    return WorkflowContext(
      targetDoseWeight: targetDoseWeight ?? this.targetDoseWeight,
      targetYield: targetYield ?? this.targetYield,
      targetWaterVolume: clearTargetWaterVolume
          ? null
          : targetWaterVolume ?? this.targetWaterVolume,
      grinderId: grinderId ?? this.grinderId,
      grinderModel: grinderModel ?? this.grinderModel,
      grinderSetting: grinderSetting ?? this.grinderSetting,
      beanBatchId: beanBatchId ?? this.beanBatchId,
      coffeeName: coffeeName ?? this.coffeeName,
      coffeeRoaster: coffeeRoaster ?? this.coffeeRoaster,
      finalBeverageType: finalBeverageType ?? this.finalBeverageType,
      baristaName: baristaName ?? this.baristaName,
      drinkerName: drinkerName ?? this.drinkerName,
      extras: extras ?? this.extras,
    );
  }

  @override
  String toString() =>
      'WorkflowContext('
      'dose: $targetDoseWeight→$targetYield, '
      'grinder: $grinderModel/$grinderSetting, '
      'coffee: $coffeeName by $coffeeRoaster)';

  @override
  bool operator ==(Object other) {
    if (other is! WorkflowContext) return false;
    return other.targetDoseWeight == targetDoseWeight &&
        other.targetYield == targetYield &&
        other.targetWaterVolume == targetWaterVolume &&
        other.grinderId == grinderId &&
        other.grinderModel == grinderModel &&
        other.grinderSetting == grinderSetting &&
        other.beanBatchId == beanBatchId &&
        other.coffeeName == coffeeName &&
        other.coffeeRoaster == coffeeRoaster &&
        other.finalBeverageType == finalBeverageType &&
        other.baristaName == baristaName &&
        other.drinkerName == drinkerName &&
        _mapEquals(other.extras, extras);
  }

  @override
  int get hashCode => Object.hash(
    targetDoseWeight,
    targetYield,
    targetWaterVolume,
    grinderId,
    grinderModel,
    grinderSetting,
    beanBatchId,
    coffeeName,
    coffeeRoaster,
    finalBeverageType,
    baristaName,
    drinkerName,
    extras == null
        ? null
        : Object.hashAll(
            extras!.entries.map((e) => Object.hash(e.key, e.value)),
          ),
  );
}

bool _mapEquals(Map<String, dynamic>? a, Map<String, dynamic>? b) {
  if (identical(a, b)) return true;
  if (a == null || b == null) return false;
  if (a.length != b.length) return false;
  for (final key in a.keys) {
    if (!b.containsKey(key) || a[key] != b[key]) return false;
  }
  return true;
}
