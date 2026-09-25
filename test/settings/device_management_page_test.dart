import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/device_controller.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/plugins/plugin_device_contract.dart';
import 'package:reaprime/src/settings/device_management_page.dart';
import 'package:reaprime/src/settings/settings_controller.dart';
import 'package:rxdart/rxdart.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import '../helpers/mock_device_discovery_service.dart';
import '../helpers/mock_settings_service.dart';
import '../helpers/test_scale.dart';

class _InformationScale extends TestScale implements DeviceInformationCapable {
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

class _SettingsScale extends _InformationScale
    implements DeviceSettingsCapable {
  _SettingsScale({required super.deviceId}) : super(firmwareVersion: 'R029');

  @override
  PluginDeviceSettings get deviceSettings => const PluginDeviceSettings(
    pluginId: 'test.plugin',
    endpointId: 'device-settings',
  );
}

class _InvalidSettingsScale extends _SettingsScale {
  _InvalidSettingsScale({required super.deviceId});

  @override
  PluginDeviceSettings get deviceSettings => const PluginDeviceSettings(
    pluginId: 'invalid/plugin',
    endpointId: 'device-settings',
  );
}

void main() {
  testWidgets('shows firmware and follows a same-ID replacement scale', (
    tester,
  ) async {
    final discovery = MockDeviceDiscoveryService();
    final deviceController = DeviceController([discovery]);
    await deviceController.initialize();
    final settingsController = SettingsController(MockSettingsService());
    await settingsController.loadSettings();

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

  testWidgets('opens settings for an eligible plugin device', (tester) async {
    final discovery = MockDeviceDiscoveryService();
    final deviceController = DeviceController([discovery]);
    await deviceController.initialize();
    final settingsController = SettingsController(MockSettingsService());
    await settingsController.loadSettings();
    final device = _SettingsScale(deviceId: 'plugin:test.plugin:scale:one');
    discovery.addDevice(device);
    Uri? launched;

    await tester.pumpWidget(
      ShadApp(
        home: DeviceManagementPage(
          settingsController: settingsController,
          deviceController: deviceController,
          settingsLauncher: (uri) async {
            launched = uri;
            return true;
          },
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.byTooltip('Device settings'));
    expect(launched?.queryParameters['deviceId'], device.deviceId);
    expect(launched?.queryParameters['ui'], '1');

    await tester.pumpWidget(const SizedBox.shrink());
    deviceController.dispose();
    discovery.dispose();
  });

  testWidgets('shows a launch failure', (tester) async {
    final discovery = MockDeviceDiscoveryService();
    final deviceController = DeviceController([discovery]);
    await deviceController.initialize();
    final settingsController = SettingsController(MockSettingsService());
    await settingsController.loadSettings();
    discovery.addDevice(
      _SettingsScale(deviceId: 'plugin:test.plugin:scale:one'),
    );

    await tester.pumpWidget(
      ShadApp(
        home: ScaffoldMessenger(
          child: DeviceManagementPage(
            settingsController: settingsController,
            deviceController: deviceController,
            settingsLauncher: (_) async => false,
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.byTooltip('Device settings'));
    await tester.pump();
    expect(find.text('Unable to open device settings.'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    deviceController.dispose();
    discovery.dispose();
  });

  testWidgets('shows a URI construction failure', (tester) async {
    final discovery = MockDeviceDiscoveryService();
    final deviceController = DeviceController([discovery]);
    await deviceController.initialize();
    final settingsController = SettingsController(MockSettingsService());
    await settingsController.loadSettings();
    discovery.addDevice(
      _InvalidSettingsScale(deviceId: 'plugin:test.plugin:scale:one'),
    );

    await tester.pumpWidget(
      ShadApp(
        home: ScaffoldMessenger(
          child: DeviceManagementPage(
            settingsController: settingsController,
            deviceController: deviceController,
            settingsLauncher: (_) async => true,
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.byTooltip('Device settings'));
    await tester.pump();
    expect(find.text('Unable to open device settings.'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    deviceController.dispose();
    discovery.dispose();
  });
}
