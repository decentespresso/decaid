import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shelf_plus/shelf_plus.dart';
import 'package:reaprime/src/controllers/connection_manager.dart';
import 'package:reaprime/src/controllers/de1_controller.dart';
import 'package:reaprime/src/controllers/device_controller.dart';
import 'package:reaprime/src/controllers/remembered_devices_controller.dart';
import 'package:reaprime/src/controllers/scale_controller.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/remembered_device.dart';
import 'package:reaprime/src/settings/settings_controller.dart';
import 'package:reaprime/src/services/webserver_service.dart';

import 'helpers/mock_device_discovery_service.dart';
import 'helpers/mock_settings_service.dart';

void main() {
  late DeviceController deviceController;
  late ConnectionManager connectionManager;
  late RememberedDevicesController remembered;
  late MockSettingsService settings;
  late StreamController<RememberedDevice?> machineConn;
  late StreamController<RememberedDevice?> scaleConn;
  late DevicesHandler devicesHandler;
  late Handler handler;

  setUp(() async {
    final mockDiscovery = MockDeviceDiscoveryService();
    deviceController = DeviceController([mockDiscovery]);
    await deviceController.initialize();

    final de1Controller = De1Controller(controller: deviceController);
    final scaleController = ScaleController();
    settings = MockSettingsService();
    // Seed one remembered device that is NOT currently present.
    await settings.setRememberedDevices(
      RememberedDevice.encodeList([
        const RememberedDevice(
          id: 'wifi:hds.local',
          name: 'Half Decent Scale (WiFi)',
          type: DeviceType.scale,
        ),
      ]),
    );

    final settingsController = SettingsController(settings);
    await settingsController.loadSettings();

    connectionManager = ConnectionManager(
      deviceScanner: deviceController,
      de1Controller: de1Controller,
      scaleController: scaleController,
      settingsController: settingsController,
    );

    machineConn = StreamController<RememberedDevice?>.broadcast();
    scaleConn = StreamController<RememberedDevice?>.broadcast();
    remembered = RememberedDevicesController(
      machineConnections: machineConn.stream,
      scaleConnections: scaleConn.stream,
      settings: settings,
    );
    await remembered.initialize();

    devicesHandler = DevicesHandler(
      controller: deviceController,
      connectionManager: connectionManager,
      rememberedController: remembered,
    );
    final app = Router().plus;
    devicesHandler.addRoutes(app);
    handler = app.call;
  });

  tearDown(() async {
    devicesHandler.dispose();
    connectionManager.dispose();
    deviceController.dispose();
    await remembered.dispose();
    await machineConn.close();
    await scaleConn.close();
  });

  Future<List<dynamic>> getDevices() async {
    final res = await handler(
      Request('GET', Uri.parse('http://localhost/api/v1/devices')),
    );
    return jsonDecode(await res.readAsString()) as List<dynamic>;
  }

  test('a remembered-absent device appears as available:false', () async {
    final devices = await getDevices();
    final hds = devices.firstWhere((d) => d['id'] == 'wifi:hds.local');
    expect(hds['available'], isFalse);
    expect(hds['state'], 'disconnected');
    expect(hds['type'], 'scale');
  });

  test('forget removes a remembered-absent device from the list', () async {
    expect(
      (await getDevices()).any((d) => d['id'] == 'wifi:hds.local'),
      isTrue,
    );

    final res = await handler(
      Request(
        'PUT',
        Uri.parse('http://localhost/api/v1/devices/forget'),
        body: jsonEncode({'deviceId': 'wifi:hds.local'}),
        headers: {'content-type': 'application/json'},
      ),
    );
    expect(res.statusCode, 200);

    expect(
      (await getDevices()).any((d) => d['id'] == 'wifi:hds.local'),
      isFalse,
    );
    expect(
      RememberedDevice.decodeList(await settings.rememberedDevices()),
      isEmpty,
    );
  });

  test('forget with missing deviceId is a bad request', () async {
    final res = await handler(
      Request('PUT', Uri.parse('http://localhost/api/v1/devices/forget')),
    );
    expect(res.statusCode, 400);
  });

  test('forget accepts deviceId via the query param (no body)', () async {
    final res = await handler(
      Request(
        'PUT',
        Uri.parse(
          'http://localhost/api/v1/devices/forget?deviceId=wifi:hds.local',
        ),
      ),
    );
    expect(res.statusCode, 200);
    expect(
      (await getDevices()).any((d) => d['id'] == 'wifi:hds.local'),
      isFalse,
    );
  });

  test('forget returns 503 when the remembered controller is unwired', () async {
    // A handler with no remembered controller — the feature is unavailable, not
    // a server fault, so it must be 503 (not 500).
    final bareHandler = DevicesHandler(
      controller: deviceController,
      connectionManager: connectionManager,
    );
    final app = Router().plus;
    bareHandler.addRoutes(app);
    final res = await app.call(
      Request(
        'PUT',
        Uri.parse('http://localhost/api/v1/devices/forget'),
        body: jsonEncode({'deviceId': 'x'}),
        headers: {'content-type': 'application/json'},
      ),
    );
    expect(res.statusCode, 503);
    bareHandler.dispose();
  });
}
