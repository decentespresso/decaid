import 'package:reaprime/src/import/parsers/tcl_parser.dart';
import 'package:reaprime/src/settings/charging_mode.dart';

class SettingsTdbResult {
  final bool? wakeScheduleEnabled;
  final int? wakeHour;
  final int? wakeMinute;
  final int? keepAwakeForMinutes;

  final bool? keepScaleOn;
  final int? sleepTimeoutMinutes;
  final ChargingMode? chargingMode;

  final double? doseWeight;
  final String? grinderSetting;
  final String? grinderModel;
  final double? targetYield;

  final int? steamTemperature;
  final int? steamDuration;

  final int? hotWaterTemperature;
  final int? hotWaterVolume;

  final double? rinseFlow;
  final int? rinseDuration;

  final String? machineBluetoothAddress;
  final String? scaleBluetoothAddress;

  const SettingsTdbResult({
    this.wakeScheduleEnabled,
    this.wakeHour,
    this.wakeMinute,
    this.keepAwakeForMinutes,
    this.keepScaleOn,
    this.sleepTimeoutMinutes,
    this.chargingMode,
    this.doseWeight,
    this.grinderSetting,
    this.grinderModel,
    this.targetYield,
    this.steamTemperature,
    this.steamDuration,
    this.hotWaterTemperature,
    this.hotWaterVolume,
    this.rinseFlow,
    this.rinseDuration,
    this.machineBluetoothAddress,
    this.scaleBluetoothAddress,
  });

  bool get isEmpty =>
      wakeHour == null &&
      wakeMinute == null &&
      keepAwakeForMinutes == null &&
      keepScaleOn == null &&
      sleepTimeoutMinutes == null &&
      chargingMode == null &&
      doseWeight == null &&
      grinderSetting == null &&
      grinderModel == null &&
      targetYield == null &&
      steamTemperature == null &&
      steamDuration == null &&
      hotWaterTemperature == null &&
      hotWaterVolume == null &&
      rinseFlow == null &&
      rinseDuration == null;
}

class SettingsTdbParser {
  static SettingsTdbResult parse(String content) {
    final data = TclParser.parse(content);

    final wakeSeconds = _parseInt(data['scheduler_wake']);
    final sleepSeconds = _parseInt(data['scheduler_sleep']);

    int? wakeHour;
    int? wakeMinute;
    if (wakeSeconds != null) {
      wakeHour = wakeSeconds ~/ 3600;
      wakeMinute = (wakeSeconds % 3600) ~/ 60;
    }

    int? keepAwakeFor;
    if (wakeSeconds != null && sleepSeconds != null) {
      var diff = sleepSeconds - wakeSeconds;
      if (diff < 0) diff += 86400;
      keepAwakeFor = diff ~/ 60;
    }

    int? sleepTimeoutMinutes;
    final screenSaverMinutes = _parseInt(data['screen_saver_delay']);
    if (screenSaverMinutes != null) {
      sleepTimeoutMinutes = _snapToSleepOption(screenSaverMinutes);
    }

    final doseRaw = _parseDouble(data['grinder_dose_weight']);
    final doseWeight = (doseRaw != null && doseRaw != 0) ? doseRaw : null;

    final yieldRaw = _parseDouble(data['final_desired_shot_weight_advanced']);
    final targetYield = (yieldRaw != null && yieldRaw != 0) ? yieldRaw : null;

    final grinderSettingRaw = _nonEmpty(data['grinder_setting']?.toString());
    final grinderSetting =
        (grinderSettingRaw != null && grinderSettingRaw != '0')
        ? grinderSettingRaw
        : null;

    final grinderModel = _nonEmpty(data['grinder_model']?.toString());

    return SettingsTdbResult(
      wakeScheduleEnabled: _parseBool(data['scheduler_enable']),
      wakeHour: wakeHour,
      wakeMinute: wakeMinute,
      keepAwakeForMinutes: keepAwakeFor,
      keepScaleOn: _parseBool(data['keep_scale_on']),
      sleepTimeoutMinutes: sleepTimeoutMinutes,
      chargingMode: _parseChargingMode(data['smart_battery_charging']),
      doseWeight: doseWeight,
      grinderSetting: grinderSetting,
      grinderModel: grinderModel,
      targetYield: targetYield,
      steamTemperature: _parseInt(data['steam_temperature']),
      steamDuration: _parseInt(data['steam_max_time']),
      hotWaterTemperature: _parseInt(data['water_temperature']),
      hotWaterVolume: _parseInt(data['water_volume']),
      rinseFlow: _parseDouble(data['flush_flow']),
      rinseDuration: _parseInt(data['flush_seconds']),
      machineBluetoothAddress: _nonEmpty(data['bluetooth_address']?.toString()),
      scaleBluetoothAddress: _nonEmpty(
        data['scale_bluetooth_address']?.toString(),
      ),
    );
  }

  static bool? _parseBool(dynamic value) {
    if (value == null) return null;
    return value.toString() == '1';
  }

  static ChargingMode? _parseChargingMode(dynamic value) {
    if (value == null) return null;
    switch (value.toString()) {
      case '0':
        return ChargingMode.disabled;
      case '1':
        return ChargingMode.longevity;
      case '2':
        return ChargingMode.highAvailability;
      default:
        return null;
    }
  }

  static int? _parseInt(dynamic value) {
    if (value == null) return null;
    return int.tryParse(value.toString());
  }

  static double? _parseDouble(dynamic value) {
    if (value == null) return null;
    return double.tryParse(value.toString());
  }

  static String? _nonEmpty(String? value) {
    if (value == null || value.isEmpty) return null;
    return value;
  }

  static const _sleepOptions = [0, 15, 30, 45, 60, 90, 120, 180];

  static int _snapToSleepOption(int minutes) {
    int closest = _sleepOptions.first;
    int bestDiff = (minutes - closest).abs();
    for (final option in _sleepOptions) {
      final diff = (minutes - option).abs();
      if (diff < bestDiff) {
        bestDiff = diff;
        closest = option;
      }
    }
    return closest;
  }
}
