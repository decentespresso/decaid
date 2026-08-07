import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/import/parsers/settings_tdb_parser.dart';
import 'package:reaprime/src/settings/charging_mode.dart';

void main() {
  group('SettingsTdbParser', () {
    group('scheduler / wake schedule', () {
      test('parses wake schedule from seconds since midnight', () {
        final content = '''
scheduler_enable 1
scheduler_wake 25200
scheduler_sleep 28800
''';
        final result = SettingsTdbParser.parse(content);
        expect(result.wakeScheduleEnabled, true);
        expect(result.wakeHour, 7);
        expect(result.wakeMinute, 0);
        expect(result.keepAwakeForMinutes, 60);
      });

      test('midnight wraparound for keepAwakeForMinutes', () {
        final content = '''
scheduler_enable 1
scheduler_wake 82800
scheduler_sleep 3600
''';
        final result = SettingsTdbParser.parse(content);
        expect(result.wakeHour, 23);
        expect(result.wakeMinute, 0);
        expect(result.keepAwakeForMinutes, 120);
      });

      test('scheduler_enable 0 means disabled', () {
        final content = '''
scheduler_enable 0
scheduler_wake 25200
scheduler_sleep 28800
''';
        final result = SettingsTdbParser.parse(content);
        expect(result.wakeScheduleEnabled, false);
      });

      test('wake minute is extracted correctly', () {
        final content = '''
scheduler_wake 25500
''';
        final result = SettingsTdbParser.parse(content);
        expect(result.wakeHour, 7);
        expect(result.wakeMinute, 5);
      });
    });

    group('scale and sleep settings', () {
      test('parses keep_scale_on and screen_saver_delay', () {
        final content = '''
keep_scale_on 1
screen_saver_delay 30
''';
        final result = SettingsTdbParser.parse(content);
        expect(result.keepScaleOn, true);
        expect(result.sleepTimeoutMinutes, 30);
      });

      test('keep_scale_on 0 means false', () {
        final content = 'keep_scale_on 0\n';
        final result = SettingsTdbParser.parse(content);
        expect(result.keepScaleOn, false);
      });

      test('screen_saver_delay snaps to nearest valid option (minutes)', () {
        expect(
          SettingsTdbParser.parse('screen_saver_delay 2\n').sleepTimeoutMinutes,
          0,
        );
        expect(
          SettingsTdbParser.parse(
            'screen_saver_delay 10\n',
          ).sleepTimeoutMinutes,
          15,
        );
        expect(
          SettingsTdbParser.parse(
            'screen_saver_delay 50\n',
          ).sleepTimeoutMinutes,
          45,
        );
        expect(
          SettingsTdbParser.parse(
            'screen_saver_delay 118\n',
          ).sleepTimeoutMinutes,
          120,
        );
        expect(
          SettingsTdbParser.parse(
            'screen_saver_delay 180\n',
          ).sleepTimeoutMinutes,
          180,
        );
        expect(
          SettingsTdbParser.parse(
            'screen_saver_delay 250\n',
          ).sleepTimeoutMinutes,
          180,
        );
      });

      test('screen_saver_delay of 0 snaps to 0 (disabled)', () {
        final content = 'screen_saver_delay 0\n';
        final result = SettingsTdbParser.parse(content);
        expect(result.sleepTimeoutMinutes, 0);
      });
    });

    group('workflow settings', () {
      test('parses dose, grinder, and yield', () {
        final content = '''
grinder_dose_weight 18.5
grinder_setting 15
grinder_model {Niche Zero}
final_desired_shot_weight_advanced 36.0
''';
        final result = SettingsTdbParser.parse(content);
        expect(result.doseWeight, 18.5);
        expect(result.grinderSetting, '15');
        expect(result.grinderModel, 'Niche Zero');
        expect(result.targetYield, 36.0);
      });

      test('zero dose weight is treated as null', () {
        final content = 'grinder_dose_weight 0\n';
        final result = SettingsTdbParser.parse(content);
        expect(result.doseWeight, isNull);
      });

      test('zero target yield is treated as null', () {
        final content = 'final_desired_shot_weight_advanced 0\n';
        final result = SettingsTdbParser.parse(content);
        expect(result.targetYield, isNull);
      });

      test('grinder_setting "0" is treated as null', () {
        final content = 'grinder_setting 0\n';
        final result = SettingsTdbParser.parse(content);
        expect(result.grinderSetting, isNull);
      });

      test('empty grinder_setting is treated as null', () {
        final content = 'grinder_setting {}\n';
        final result = SettingsTdbParser.parse(content);
        expect(result.grinderSetting, isNull);
      });

      test('empty grinder_model is treated as null', () {
        final content = 'grinder_model {}\n';
        final result = SettingsTdbParser.parse(content);
        expect(result.grinderModel, isNull);
      });
    });

    group('steam settings', () {
      test('parses steam temperature and duration', () {
        final content = '''
steam_temperature 160
steam_max_time 90
''';
        final result = SettingsTdbParser.parse(content);
        expect(result.steamTemperature, 160);
        expect(result.steamDuration, 90);
      });
    });

    group('hot water settings', () {
      test('parses water temperature and volume', () {
        final content = '''
water_temperature 85
water_volume 200
''';
        final result = SettingsTdbParser.parse(content);
        expect(result.hotWaterTemperature, 85);
        expect(result.hotWaterVolume, 200);
      });
    });

    group('charging mode', () {
      test('smart_battery_charging 0 → disabled', () {
        final result = SettingsTdbParser.parse('smart_battery_charging 0\n');
        expect(result.chargingMode, ChargingMode.disabled);
      });

      test('smart_battery_charging 1 → longevity', () {
        final result = SettingsTdbParser.parse('smart_battery_charging 1\n');
        expect(result.chargingMode, ChargingMode.longevity);
      });

      test('smart_battery_charging 2 → highAvailability', () {
        final result = SettingsTdbParser.parse('smart_battery_charging 2\n');
        expect(result.chargingMode, ChargingMode.highAvailability);
      });

      test('unknown value returns null (leave Bridge setting untouched)', () {
        final result = SettingsTdbParser.parse('smart_battery_charging 99\n');
        expect(result.chargingMode, isNull);
      });

      test('missing key returns null', () {
        final result = SettingsTdbParser.parse('');
        expect(result.chargingMode, isNull);
      });

      test('chargingMode alone makes isEmpty false', () {
        final result = SettingsTdbParser.parse('smart_battery_charging 0\n');
        expect(result.isEmpty, false);
      });
    });

    group('rinse settings', () {
      test('parses rinse flow and duration', () {
        final content = '''
flush_flow 4.5
flush_seconds 10
''';
        final result = SettingsTdbParser.parse(content);
        expect(result.rinseFlow, 4.5);
        expect(result.rinseDuration, 10);
      });
    });

    group('missing keys', () {
      test('empty content returns all null', () {
        final result = SettingsTdbParser.parse('');
        expect(result.wakeScheduleEnabled, isNull);
        expect(result.wakeHour, isNull);
        expect(result.wakeMinute, isNull);
        expect(result.keepAwakeForMinutes, isNull);
        expect(result.keepScaleOn, isNull);
        expect(result.sleepTimeoutMinutes, isNull);
        expect(result.chargingMode, isNull);
        expect(result.doseWeight, isNull);
        expect(result.grinderSetting, isNull);
        expect(result.grinderModel, isNull);
        expect(result.targetYield, isNull);
        expect(result.steamTemperature, isNull);
        expect(result.steamDuration, isNull);
        expect(result.hotWaterTemperature, isNull);
        expect(result.hotWaterVolume, isNull);
        expect(result.rinseFlow, isNull);
        expect(result.rinseDuration, isNull);
      });

      test('isEmpty is true when all fields are null', () {
        final result = SettingsTdbParser.parse('');
        expect(result.isEmpty, true);
      });

      test('isEmpty is false when a non-wake field is present', () {
        final content = 'grinder_dose_weight 18.0\n';
        final result = SettingsTdbParser.parse(content);
        expect(result.isEmpty, false);
      });

      test('isEmpty is true when only wakeScheduleEnabled is set '
          'but wake hour/minute are null', () {
        final content = 'scheduler_enable 1\n';
        final result = SettingsTdbParser.parse(content);
        expect(result.isEmpty, true);
      });

      test('isEmpty is false when wake hour and minute are set', () {
        final content = '''
scheduler_enable 1
scheduler_wake 25200
''';
        final result = SettingsTdbParser.parse(content);
        expect(result.isEmpty, false);
      });
    });
  });
}
