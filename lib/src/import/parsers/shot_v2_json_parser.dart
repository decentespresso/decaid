import 'dart:math';

import 'package:reaprime/src/controllers/scale_controller.dart';
import 'package:reaprime/src/models/data/profile.dart';
import 'package:reaprime/src/models/data/shot_annotations.dart';
import 'package:reaprime/src/models/data/shot_record.dart';
import 'package:reaprime/src/models/data/shot_snapshot.dart';
import 'package:reaprime/src/models/data/workflow.dart';
import 'package:reaprime/src/models/data/workflow_context.dart';
import 'package:reaprime/src/models/device/machine.dart';
import 'package:reaprime/src/models/data/utils.dart' as parse_utils;
import 'package:uuid/uuid.dart';

/// Holds a parsed [ShotRecord] plus extracted metadata strings for entity
/// extraction in later import stages.
class ParsedShot {
  final ShotRecord shot;
  final String? beanBrand;
  final String? beanType;
  final String? beanNotes;
  final String? roastDate;
  final String? roastLevel;
  final String? grinderModel;
  final String? grinderSetting;

  const ParsedShot({
    required this.shot,
    this.beanBrand,
    this.beanType,
    this.beanNotes,
    this.roastDate,
    this.roastLevel,
    this.grinderModel,
    this.grinderSetting,
  });
}

/// Parses de1app history_v2 JSON files into [ParsedShot] instances.
class ShotV2JsonParser {
  ShotV2JsonParser._();

  /// Parses a de1app history_v2 JSON map into a [ParsedShot].
  static ParsedShot parse(Map<String, dynamic> json) {
    final clockValue = json['clock'];
    if (clockValue == null) {
      throw const FormatException('Missing clock field');
    }
    final clock = parse_utils.parseInt(clockValue);
    final baseTimestamp = DateTime.fromMillisecondsSinceEpoch(
      clock * 1000,
      isUtc: true,
    );

    final settings = _extractSettings(json);

    final meta = json['meta'] as Map<String, dynamic>?;
    final metaBean = meta?['bean'] as Map<String, dynamic>?;
    final metaShot = meta?['shot'] as Map<String, dynamic>?;
    final metaGrinder = meta?['grinder'] as Map<String, dynamic>?;

    final beanBrand = _str(metaBean?['brand']) ?? _str(settings['bean_brand']);
    final beanType = _str(metaBean?['type']) ?? _str(settings['bean_type']);
    final beanNotes = _str(metaBean?['notes']) ?? _str(settings['bean_notes']);
    final roastLevel =
        _str(metaBean?['roast_level']) ?? _str(settings['roast_level']);
    final roastDate =
        _str(metaBean?['roast_date']) ?? _str(settings['roast_date']);

    final grinderModel =
        _str(metaGrinder?['model']) ?? _str(settings['grinder_model']);
    final grinderSetting =
        _str(metaGrinder?['setting']) ?? _str(settings['grinder_setting']);

    final Profile profile;
    if (json['profile'] != null) {
      profile = Profile.fromJson(json['profile'] as Map<String, dynamic>);
    } else {
      profile = Profile(
        version: '2',
        title: _str(settings['profile_title']) ?? 'Unknown',
        notes: '',
        author: '',
        beverageType: BeverageType.espresso,
        steps: [],
        targetWeight: parse_utils.parseOptionalDouble(
          settings['final_desired_shot_weight'],
        ),
        targetVolumeCountStart: 0,
        tankTemperature: 0,
      );
    }

    final doseWeight =
        parse_utils.parseOptionalDouble(meta?['in']) ??
        parse_utils.parseOptionalDouble(settings['grinder_dose_weight']);
    final actualYield =
        parse_utils.parseOptionalDouble(meta?['out']) ??
        parse_utils.parseOptionalDouble(settings['drink_weight']);
    final targetYield =
        parse_utils.parseOptionalDouble(settings['target_drink_weight']) ??
        profile.targetWeight ??
        actualYield;
    final tds =
        parse_utils.parseOptionalDouble(metaShot?['tds']) ??
        parse_utils.parseOptionalDouble(settings['drink_tds']);
    final ey =
        parse_utils.parseOptionalDouble(metaShot?['ey']) ??
        parse_utils.parseOptionalDouble(settings['drink_ey']);
    final enjoyment =
        parse_utils.parseOptionalDouble(metaShot?['enjoyment']) ??
        parse_utils.parseOptionalDouble(settings['espresso_enjoyment']);
    final espressoNotes =
        _str(metaShot?['notes']) ?? _str(settings['espresso_notes']);

    final annotations = ShotAnnotations(
      actualDoseWeight: doseWeight,
      actualYield: actualYield,
      drinkTds: tds,
      drinkEy: ey,
      enjoyment: enjoyment,
      espressoNotes: espressoNotes,
    );

    final context = WorkflowContext(
      targetDoseWeight: doseWeight,
      targetYield: targetYield,
      grinderModel: grinderModel,
      grinderSetting: grinderSetting,
      coffeeName: beanType,
      coffeeRoaster: beanBrand,
      baristaName: _str(settings['my_name']),
      drinkerName: _str(settings['drinker_name']),
    );

    final workflow = Workflow(
      id: const Uuid().v4(),
      name: profile.title,
      profile: profile,
      context: context,
      steamSettings: SteamSettings.defaults(),
      hotWaterData: HotWaterData.defaults(),
      rinseData: RinseData.defaults(),
    );

    final measurements = _parseSnapshots(json, baseTimestamp, profile);

    final shot = ShotRecord(
      id: 'de1app-$clock',
      timestamp: baseTimestamp,
      measurements: measurements,
      workflow: workflow,
      annotations: annotations,
    );

    return ParsedShot(
      shot: shot,
      beanBrand: beanBrand,
      beanType: beanType,
      beanNotes: beanNotes,
      roastDate: roastDate,
      roastLevel: roastLevel,
      grinderModel: grinderModel,
      grinderSetting: grinderSetting,
    );
  }

