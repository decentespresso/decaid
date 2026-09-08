import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/device_controller.dart';
import 'package:reaprime/src/models/device/scale.dart';
import 'package:reaprime/src/settings/device_management_page.dart';
import 'package:reaprime/src/settings/settings_controller.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import '../helpers/mock_device_discovery_service.dart';
import '../helpers/mock_settings_service.dart';
import '../helpers/test_scale.dart';

class _ButtonScale extends TestScale implements ScaleButtonCapable {
  _ButtonScale({required super.deviceId, required super.name});

  @override
  Stream<ScaleButton> get buttonPresses => const Stream.empty();
}

void main() {
  testWidgets('each capable scale has an independent button setting', (
    tester,
  ) async {
    final settings = SettingsController(MockSettingsService());
    await settings.loadSettings();
    final discovery = MockDeviceDiscoveryService();
    final devices = DeviceController([discovery]);
    await devices.initialize();
    discovery.addDevice(_ButtonScale(deviceId: 'scale-a', name: 'Skale A'));
    discovery.addDevice(_ButtonScale(deviceId: 'scale-b', name: 'Skale B'));

    await tester.pumpWidget(
      ShadApp(
        builder: (_, child) => ScaffoldMessenger(child: child!),
        home: Scaffold(
          body: DeviceManagementPage(
            settingsController: settings,
            deviceController: devices,
          ),
        ),
      ),
    );

    expect(settings.scaleButtonStartsEspressoByDevice, isEmpty);
    expect(find.text('Square button controls espresso'), findsNothing);
    expect(find.byTooltip('Configure Skale A'), findsOneWidget);
    expect(find.byTooltip('Configure Skale B'), findsOneWidget);

    await tester.tap(find.byTooltip('Configure Skale A'));
    await tester.pumpAndSettle();

    expect(find.text('Skale A settings'), findsOneWidget);
    final toggle = find.widgetWithText(
      SwitchListTile,
      'Square button controls espresso',
    );
    expect(toggle, findsOneWidget);
    await tester.tap(toggle);
    await tester.pump();
    expect(settings.scaleButtonStartsEspressoByDevice, {'scale-a': true});

    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Configure Skale B'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<SwitchListTile>(
            find.widgetWithText(
              SwitchListTile,
              'Square button controls espresso',
            ),
          )
          .value,
      isFalse,
    );
    await tester.tap(
      find.widgetWithText(SwitchListTile, 'Square button controls espresso'),
    );
    await tester.pump();
    expect(settings.scaleButtonStartsEspressoByDevice, {
      'scale-a': true,
      'scale-b': true,
    });

    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Configure Skale A'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.widgetWithText(SwitchListTile, 'Square button controls espresso'),
    );
    await tester.pump();
    expect(settings.scaleButtonStartsEspressoByDevice, {'scale-b': true});

    devices.dispose();
    discovery.dispose();
    settings.dispose();
  });
}
