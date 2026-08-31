import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/settings/gateway_mode.dart';
import 'package:reaprime/src/settings/settings_controller.dart';
import 'package:reaprime/src/services/webserver/data_export/data_export_section.dart';
import 'package:reaprime/src/services/webserver/data_export/settings_export_section.dart';

import '../helpers/mock_settings_service.dart';
import 'streaming_test_helpers.dart';

Future<Map<String, dynamic>> exportSettings(
  SettingsExportSection section,
) async {
  final sink = CapturingJsonSink();
  await section.exportJson(sink);
  return jsonDecode(sink.json) as Map<String, dynamic>;
}

void main() {
  late MockSettingsService settingsService;
  late SettingsController controller;
  late SettingsExportSection section;

  setUp(() async {
    settingsService = MockSettingsService();
    controller = SettingsController(settingsService);
    await controller.loadSettings();
    section = SettingsExportSection(controller: controller);
  });

  tearDown(() {
    controller.dispose();
  });

  group('export', () {
    test('exports all settings as structured JSON', () async {
      final map = await exportSettings(section);

      expect(map, contains('settings'));
      expect(map, contains('wakeSchedules'));
      expect(map, contains('devicePreferences'));

      final settings = map['settings'] as Map<String, dynamic>;
      expect(settings['gatewayMode'], 'disabled');
      expect(settings['logLevel'], 'INFO');
      expect(settings['weightFlowMultiplier'], 1.0);
      expect(settings['volumeFlowMultiplier'], 0.3);
      expect(settings['hotWaterFlowMultiplier'], 0.3);
      expect(settings['scalePowerMode'], 'disabled');
      expect(settings['blockTareDuringShot'], isFalse);
      expect(settings['stopHotWaterAtWeight'], isTrue);
      expect(settings['scaleButtonStartsEspresso'], isFalse);
      expect(settings['automaticUpdateCheck'], isTrue);
      expect(settings['chargingMode'], 'disabled');
      expect(settings['nightModeEnabled'], isFalse);
      expect(settings['nightModeSleepTime'], 1320);
      expect(settings['nightModeMorningTime'], 420);
      expect(settings['userPresenceEnabled'], isTrue);
      expect(settings['sleepTimeoutMinutes'], 30);
      expect(settings['lowBatteryBrightnessLimit'], isFalse);
      expect(settings['keepAwake'], isTrue);
      expect(map['wakeSchedules'], '[]');

      final devicePrefs = map['devicePreferences'] as Map<String, dynamic>;
      expect(devicePrefs['preferredMachineId'], isNull);
      expect(devicePrefs['preferredScaleId'], isNull);
    });

    test('exports modified settings', () async {
      await controller.updateGatewayMode(GatewayMode.full);
      await controller.setWeightFlowMultiplier(2.5);
      await controller.setPreferredMachineId('DE1-ABC123');

      final map = await exportSettings(section);
      final settings = map['settings'] as Map<String, dynamic>;
      expect(settings['gatewayMode'], 'full');
      expect(settings['weightFlowMultiplier'], 2.5);
      final devicePrefs = map['devicePreferences'] as Map<String, dynamic>;
      expect(devicePrefs['preferredMachineId'], 'DE1-ABC123');
    });
  });

  group('import', () {
    test('imports settings from exported data', () async {
      await controller.updateGatewayMode(GatewayMode.full);
      await controller.setWeightFlowMultiplier(2.5);
      await controller.setNightModeEnabled(true);
      await controller.setStopHotWaterAtWeight(false);
      await controller.setHotWaterFlowMultiplier(0.5);
      await controller.setBlockTareDuringShot(true);
      await controller.setScaleButtonStartsEspresso(true);
      await controller.setLowBatteryBrightnessLimit(true);
      await controller.setKeepAwake(false);
      final exported = await exportSettings(section);

      await controller.updateGatewayMode(GatewayMode.disabled);
      await controller.setWeightFlowMultiplier(1.0);
      await controller.setNightModeEnabled(false);
      await controller.setStopHotWaterAtWeight(true);
      await controller.setHotWaterFlowMultiplier(0.3);
      await controller.setBlockTareDuringShot(false);
      await controller.setScaleButtonStartsEspresso(false);
      await controller.setLowBatteryBrightnessLimit(false);
      await controller.setKeepAwake(true);

      final result = await importSectionJson(
        section,
        jsonEncode(exported),
        ConflictStrategy.overwrite,
      );
      expect(result.errors, isEmpty);
      expect(result.imported, greaterThan(0));
      expect(controller.gatewayMode, GatewayMode.full);
      expect(controller.weightFlowMultiplier, 2.5);
      expect(controller.nightModeEnabled, isTrue);
      expect(controller.stopHotWaterAtWeight, isFalse);
      expect(controller.hotWaterFlowMultiplier, 0.5);
      expect(controller.blockTareDuringShot, isTrue);
      expect(controller.scaleButtonStartsEspresso, isTrue);
      expect(controller.lowBatteryBrightnessLimit, isTrue);
      expect(controller.keepAwake, isFalse);
    });

    test('imports device preferences', () async {
      final data = {
        'settings': <String, dynamic>{},
        'wakeSchedules': '[]',
        'devicePreferences': {
          'preferredMachineId': 'DE1-XYZ',
          'preferredScaleId': 'SCALE-ABC',
        },
      };
      final result = await importSectionJson(
        section,
        jsonEncode(data),
        ConflictStrategy.overwrite,
      );
      expect(result.errors, isEmpty);
      expect(controller.preferredMachineId, 'DE1-XYZ');
      expect(controller.preferredScaleId, 'SCALE-ABC');
    });

    test('imports wake schedules', () async {
      final data = {
        'settings': <String, dynamic>{},
        'wakeSchedules': '[{"time": 420, "enabled": true}]',
        'devicePreferences': <String, dynamic>{},
      };
      final result = await importSectionJson(
        section,
        jsonEncode(data),
        ConflictStrategy.overwrite,
      );
      expect(result.errors, isEmpty);
      expect(controller.wakeSchedules, '[{"time": 420, "enabled": true}]');
    });

    test('reports errors for invalid enum values', () async {
      final data = {
        'settings': {
          'gatewayMode': 'invalid_mode',
          'scalePowerMode': 'bad_mode',
        },
        'wakeSchedules': '[]',
        'devicePreferences': <String, dynamic>{},
      };
      final result = await importSectionJson(
        section,
        jsonEncode(data),
        ConflictStrategy.overwrite,
      );
      expect(result.errors, hasLength(2));
      expect(result.errors[0], contains('Invalid gatewayMode'));
      expect(result.errors[1], contains('Invalid scalePowerMode'));
    });

    test('rejects a non-boolean scale button setting', () async {
      final result = await importSectionJson(
        section,
        '{"settings":{"scaleButtonStartsEspresso":"yes"}}',
        ConflictStrategy.overwrite,
      );

      expect(controller.scaleButtonStartsEspresso, isFalse);
      expect(result.errors, hasLength(1));
      expect(
        result.errors.single,
        contains('Invalid scaleButtonStartsEspresso'),
      );
    });

    test('counts settings imported before a later field fails', () async {
      final result = await importSectionJson(
        section,
        '{"settings":{"gatewayMode":"full","logLevel":123}}',
        ConflictStrategy.overwrite,
      );

      expect(controller.gatewayMode, GatewayMode.full);
      expect(result.imported, 1);
      expect(result.errors, isNotEmpty);
    });

    test('returns error for invalid payload shape', () async {
      final result = await importSectionJson(
        section,
        '"not a map"',
        ConflictStrategy.overwrite,
      );
      expect(result.imported, 0);
      expect(result.errors, hasLength(1));
    });

    test('handles partial settings gracefully', () async {
      final data = {
        'settings': {'logLevel': 'FINE'},
      };
      final result = await importSectionJson(
        section,
        jsonEncode(data),
        ConflictStrategy.overwrite,
      );
      expect(result.errors, isEmpty);
      expect(result.imported, 1);
      expect(controller.logLevel, 'FINE');
    });
  });
}