  static Map<String, dynamic> _extractSettings(Map<String, dynamic> json) {
    final app = json['app'] as Map<String, dynamic>?;
    final data = app?['data'] as Map<String, dynamic>?;
    return (data?['settings'] as Map<String, dynamic>?) ?? {};
  }

  /// Pre-computes cumulative step end-times from profile step durations.
  /// Used to reconstruct frame numbers for history snapshots.
  static List<double> _stepBoundaries(Profile profile) {
    final boundaries = <double>[];
    var cumulative = 0.0;
    for (final step in profile.steps) {
      cumulative += step.seconds;
      boundaries.add(cumulative);
    }
    return boundaries;
  }

  /// Returns the profile step index for [elapsedSeconds] given step [boundaries].
  static int _frameForElapsed(double elapsedSeconds, List<double> boundaries) {
    for (var i = 0; i < boundaries.length; i++) {
      if (elapsedSeconds < boundaries[i]) return i;
    }
    return boundaries.isEmpty ? 0 : boundaries.length - 1;
  }

  static List<ShotSnapshot> _parseSnapshots(
    Map<String, dynamic> json,
    DateTime baseTimestamp,
    Profile profile,
  ) {
    final elapsed = _numList(json['elapsed']);
    if (elapsed.isEmpty) return [];

    final pressure = json['pressure'] as Map<String, dynamic>?;
    final flow = json['flow'] as Map<String, dynamic>?;
    final temperature = json['temperature'] as Map<String, dynamic>?;
    final totals = json['totals'] as Map<String, dynamic>?;

    final pressureData = _numList(pressure?['pressure']);
    final pressureGoal = _numList(pressure?['goal']);
    final flowData = _numList(flow?['flow']);
    final flowGoal = _numList(flow?['goal']);
    final flowByWeight = _numList(flow?['by_weight']);
    final tempBasket = _numList(temperature?['basket']);
    final tempMix = _numList(temperature?['mix']);
    final tempGoal = _numList(temperature?['goal']);
    final totalWeight = _numList(totals?['weight']);
    final waterDispensed = _numList(totals?['water_dispensed']);

    final allArrays = [
      elapsed,
      pressureData,
      pressureGoal,
      flowData,
      flowGoal,
      flowByWeight,
      tempBasket,
      tempMix,
      tempGoal,
      totalWeight,
      waterDispensed,
    ];
    final count = allArrays
        .where((l) => l.isNotEmpty)
        .map((l) => l.length)
        .reduce(min);

    final boundaries = _stepBoundaries(profile);

    final snapshots = <ShotSnapshot>[];
    for (var i = 0; i < count; i++) {
      final ts = baseTimestamp.add(
        Duration(milliseconds: (elapsed[i] * 1000).round()),
      );

      final frame = _frameForElapsed(elapsed[i], boundaries);

      final machineSnap = MachineSnapshot(
        timestamp: ts,
        state: const MachineStateSnapshot(
          state: MachineState.espresso,
          substate: MachineSubstate.pouring,
        ),
        flow: _at(flowData, i),
        pressure: _at(pressureData, i),
        targetFlow: _at(flowGoal, i),
        targetPressure: _at(pressureGoal, i),
        mixTemperature: _at(tempMix, i),
        groupTemperature: _at(tempBasket, i),
        targetMixTemperature: _at(tempGoal, i),
        targetGroupTemperature: _at(tempGoal, i),
        profileFrame: frame,
        steamTemperature: 0,
      );

      final hasWeight = i < totalWeight.length;
      final weightSnap = hasWeight
          ? WeightSnapshot(
              timestamp: ts,
              weight: totalWeight[i],
              weightFlow: _at(flowByWeight, i),
            )
          : null;

      snapshots.add(ShotSnapshot(machine: machineSnap, scale: weightSnap));
    }

    return snapshots;
  }

  /// Safe index access — returns 0.0 if out of bounds.
  static double _at(List<double> list, int i) =>
      i < list.length ? list[i] : 0.0;

  /// Parses a JSON list of numbers that may contain strings, ints, or doubles.
  /// Returns an empty list if [value] is null or not a list.
  static List<double> _numList(dynamic value) {
    if (value == null || value is! List) return [];
    return value.map((e) {
      if (e is num) return e.toDouble();
      return double.tryParse(e.toString()) ?? 0.0;
    }).toList();
  }

  /// Returns a non-null, non-empty string or null.
  static String? _str(dynamic value) {
    if (value == null) return null;
    final s = value.toString().trim();
    return s.isEmpty ? null : s;
  }
}
