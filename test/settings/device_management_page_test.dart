import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/device_controller.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/settings/device_management_page.dart';
import 'package:reaprime/src/settings/settings_controller.dart';
import 'package:rxdart/rxdart.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import '../helpers/mock_device_discovery_service.dart';
import '../helpers/mock_settings_service.dart';
import '../helpers/test_scale.dart';

class _InformationScale extends TestScale
    implements DeviceInformationCapable, UsbPowerConfigurable {
  _InformationScale({
    required super.deviceId,
    required this.scaleName,
    required String firmwareVersion,
    int? batteryLevel,
  }) : _information = DeviceInformation(
         firmwareVersion: firmwareVersion,
         batteryLevel: batteryLevel,
       ),
       _informationSubject = BehaviorSubject<DeviceInformation?>.seeded(
         DeviceInformation(
           firmwareVersion: firmwareVersion,
           batteryLevel: batteryLevel,
         ),
       );

  final String scaleName;
  DeviceInformation? _information;
  final BehaviorSubject<DeviceInformation?> _informationSubject;
  bool poweredByUsb = false;

  @override
  String get name => scaleName;

  @override
  Future<void> setUsbPowered(bool value) async {
    poweredByUsb = value;
  }

  @override
  DeviceInformation? get currentDeviceInformation => _information;

  @override
  Stream<DeviceInformation?> get deviceInformation =>
      _informationSubject.stream;

  void emitFirmware(String firmwareVersion) {
    _information = DeviceInformation(firmwareVersion: firmwareVersion);
    _informationSubject.add(_information);
  }
}

void main() {
  testWidgets('shows firmware and follows a same-ID replacement scale', (
    tester,
  ) async {
    final discovery = MockDeviceDiscoveryService();
    final settingsController = SettingsController(MockSettingsService());
    await settingsController.loadSettings();
    final deviceController = DeviceController([
      discovery,
    ], settingsController: settingsController);
    await deviceController.initialize();

    final first = _InformationScale(
      deviceId: 'skale-device',
      scaleName: 'Scale A',
      firmwareVersion: 'R029',
      batteryLevel: 82,
    );
    final second = _InformationScale(
      deviceId: 'other-skale-device',
      scaleName: 'Scale B',
      firmwareVersion: 'R028',
    );
    discovery.addDevice(first);
    discovery.addDevice(second);

    await tester.pumpWidget(
      ShadApp(
        home: DeviceManagementPage(
          settingsController: settingsController,
          deviceController: deviceController,
        ),
      ),
    );
    await tester.pump();

    expect(find.textContaining('Firmware: R029'), findsOneWidget);
    expect(
      find.textContaining('Battery: 82% (device-reported)'),
      findsOneWidget,
    );
    expect(find.text('Powered by USB'), findsNothing);
    expect(find.byTooltip('Configure Scale A'), findsOneWidget);
    expect(find.byTooltip('Configure Scale B'), findsOneWidget);
    await tester.tap(find.byTooltip('Configure Scale B'));
    await tester.pumpAndSettle();

    expect(find.text('Scale B settings'), findsOneWidget);
    final switchFinder = find.widgetWithText(SwitchListTile, 'Powered by USB');
    expect(switchFinder, findsOneWidget);
    await tester.tap(switchFinder);
    await tester.pump();
    expect(
      settingsController.isSkalePoweredByUsb('other-skale-device'),
      isTrue,
    );
    expect(settingsController.isSkalePoweredByUsb('skale-device'), isFalse);
    expect(second.poweredByUsb, isTrue);
    expect(first.poweredByUsb, isFalse);

    discovery.clear();
    final replacement = _InformationScale(
      deviceId: 'skale-device',
      scaleName: 'Scale A',
      firmwareVersion: 'R030',
    );
    discovery.addDevice(replacement);
    await tester.pump();
    await tester.pump();

    expect(find.textContaining('Firmware: R030'), findsOneWidget);

    replacement.emitFirmware('R031');
    await tester.pump();

    expect(find.textContaining('Firmware: R031'), findsOneWidget);

    first.emitFirmware('stale');
    await tester.pump();

    expect(find.textContaining('Firmware: R031'), findsOneWidget);
    expect(find.textContaining('Firmware: stale'), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    deviceController.dispose();
    discovery.dispose();
  });
}
