import 'dart:math';

import 'package:reaprime/src/controllers/scale_controller.dart';
import 'package:reaprime/src/import/parsers/shot_v2_json_parser.dart';
import 'package:reaprime/src/import/parsers/tcl_parser.dart';
import 'package:reaprime/src/models/data/profile.dart';
import 'package:reaprime/src/models/data/shot_annotations.dart';
import 'package:reaprime/src/models/data/shot_record.dart';
import 'package:reaprime/src/models/data/shot_snapshot.dart';
import 'package:reaprime/src/models/data/workflow.dart';
import 'package:reaprime/src/models/data/workflow_context.dart';
import 'package:reaprime/src/models/device/machine.dart';
import 'package:uuid/uuid.dart';

/// Parses de1app `history/*.shot` (TCL format) into [ParsedShot] instances.
class TclShotParser {
  TclShotParser._();

  /// Parses a de1app `.shot` file [content] into a [ParsedShot].
  static ParsedShot parse(String content) {
    final map = TclParser.parse(content);

    final clock = int.parse(map['clock'] as String);
    final baseTimestamp = DateTime.fromMillisecondsSinceEpoch(
      clock * 1000,
      isUtc: true,
    );

    final settings = map['settings'] as Map<String, dynamic>? ?? {};

    final beanBrand = _str(settings['bean_brand']);
    final beanType = _str(settings['bean_type']);
    final beanNotes = _str(settings['bean_notes']);
    final roastLevel = _str(settings['roast_level']);
    final roastDate = _str(settings['roast_date']);

    final grinderModel = _str(settings['grinder_model']);
    final grinderSetting = _str(settings['grinder_setting']);

    final profileTitle = _str(settings['profile_title']) ?? '';
    final profileTargetWeight = _parseOptDouble(
      settings['final_desired_shot_weight'],
    );
    final profile = Profile(
      version: '2',
      title: profileTitle,
      notes: '',
      author: '',
      beverageType: BeverageType.espresso,
      steps: [],
      targetWeight: profileTargetWeight,
      targetVolumeCountStart: 0,
      tankTemperature: 0,
    );

    final doseWeight = _parseOptDouble(settings['grinder_dose_weight']);
    final actualYield = _parseOptDouble(settings['drink_weight']);
    final targetYield =
        _parseOptDouble(settings['target_drink_weight']) ??
        profileTargetWeight ??
        actualYield;
    final tds = _parseOptDouble(settings['drink_tds']);
    final ey = _parseOptDouble(settings['drink_ey']);
    final enjoyment = _parseOptDouble(settings['espresso_enjoyment']);
    final espressoNotes = _str(settings['espresso_notes']);

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
      name: profileTitle,
      profile: profile,
      context: context,
      steamSettings: SteamSettings.defaults(),
      hotWaterData: HotWaterData.defaults(),
      rinseData: RinseData.defaults(),
    );

    final measurements = _parseSnapshots(map, baseTimestamp, profile);

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

  static List<ShotSnapshot> _parseSnapshots(
    Map<String, dynamic> map,
    DateTime baseTimestamp,
    Profile profile,
  ) {
    final elapsed = _parseDoubleList(map['espresso_elapsed']);
    final pressure = _parseDoubleList(map['espresso_pressure']);
    final flow = _parseDoubleList(map['espresso_flow']);
    final flowWeight = _parseDoubleList(map['espresso_flow_weight']);
    final weight = _parseDoubleList(map['espresso_weight']);
    final tempBasket = _parseDoubleList(map['espresso_temperature_basket']);
    final tempMix = _parseDoubleList(map['espresso_temperature_mix']);
    final tempGoal = _parseDoubleList(map['espresso_temperature_goal']);
    final pressureGoal = _parseDoubleList(map['espresso_pressure_goal']);
    final flowGoal = _parseDoubleList(map['espresso_flow_goal']);

    final count = [
      elapsed,
      pressure,
      flow,
      flowWeight,
      weight,
      tempBasket,
      tempMix,
      tempGoal,
      pressureGoal,
      flowGoal,
    ].map((l) => l.length).reduce(min);

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
        flow: flow[i],
        pressure: pressure[i],
        targetFlow: flowGoal[i],
        targetPressure: pressureGoal[i],
        mixTemperature: tempMix[i],
        groupTemperature: tempBasket[i],
        targetMixTemperature: tempGoal[i],
        targetGroupTemperature: tempGoal[i],
        profileFrame: frame,
        steamTemperature: 0,
      );

      final weightSnap = WeightSnapshot(
        timestamp: ts,
        weight: weight[i],
        weightFlow: flowWeight[i],
      );

      snapshots.add(ShotSnapshot(machine: machineSnap, scale: weightSnap));
    }

    return snapshots;
  }

  /// Pre-computes cumulative step end-times from profile step durations.
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

  /// Parses a TCL list value ([List] of strings from [TclParser]) into a list of doubles.
  static List<double> _parseDoubleList(dynamic value) {
    if (value == null) return [];
    if (value is List) {
      return value.map((e) => double.parse(e.toString())).toList();
    }
    final d = double.tryParse(value.toString());
    return d != null ? [d] : [];
  }

  /// Returns a non-null, non-empty string or null.
  static String? _str(dynamic value) {
    if (value == null) return null;
    final s = value.toString().trim();
    return s.isEmpty ? null : s;
  }

  /// Parses a string-encoded double.
  static double? _parseOptDouble(dynamic value) {
    if (value == null) return null;
    if (value is num) return value.toDouble();
    final s = value.toString().trim();
    return s.isEmpty ? null : double.tryParse(s);
  }
}
