import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/device_controller.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/plugins/plugin_device_service.dart';
import 'package:reaprime/src/plugins/plugin_manifest.dart';
import 'package:reaprime/src/plugins/plugin_scale.dart';
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

Future<void> registerSettingsDevice(
  PluginDeviceService service, {
  required String handle,
  required PluginDriverType type,
  String? role = 'settings',
}) => service.register(
  pluginId: 'test.plugin',
  generation: 1,
  registrationHandle: handle,
  definition: {
    'driverId': type.name,
    'instanceId': handle,
    'name': '$handle name',
    'vendor': 'Test',
    'dataChannels': [
      {'key': 'value', 'type': 'number'},
    ],
    'commands': <dynamic>[],
  },
  driver: PluginDriverDeclaration(
    id: type.name,
    type: type,
    surfaces: role == null
        ? const []
        : [
            PluginDeviceSurface(
              id: 'panel',
              role: role,
              endpoint: 'device-settings',
            ),
          ],
  ),
  invoke: (_, _) async => const {},
);

void main() {
  testWidgets('launches the authority href with opaque IDs encoded once', (
    tester,
  ) async {
    final discovery = MockDeviceDiscoveryService();
    final controller = DeviceController([discovery]);
    await controller.initialize();
    final settings = SettingsController(MockSettingsService());
    await settings.loadSettings();
    const deviceId = 'not-the-owner:%2F +?&/設定';
    const endpoint = 'panel%2F +設定';
    const deviceName = 'Opaque:%2F +?&/設定';
    final device = PluginScale(
      deviceId: deviceId,
      name: deviceName,
      pluginId: 'explicit.owner',
      capabilities: const {},
      surfaces: const [
        PluginDeviceSurface(id: 'panel', role: 'settings', endpoint: endpoint),
      ],
      invoke: (_, _) async => const {},
    );
    discovery.addDevice(device);
    final launched = <Uri>[];
    await tester.pumpWidget(
      ShadApp(
        home: DeviceManagementPage(
          settingsController: settings,
          deviceController: controller,
          settingsLauncher: (uri) async {
            launched.add(uri);
            return true;
          },
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.byTooltip('Device settings'));
    await tester.pump();
    expect(
      launched.single.toString(),
      'http://localhost:8080/api/v1/plugins/explicit.owner/panel%252F%20+%E8%A8%AD%E5%AE%9A'
      '?ui=1&deviceId=not-the-owner%3A%252F+%2B%3F%26%2F%E8%A8%AD%E5%AE%9A'
      '&deviceName=Opaque%3A%252F+%2B%3F%26%2F%E8%A8%AD%E5%AE%9A',
    );
    expect(launched.single.queryParameters, {
      'ui': '1',
      'deviceId': deviceId,
      'deviceName': deviceName,
    });
    expect(
      launched.single.toString(),
      Uri.parse('http://localhost:8080')
          .resolve(
            device.surfaceAuthority!
                .resolve(deviceId, deviceName: deviceName)
                .single['href']!,
          )
          .toString(),
    );
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
    discovery.dispose();
    await device.dispose();
  });

  testWidgets('opens independent Scale, Sensor and Grinder settings', (
    tester,
  ) async {
    final service = PluginDeviceService();
    final nativeDiscovery = MockDeviceDiscoveryService();
    final controller = DeviceController([service, nativeDiscovery]);
    await controller.initialize();
    final settings = SettingsController(MockSettingsService());
    await settings.loadSettings();
    for (final (handle, type) in [
      ('one', PluginDriverType.scale),
      ('two', PluginDriverType.scale),
      ('sensor', PluginDriverType.sensor),
      ('grinder', PluginDriverType.grinder),
    ]) {
      await registerSettingsDevice(service, handle: handle, type: type);
    }
    await registerSettingsDevice(
      service,
      handle: 'plain',
      type: PluginDriverType.grinder,
      role: null,
    );
    await registerSettingsDevice(
      service,
      handle: 'diagnostics',
      type: PluginDriverType.sensor,
      role: 'diagnostics',
    );
    nativeDiscovery.addDevice(TestScale(deviceId: 'native'));
    final launched = <Uri>[];
    await tester.pumpWidget(
      ShadApp(
        home: ScaffoldMessenger(
          child: DeviceManagementPage(
            settingsController: settings,
            deviceController: controller,
            settingsLauncher: (uri) async {
              launched.add(uri);
              return true;
            },
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.byTooltip('Device settings'), findsNWidgets(4));
    for (var index = 0; index < 4; index++) {
      final action = find.byTooltip('Device settings').at(index);
      await tester.ensureVisible(action);
      await tester.pump();
      await tester.tap(action);
      await tester.pump();
    }
    expect(launched.map((uri) => uri.queryParameters['deviceId']).toSet(), {
      'plugin:test.plugin:scale:one',
      'plugin:test.plugin:scale:two',
      'plugin:test.plugin:sensor:sensor',
      'plugin:test.plugin:grinder:grinder',
    });
    expect(find.text('Auto-connect Grinder'), findsOneWidget);
    for (final uri in launched) {
      final deviceId = uri.queryParameters['deviceId']!;
      final deviceName = controller.devices
          .singleWhere((device) => device.deviceId == deviceId)
          .name;
      expect(uri.queryParameters['deviceName'], deviceName);
      expect(
        uri.toString(),
        'http://localhost:8080/api/v1/plugins/test.plugin/device-settings'
        '?ui=1&deviceId=${Uri.encodeQueryComponent(deviceId)}'
        '&deviceName=${Uri.encodeQueryComponent(deviceName)}',
      );
      expect(
        uri.queryParameters.keys,
        unorderedEquals(['ui', 'deviceId', 'deviceName']),
      );
    }
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
    service.dispose();
    nativeDiscovery.dispose();
  });

  testWidgets('retired and unloaded device callbacks refuse launch', (
    tester,
  ) async {
    final service = PluginDeviceService();
    final controller = DeviceController([service]);
    await controller.initialize();
    final settings = SettingsController(MockSettingsService());
    await settings.loadSettings();
    await registerSettingsDevice(
      service,
      handle: 'one',
      type: PluginDriverType.scale,
    );
    var launchCount = 0;
    await tester.pumpWidget(
      ShadApp(
        home: ScaffoldMessenger(
          child: DeviceManagementPage(
            settingsController: settings,
            deviceController: controller,
            settingsLauncher: (_) async {
              launchCount++;
              return true;
            },
          ),
        ),
      ),
    );
    await tester.pump();
    final retiredAction = tester
        .widget<IconButton>(
          find.widgetWithIcon(IconButton, Icons.settings_outlined),
        )
        .onPressed!;
    await service.unregister(
      pluginId: 'test.plugin',
      generation: 1,
      registrationHandle: 'one',
    );
    await tester.pump();
    expect(controller.devices, isEmpty);
    await registerSettingsDevice(
      service,
      handle: 'one',
      type: PluginDriverType.scale,
    );
    await tester.pump();
    retiredAction();
    await tester.pump();
    expect(launchCount, 0);
    expect(find.text('Unable to open device settings.'), findsOneWidget);
    ScaffoldMessenger.of(
      tester.element(find.byType(DeviceManagementPage)),
    ).removeCurrentSnackBar();
    await tester.pumpAndSettle();
    expect(find.text('Unable to open device settings.'), findsNothing);
    await service.unregister(
      pluginId: 'test.plugin',
      generation: 1,
      registrationHandle: 'one',
    );
    await registerSettingsDevice(
      service,
      handle: 'two',
      type: PluginDriverType.grinder,
    );
    await tester.pump();
    final unloadedAction = tester
        .widget<IconButton>(
          find.widgetWithIcon(IconButton, Icons.settings_outlined),
        )
        .onPressed!;
    await service.removeAllForPlugin('test.plugin', 1);
    await tester.pump();
    expect(controller.devices, isEmpty);
    unloadedAction();
    await tester.pump();
    expect(launchCount, 0);
    expect(find.text('Unable to open device settings.'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
    service.dispose();
  });

  testWidgets('browser refusal and exception show an error', (tester) async {
    final service = PluginDeviceService();
    final controller = DeviceController([service]);
    await controller.initialize();
    final settings = SettingsController(MockSettingsService());
    await settings.loadSettings();
    await registerSettingsDevice(
      service,
      handle: 'one',
      type: PluginDriverType.scale,
    );
    var throwOnLaunch = false;
    await tester.pumpWidget(
      ShadApp(
        home: ScaffoldMessenger(
          child: DeviceManagementPage(
            settingsController: settings,
            deviceController: controller,
            settingsLauncher: (_) async {
              if (throwOnLaunch) throw StateError('browser unavailable');
              return false;
            },
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.byTooltip('Device settings'));
    await tester.pump();
    expect(find.text('Unable to open device settings.'), findsOneWidget);
    ScaffoldMessenger.of(
      tester.element(find.byType(DeviceManagementPage)),
    ).removeCurrentSnackBar();
    await tester.pumpAndSettle();
    expect(find.text('Unable to open device settings.'), findsNothing);
    throwOnLaunch = true;
    await tester.tap(find.byTooltip('Device settings'));
    await tester.pump();
    expect(find.text('Unable to open device settings.'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
    service.dispose();
  });
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
}
