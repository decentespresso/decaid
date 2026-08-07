import 'dart:convert';

import 'package:reaprime/src/settings/charging_mode.dart';
import 'package:reaprime/src/settings/gateway_mode.dart';
import 'package:reaprime/src/settings/scale_power_mode.dart';
import 'package:reaprime/src/settings/settings_controller.dart';
import 'package:reaprime/src/services/webserver/data_export/data_export_section.dart';

/// Settings is a singleton section: the payload is a fixed small set of
/// scalar values, wake schedules, and device preferences. It is materialized
/// as one JSON value, bounded by the handler's maximum record size (the
/// sink rejects oversized fragments).
class SettingsExportSection implements DataExportSection {
  final SettingsController _controller;

  SettingsExportSection({required SettingsController controller})
    : _controller = controller;

  @override
  String get filename => 'settings.json';

  @override
  Future<void> exportJson(JsonSink output) async {
    output.writeRaw(
      jsonEncode({
        'settings': {
          'gatewayMode': _controller.gatewayMode.name,
          'logLevel': _controller.logLevel,
          'themeMode': _controller.themeMode.name,
          'weightFlowMultiplier': _controller.weightFlowMultiplier,
          'volumeFlowMultiplier': _controller.volumeFlowMultiplier,
          'hotWaterFlowMultiplier': _controller.hotWaterFlowMultiplier,
          'scalePowerMode': _controller.scalePowerMode.name,
          'blockOnNoScale': _controller.blockOnNoScale,
          'blockTareDuringShot': _controller.blockTareDuringShot,
          'stopHotWaterAtWeight': _controller.stopHotWaterAtWeight,
          'defaultSkinId': _controller.defaultSkinId,
          'automaticUpdateCheck': _controller.automaticUpdateCheck,
          'chargingMode': _controller.chargingMode.name,
          'nightModeEnabled': _controller.nightModeEnabled,
          'nightModeSleepTime': _controller.nightModeSleepTime,
          'nightModeMorningTime': _controller.nightModeMorningTime,
          'userPresenceEnabled': _controller.userPresenceEnabled,
          'sleepTimeoutMinutes': _controller.sleepTimeoutMinutes,
          'lowBatteryBrightnessLimit': _controller.lowBatteryBrightnessLimit,
          'keepAwake': _controller.keepAwake,
        },
        'wakeSchedules': _controller.wakeSchedules,
        'devicePreferences': {
          'preferredMachineId': _controller.preferredMachineId,
          'preferredScaleId': _controller.preferredScaleId,
        },
      }),
    );
  }

