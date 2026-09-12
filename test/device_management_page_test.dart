import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/device_controller.dart';
import 'package:reaprime/src/settings/device_management_page.dart';
import 'package:reaprime/src/settings/settings_controller.dart';
import 'package:reaprime/src/settings/settings_service.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import 'helpers/mock_device_discovery_service.dart';
import 'helpers/mock_settings_service.dart';
import 'helpers/test_scale.dart';

Widget _app(Widget child) => ShadApp(home: child);

void main() {
  late MockDeviceDiscoveryService mockService;
  late DeviceController deviceController;
  late SettingsController settingsController;

  setUp(() async {
    mockService = MockDeviceDiscoveryService();
    deviceController = DeviceController([mockService]);
    await deviceController.initialize();
    settingsController = SettingsController(
      MockSettingsService() as SettingsService,
    );
    await settingsController.loadSettings();
  });

  tearDown(() {
    deviceController.dispose();
    mockService.dispose();
  });

  Future<void> pumpPage(WidgetTester tester) async {
    await tester.pumpWidget(
      _app(
        DeviceManagementPage(
          settingsController: settingsController,
          deviceController: deviceController,
        ),
      ),
    );
    await tester.pump();
  }

  group('DeviceManagementPage', () {
    testWidgets('offers a dosing scale section', (tester) async {
      mockService.addDevice(TestScale(deviceId: 'a', name: 'Scale A'));
      await pumpPage(tester);
      await tester.pump();

      expect(find.text('Dosing Scale'), findsOneWidget);
      expect(find.text('Auto-connect Scale'), findsOneWidget);
    });

    testWidgets('scans when it opens with nothing discovered', (tester) async {
      await pumpPage(tester);
      await tester.pump();
      await tester.pumpAndSettle(const Duration(milliseconds: 100));

      expect(mockService.scanCallCount, greaterThan(0));
    });

    testWidgets('does not scan when devices are already known', (tester) async {
      mockService.addDevice(TestScale(deviceId: 'a', name: 'Scale A'));
      await tester.pump();
      await pumpPage(tester);
      await tester.pump();
      await tester.pumpAndSettle(const Duration(milliseconds: 100));

      expect(mockService.scanCallCount, 0);
    });

    testWidgets('a scale taken for dosing is not offered for brewing', (
      tester,
    ) async {
      mockService.addDevice(TestScale(deviceId: 'brew', name: 'Brew Scale'));
      mockService.addDevice(TestScale(deviceId: 'dose', name: 'Dose Scale'));
      await settingsController.setDosingScaleId('dose');
      await pumpPage(tester);
      await tester.pump();

      // Named once, under Dosing Scale, and not under the brewing section.
      expect(find.text('Dose Scale'), findsOneWidget);
      // The brewing scale is offered in its own section, and again as a
      // candidate for dosing.
      expect(find.text('Brew Scale'), findsNWidgets(2));
    });

    testWidgets('with nothing reserved both scales are offered to brewing', (
      tester,
    ) async {
      mockService.addDevice(TestScale(deviceId: 'one', name: 'Scale One'));
      mockService.addDevice(TestScale(deviceId: 'two', name: 'Scale Two'));
      await pumpPage(tester);
      await tester.pump();

      expect(find.text('Scale One'), findsNWidgets(2));
      expect(find.text('Scale Two'), findsNWidgets(2));
    });
  });
}
