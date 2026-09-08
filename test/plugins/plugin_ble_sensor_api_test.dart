import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/connection_manager.dart';
import 'package:reaprime/src/controllers/de1_controller.dart';
import 'package:reaprime/src/controllers/device_controller.dart';
import 'package:reaprime/src/controllers/scale_controller.dart';
import 'package:reaprime/src/controllers/sensor_controller.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/watch_filter.dart';
import 'package:reaprime/src/plugins/plugin_manager.dart';
import 'package:reaprime/src/services/universal_ble_discovery_service.dart';
import 'package:reaprime/src/services/webserver_service.dart';
import 'package:reaprime/src/settings/settings_controller.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_plus/shelf_plus.dart';
import 'package:universal_ble/universal_ble.dart';
import 'package:web_socket_channel/io.dart';

import '../helpers/mock_settings_service.dart';
import '../helpers/plugin_ble_fixture.dart';
import 'plugin_manager_ble_test.dart' show bleSensorSource, bleSensorManifest;
import 'plugin_test_helpers.dart';

void main() {
  test(
    'advertisement through JS protocol reaches existing Sensor REST and WS',
    () async {
      final platform = PluginBleFixturePlatform();
      UniversalBle.setInstance(platform);
      final manager = PluginManager(kvStore: FakeKeyValueStoreService());
      final transports = <PluginBleFixtureTransport>[];
      final discovery = UniversalBleDiscoveryService(
        watchSupportGate: () => true,
        pluginBleService: () => manager.bleService,
        transportFactory:
            ({
              required device,
              required stopScan,
              required requestLargeMtuNonAndroid,
              required lifecycleGate,
            }) {
              final transport = PluginBleFixtureTransport(device.deviceId);
              transports.add(transport);
              return transport;
            },
      );
      final devices = DeviceController([discovery]);
      await devices.initialize();
      final sensors = SensorController(controller: devices);
      final settings = SettingsController(MockSettingsService());
      await settings.loadSettings();
      final connections = ConnectionManager(
        deviceScanner: devices,
        de1Controller: De1Controller(controller: devices),
        scaleController: ScaleController(),
        settingsController: settings,
      );
      final router = Router().plus;
      SensorsHandler(controller: sensors).addRoutes(router);
      final devicesHandler = DevicesHandler(
        controller: devices,
        connectionManager: connections,
      );
      devicesHandler.addRoutes(router);
      final server = await shelf_io.serve(router.call, '127.0.0.1', 0);
      final client = HttpClient();
      IOWebSocketChannel? channel;
      addTearDown(() async {
        await channel?.sink.close();
        client.close(force: true);
        await discovery.dispose();
        await manager.dispose();
        devicesHandler.dispose();
        connections.dispose();
        sensors.dispose();
        devices.dispose();
        await server.close(force: true);
      });
      await manager.loadPlugin(
        id: 'ble.sensor',
        manifest: bleSensorManifest(),
        settings: {},
        jsCode: bleSensorSource,
      );
      await discovery.startDeviceWatch(const DeviceWatchFilter());
      final found = sensors.sensorRegistry.firstWhere((s) => s.isNotEmpty);
      platform.updateScanResult(
        BleDevice(deviceId: 'AA:BB', name: null, services: ['180f']),
      );
      final sensor = (await found.timeout(
        const Duration(seconds: 2),
      )).values.single;
      await sensor.connectionState
          .firstWhere((s) => s == ConnectionState.connected)
          .timeout(const Duration(seconds: 2));
      final origin = 'http://127.0.0.1:${server.port}';
      Future<dynamic> get(String path) async {
        final response = await (await client.getUrl(
          Uri.parse('$origin$path'),
        )).close();
        expect(response.statusCode, 200);
        return jsonDecode(await utf8.decoder.bind(response).join());
      }

      final inventory = await get('/api/v1/devices') as List;
      expect(inventory.single['id'], sensor.deviceId);
      expect(inventory.single['type'], 'sensor');
      final registry = await get('/api/v1/sensors') as List;
      expect(registry.single['id'], sensor.deviceId);
      expect(registry.single['info']['data'].single['key'], 'humidity');
      channel = IOWebSocketChannel.connect(
        Uri.parse(
          'ws://127.0.0.1:${server.port}/ws/v1/sensors/${sensor.deviceId}/snapshot',
        ),
      );
      await channel.ready;
      final snapshot = channel.stream.first;
      transports.single.subscribers.values.single(Uint8List.fromList([57]));
      expect(
        jsonDecode(
          await snapshot.timeout(const Duration(seconds: 2)) as String,
        ),
        {'humidity': 57},
      );
      final request = await client.postUrl(
        Uri.parse('$origin/api/v1/sensors/${sensor.deviceId}/execute'),
      );
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode({'commandId': 'sample', 'params': null}));
      final response = await request.close();
      expect(response.statusCode, 200);
      expect(jsonDecode(await utf8.decoder.bind(response).join()), {
        'status': 'ok',
        'result': {'humidity': 52},
      });
      expect(transports.single.writes.single.data, [1]);
      expect(transports.single.writes.single.withResponse, isTrue);
    },
  );
}
