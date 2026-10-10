import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart' hide Router;
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/device_controller.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/plugins/plugin_device_service.dart';
import 'package:reaprime/src/plugins/plugin_loader_service.dart';
import 'package:reaprime/src/plugins/plugin_manager.dart';
import 'package:reaprime/src/plugins/plugin_manifest.dart';
import 'package:reaprime/src/plugins/plugin_scale.dart';
import 'package:reaprime/src/settings/device_management_page.dart';
import 'package:reaprime/src/settings/settings_controller.dart';
import 'package:reaprime/src/services/webserver_service.dart';
import 'package:rxdart/rxdart.dart';
import 'package:shelf_plus/shelf_plus.dart' hide Response;
import 'package:shadcn_ui/shadcn_ui.dart';

import '../helpers/mock_device_discovery_service.dart';
import '../helpers/mock_settings_service.dart';
import '../helpers/test_scale.dart';
import '../plugins/plugin_test_helpers.dart';

class _UnusedPluginLoaderService extends Fake implements PluginLoaderService {}

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
          isPluginRuntimeActive: (id) => id == 'explicit.owner',
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
            isPluginRuntimeActive: (id) => id == 'test.plugin',
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
    await tester.ensureVisible(find.text('grinder name'));
    await tester.tap(find.text('grinder name'));
    await tester.pumpAndSettle();
    expect(
      settings.preferredGrinderDeviceId,
      'plugin:test.plugin:grinder:grinder',
    );
    final grinderSection = find.ancestor(
      of: find.text('Auto-connect Grinder'),
      matching: find.byType(ShadCard),
    );
    final clearGrinder = find.descendant(
      of: grinderSection,
      matching: find.text('None'),
    );
    await tester.ensureVisible(clearGrinder);
    await tester.tap(clearGrinder);
    await tester.pumpAndSettle();
    expect(settings.preferredGrinderDeviceId, isNull);
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
            isPluginRuntimeActive: (id) => id == 'test.plugin',
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

  testWidgets('refuses settings while plugin unload awaits disconnect', (
    tester,
  ) async {
    const fixture = 'test/fixtures/plugins/plugin-device-settings.reaplugin';
    final manifest = PluginManifest.fromJson(
      jsonDecode(File('$fixture/manifest.json').readAsStringSync()),
    );
    final manager = PluginManager(kvStore: FakeKeyValueStoreService());
    final controller = DeviceController([manager.deviceService]);
    await controller.initialize();
    final settings = SettingsController(MockSettingsService());
    await settings.loadSettings();
    await manager.loadPlugin(
      id: manifest.id,
      manifest: manifest,
      settings: {},
      jsCode: File('$fixture/plugin.js').readAsStringSync(),
    );
    final disconnect = Completer<void>();
    var disconnectStarted = false;
    await manager.deviceService.register(
      pluginId: manifest.id,
      generation: 1,
      registrationHandle: 'one',
      definition: {
        'driverId': manifest.drivers.single.id,
        'instanceId': 'one',
        'name': 'Delayed sensor',
        'vendor': 'Mock',
        'dataChannels': [
          {'key': 'value', 'type': 'number'},
        ],
      },
      driver: manifest.drivers.single,
      invoke: (operation, _) async {
        if (operation == PluginDeviceOperation.disconnect) {
          disconnectStarted = true;
          await disconnect.future;
        }
        return const {};
      },
    );
    final app = Router().plus;
    PluginsHandler(
      pluginManager: manager,
      pluginService: _UnusedPluginLoaderService(),
    ).addRoutes(app);
    var launchCount = 0;
    var httpRequestCount = 0;
    int? httpStatus;
    await tester.pumpWidget(
      ShadApp(
        home: ScaffoldMessenger(
          child: DeviceManagementPage(
            settingsController: settings,
            deviceController: controller,
            isPluginRuntimeActive: manager.isPluginRuntimeActive,
            settingsLauncher: (uri) async {
              launchCount++;
              httpRequestCount++;
              final response = await app.call(Request('GET', uri));
              httpStatus = response.statusCode;
              return true;
            },
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.byTooltip('Device settings'), findsOneWidget);
    await tester.ensureVisible(find.byTooltip('Device settings'));
    await tester.pumpAndSettle();
    var unloadComplete = false;
    final unload = manager.unloadPlugin(manifest.id).then((_) {
      unloadComplete = true;
    });
    unawaited(unload);
    try {
      await tester.pump();
      expect(disconnectStarted, isTrue);
      expect(manager.isPluginRuntimeActive(manifest.id), isFalse);
      expect(unloadComplete, isFalse);
      expect(controller.devices, hasLength(1));
      await tester.tap(find.byTooltip('Device settings'));
      await tester.pump();
      expect(launchCount, 0, reason: 'retiring runtime must refuse launch');
      expect(httpRequestCount, 0);
      expect(httpStatus, isNull);
      expect(find.text('Unable to open device settings.'), findsOneWidget);
      settings.notifyListeners();
      await tester.pump();
      expect(find.byTooltip('Device settings'), findsNothing);
    } finally {
      disconnect.complete();
      await unload;
      await tester.pumpAndSettle();
      expect(unloadComplete, isTrue);
      expect(controller.devices, isEmpty);
      expect(manager.activePendingOpCount, 0);
      expect(manager.activeTimerCount, 0);
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
      await manager.dispose();
    }
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
            isPluginRuntimeActive: (id) => id == 'test.plugin',
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
          isPluginRuntimeActive: (_) => false,
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