  @override
  Future<SectionImportResult> importJson(
    SectionJsonInput input,
    ConflictStrategy strategy,
  ) async {
    final errors = <String>[];
    var imported = 0;

    try {
      final data = await input.readWhole();
      final map = data as Map<String, dynamic>;
      final settings = map['settings'] as Map<String, dynamic>?;
      if (settings != null) {
        if (settings.containsKey('gatewayMode')) {
          final mode = GatewayModeFromString.fromString(
            settings['gatewayMode'],
          );
          if (mode != null) {
            await _controller.updateGatewayMode(mode);
            imported++;
          } else {
            errors.add('Invalid gatewayMode: ${settings['gatewayMode']}');
          }
        }

        if (settings.containsKey('logLevel')) {
          await _controller.updateLogLevel(settings['logLevel'] as String);
          imported++;
        }

        if (settings.containsKey('weightFlowMultiplier')) {
          final value = settings['weightFlowMultiplier'];
          if (value is num) {
            await _controller.setWeightFlowMultiplier(value.toDouble());
            imported++;
          } else {
            errors.add('Invalid weightFlowMultiplier: $value');
          }
        }

        if (settings.containsKey('volumeFlowMultiplier')) {
          final value = settings['volumeFlowMultiplier'];
          if (value is num) {
            await _controller.setVolumeFlowMultiplier(value.toDouble());
            imported++;
          } else {
            errors.add('Invalid volumeFlowMultiplier: $value');
          }
        }

        if (settings.containsKey('hotWaterFlowMultiplier')) {
          final value = settings['hotWaterFlowMultiplier'];
          if (value is num) {
            await _controller.setHotWaterFlowMultiplier(value.toDouble());
            imported++;
          } else {
            errors.add('Invalid hotWaterFlowMultiplier: $value');
          }
        }

        if (settings.containsKey('scalePowerMode')) {
          final mode = ScalePowerModeFromString.fromString(
            settings['scalePowerMode'],
          );
          if (mode != null) {
            await _controller.setScalePowerMode(mode);
            imported++;
          } else {
            errors.add('Invalid scalePowerMode: ${settings['scalePowerMode']}');
          }
        }

        if (settings.containsKey('blockOnNoScale')) {
          await _controller.setBlockOnNoScale(
            settings['blockOnNoScale'] as bool,
          );
          imported++;
        }

        if (settings.containsKey('blockTareDuringShot')) {
          await _controller.setBlockTareDuringShot(
            settings['blockTareDuringShot'] as bool,
          );
          imported++;
        }

        if (settings.containsKey('stopHotWaterAtWeight')) {
          await _controller.setStopHotWaterAtWeight(
            settings['stopHotWaterAtWeight'] as bool,
          );
          imported++;
        }

        if (settings.containsKey('defaultSkinId')) {
          await _controller.setDefaultSkinId(
            settings['defaultSkinId'] as String,
          );
          imported++;
        }

        if (settings.containsKey('automaticUpdateCheck')) {
          await _controller.setAutomaticUpdateCheck(
            settings['automaticUpdateCheck'] as bool,
          );
          imported++;
        }

        if (settings.containsKey('chargingMode')) {
          final mode = ChargingModeFromString.fromString(
            settings['chargingMode'],
          );
          if (mode != null) {
            await _controller.setChargingMode(mode);
            imported++;
          } else {
            errors.add('Invalid chargingMode: ${settings['chargingMode']}');
          }
        }

        if (settings.containsKey('nightModeEnabled')) {
          await _controller.setNightModeEnabled(
            settings['nightModeEnabled'] as bool,
          );
          imported++;
        }

        if (settings.containsKey('nightModeSleepTime')) {
          await _controller.setNightModeSleepTime(
            settings['nightModeSleepTime'] as int,
          );
          imported++;
        }

        if (settings.containsKey('nightModeMorningTime')) {
          await _controller.setNightModeMorningTime(
            settings['nightModeMorningTime'] as int,
          );
          imported++;
        }

        if (settings.containsKey('userPresenceEnabled')) {
          await _controller.setUserPresenceEnabled(
            settings['userPresenceEnabled'] as bool,
          );
          imported++;
        }

        if (settings.containsKey('sleepTimeoutMinutes')) {
          final v = settings['sleepTimeoutMinutes'];
          if (v is int) {
            await _controller.setSleepTimeoutMinutes(v);
            imported++;
          } else {
            errors.add(
              'sleepTimeoutMinutes must be an integer, got ${v.runtimeType}',
            );
          }
        }

        if (settings.containsKey('lowBatteryBrightnessLimit')) {
          await _controller.setLowBatteryBrightnessLimit(
            settings['lowBatteryBrightnessLimit'] as bool,
          );
          imported++;
        }

        if (settings.containsKey('keepAwake')) {
          await _controller.setKeepAwake(settings['keepAwake'] as bool);
          imported++;
        }
      }

      if (map.containsKey('wakeSchedules')) {
        await _controller.setWakeSchedules(map['wakeSchedules'] as String);
        imported++;
      }

      final devicePrefs = map['devicePreferences'] as Map<String, dynamic>?;
      if (devicePrefs != null) {
        if (devicePrefs.containsKey('preferredMachineId')) {
          await _controller.setPreferredMachineId(
            devicePrefs['preferredMachineId'] as String?,
          );
          imported++;
        }
        if (devicePrefs.containsKey('preferredScaleId')) {
          await _controller.setPreferredScaleId(
            devicePrefs['preferredScaleId'] as String?,
          );
          imported++;
        }
      }
    } catch (e) {
      errors.add('Failed to import settings: $e');
    }

    return SectionImportResult(imported: imported, errors: errors);
  }
}
