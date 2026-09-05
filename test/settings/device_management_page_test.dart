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

  DeviceInformation? _information;
  final BehaviorSubject<DeviceInformation?> _informationSubject;
  bool poweredByUsb = false;

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
      firmwareVersion: 'R029',
      batteryLevel: 82,
    );
    discovery.addDevice(first);

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
    final switchFinder = find.byType(SwitchListTile);
    expect(switchFinder, findsOneWidget);
    await tester.tap(switchFinder);
    await tester.pump();
    expect(settingsController.skalePoweredByUsb, isTrue);

    discovery.clear();
    final replacement = _InformationScale(
      deviceId: 'skale-device',
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
