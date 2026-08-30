import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/services/webserver_service.dart';
import 'package:reaprime/src/settings/settings_controller.dart';
import 'package:reaprime/src/settings/settings_service.dart';
import 'package:reaprime/src/webui_support/webui_service.dart';
import 'package:reaprime/src/webui_support/webui_storage.dart';
import 'package:shelf_plus/shelf_plus.dart';

import '../helpers/mock_settings_service.dart';

void main() {
  late MockSettingsService mockService;
  late SettingsController controller;

  setUp(() async {
    mockService = MockSettingsService();
    controller = SettingsController(mockService);
    await controller.loadSettings();
  });

  group('simulatedDevices', () {
    test('defaults to empty set', () {
      expect(controller.simulatedDevices, isEmpty);
    });

    test('can set simulated devices', () async {
      await controller.setSimulatedDevices({
        SimulatedDevicesTypes.machine,
        SimulatedDevicesTypes.scale,
      });
      expect(controller.simulatedDevices, {
        SimulatedDevicesTypes.machine,
        SimulatedDevicesTypes.scale,
      });
    });

    test('SimulatedDevicesTypes names match expected values', () {
      expect(SimulatedDevicesTypes.machine.name, 'machine');
      expect(SimulatedDevicesTypes.scale.name, 'scale');
      expect(SimulatedDevicesTypes.sensor.name, 'sensor');
    });

    test('SimulatedDevicesTypesFromString parses valid names', () {
      expect(
        SimulatedDevicesTypesFromString.fromString('machine'),
        SimulatedDevicesTypes.machine,
      );
      expect(
        SimulatedDevicesTypesFromString.fromString('scale'),
        SimulatedDevicesTypes.scale,
      );
      expect(
        SimulatedDevicesTypesFromString.fromString('sensor'),
        SimulatedDevicesTypes.sensor,
      );
    });

    test('SimulatedDevicesTypesFromString returns null for invalid names', () {
      expect(SimulatedDevicesTypesFromString.fromString('invalid'), isNull);
      expect(SimulatedDevicesTypesFromString.fromString(''), isNull);
    });

    test('simulatedDevices serializes to name list', () {
      controller.setSimulatedDevices({
        SimulatedDevicesTypes.machine,
        SimulatedDevicesTypes.sensor,
      });
      final nameList = controller.simulatedDevices.map((e) => e.name).toList();
      expect(nameList, containsAll(['machine', 'sensor']));
      expect(nameList.length, 2);
    });
  });

  group('stopHotWaterAtWeight', () {
    test('defaults to true', () {
      expect(controller.stopHotWaterAtWeight, isTrue);
    });

    test('can be toggled off and persists', () async {
      await controller.setStopHotWaterAtWeight(false);
      expect(controller.stopHotWaterAtWeight, isFalse);
      expect(await mockService.stopHotWaterAtWeight(), isFalse);
    });
  });

  group('scaleButtonStartsEspresso', () {
    test('defaults off', () {
      expect(controller.scaleButtonStartsEspresso, isFalse);
    });

    test('persists changes', () async {
      await controller.setScaleButtonStartsEspresso(true);
      expect(controller.scaleButtonStartsEspresso, isTrue);
      expect(await mockService.scaleButtonStartsEspresso(), isTrue);
    });
  });

  group('scaleButtonStartsEspresso settings API', () {
    late RouterPlus app;
    late WebUIStorage storage;
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('decaid-settings-');
      storage = WebUIStorage(controller);
      storage.debugInitWithWebUIDir(tempDir);
      app = Router().plus;
      SettingsHandler(
        controller: controller,
        service: WebUIService(listLocalAddresses: () async => []),
        webUIStorage: storage,
      ).addRoutes(app);
    });

    tearDown(() async {
      if (tempDir.existsSync()) await tempDir.delete(recursive: true);
    });

    test('GET reports default and POST persists valid value', () async {
      final get = await app.call(
        Request('GET', Uri.parse('http://localhost/api/v1/settings')),
      );
      expect((jsonDecode(await get.readAsString()) as Map)['scaleButtonStartsEspresso'], isFalse);

      final post = await app.call(
        Request(
          'POST',
          Uri.parse('http://localhost/api/v1/settings'),
          body: jsonEncode({'scaleButtonStartsEspresso': true}),
        ),
      );
      expect(post.statusCode, 200);
      expect(controller.scaleButtonStartsEspresso, isTrue);
    });

    test('POST rejects invalid value', () async {
      final response = await app.call(
        Request(
          'POST',
          Uri.parse('http://localhost/api/v1/settings'),
          body: jsonEncode({'scaleButtonStartsEspresso': 'yes'}),
        ),
      );
      expect(response.statusCode, 400);
      expect(controller.scaleButtonStartsEspresso, isFalse);
    });
  });

  group('blockTareDuringShot', () {
    test('defaults to false', () {
      expect(controller.blockTareDuringShot, isFalse);
    });

    test('can be toggled on and persists', () async {
      await controller.setBlockTareDuringShot(true);
      expect(controller.blockTareDuringShot, isTrue);
      expect(await mockService.blockTareDuringShot(), isTrue);
    });
  });

  group('keepAwake', () {
    test('defaults to true', () {
      expect(controller.keepAwake, isTrue);
    });

    test('can be toggled off and persists', () async {
      await controller.setKeepAwake(false);
      expect(controller.keepAwake, isFalse);
      expect(await mockService.keepAwake(), isFalse);
    });
  });

  group('hotWaterFlowMultiplier', () {
    test('defaults to 0.3, separate from weightFlowMultiplier (1.0)', () {
      expect(controller.hotWaterFlowMultiplier, 0.3);
      expect(controller.weightFlowMultiplier, 1.0);
    });

    test(
      'can be set independently of the shot multiplier and persists',
      () async {
        await controller.setHotWaterFlowMultiplier(0.5);
        expect(controller.hotWaterFlowMultiplier, 0.5);
        expect(
          controller.weightFlowMultiplier,
          1.0,
          reason: 'shot multiplier is untouched',
        );
        expect(await mockService.hotWaterFlowMultiplier(), 0.5);
      },
    );
  });

  group('themeMode', () {
    test('defaults to system', () {
      expect(controller.themeMode, ThemeMode.system);
    });

    test('can update theme mode to dark', () async {
      await controller.updateThemeMode(ThemeMode.dark);
      expect(controller.themeMode, ThemeMode.dark);
    });

    test('can update theme mode to light', () async {
      await controller.updateThemeMode(ThemeMode.light);
      expect(controller.themeMode, ThemeMode.light);
    });

    test('ignores null theme mode', () async {
      await controller.updateThemeMode(ThemeMode.dark);
      await controller.updateThemeMode(null);
      expect(controller.themeMode, ThemeMode.dark);
    });

    test('themeMode name matches expected values', () {
      expect(ThemeMode.system.name, 'system');
      expect(ThemeMode.light.name, 'light');
      expect(ThemeMode.dark.name, 'dark');
    });

    test('themeMode serializes to name string', () async {
      await controller.updateThemeMode(ThemeMode.dark);
      expect(controller.themeMode.name, 'dark');
    });

    test('ThemeMode lookup returns null for invalid name', () {
      final mode = ThemeMode.values
          .where((e) => e.name == 'invalid')
          .firstOrNull;
      expect(mode, isNull);
    });
  });
}
