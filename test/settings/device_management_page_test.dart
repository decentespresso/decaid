import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/device_controller.dart';
import 'package:reaprime/src/settings/device_management_page.dart';
import 'package:reaprime/src/settings/settings_controller.dart';

import '../helpers/mock_device_discovery_service.dart';
import '../helpers/mock_settings_service.dart';

void main() {
  testWidgets('scale button switch is off by default and persists changes', (
    tester,
  ) async {
    final settings = SettingsController(MockSettingsService());
    await settings.loadSettings();
    final discovery = MockDeviceDiscoveryService();
    final devices = DeviceController([discovery]);
    await devices.initialize();

    await tester.pumpWidget(
      MaterialApp(
        home: DeviceManagementPage(
          settingsController: settings,
          deviceController: devices,
        ),
      ),
    );

    expect(settings.scaleButtonStartsEspresso, isFalse);
    final toggle = find.byType(SwitchListTile);
    expect(toggle, findsOneWidget);
    await tester.tap(toggle);
    await tester.pump();
    expect(settings.scaleButtonStartsEspresso, isTrue);

    devices.dispose();
    discovery.dispose();
    settings.dispose();
  });
}
