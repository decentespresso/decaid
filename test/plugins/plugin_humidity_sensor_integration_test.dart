import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/connection_manager.dart';
import 'package:reaprime/src/controllers/de1_controller.dart';
import 'package:reaprime/src/controllers/device_controller.dart';
import 'package:reaprime/src/controllers/scale_controller.dart';
import 'package:reaprime/src/controllers/sensor_controller.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/plugins/plugin_device_service.dart';
import 'package:reaprime/src/plugins/plugin_manager.dart';
import 'package:reaprime/src/plugins/plugin_manifest.dart';
import 'package:reaprime/src/services/webserver_service.dart';
import 'package:reaprime/src/settings/settings_controller.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_plus/shelf_plus.dart';
import 'package:web_socket_channel/io.dart';

import '../helpers/mock_settings_service.dart';
import 'plugin_test_helpers.dart';

void main() {
  test('WebSocket humidity plugin is exposed through the Sensor API', () async {
    final humidityServer = await _startHumidityServer();
    final deviceService = PluginDeviceService();
    final deviceController = DeviceController([deviceService]);
    await deviceController.initialize();
    final sensorController = SensorController(controller: deviceController);
    final settingsController = SettingsController(MockSettingsService());
    await settingsController.loadSettings();
    final connectionManager = ConnectionManager(
      deviceScanner: deviceController,
      de1Controller: De1Controller(controller: deviceController),
      scaleController: ScaleController(),
      settingsController: settingsController,
    );
    final manager = PluginManager(
      kvStore: FakeKeyValueStoreService(),
      deviceService: deviceService,
    );
    final app = Router().plus;
    SensorsHandler(controller: sensorController).addRoutes(app);
    final devicesHandler = DevicesHandler(
      controller: deviceController,
      connectionManager: connectionManager,
    );
    devicesHandler.addRoutes(app);
    final apiServer = await shelf_io.serve(app.call, '127.0.0.1', 0);
    final client = HttpClient();
    IOWebSocketChannel? snapshotChannel;
    addTearDown(() async {
      try {
        await snapshotChannel?.sink.close();
      } catch (_) {}
      client.close(force: true);
      await manager.dispose();
      devicesHandler.dispose();
      connectionManager.dispose();
      sensorController.dispose();
      deviceController.dispose();
      await apiServer.close(force: true);
      await humidityServer.close(force: true);
    });

    final registered = manager.emitStream
        .where((event) => event['event'] == 'registered')
        .map((event) => event['payload'] as String)
        .first;
    await manager.loadPlugin(
      id: 'humidity.plugin',
      manifest: testManifest(
        'humidity.plugin',
        permissions: const {
          PluginPermissions.emit,
          PluginPermissions.networkWebsocket,
        },
        drivers: const [
          PluginDriverDeclaration(
            id: 'humidity',
            type: PluginDriverType.sensor,
          ),
        ],
      ),
      settings: const {},
      jsCode:
          '''
        function createPlugin(host) {
          let device;
          let transportHandle;
          let pendingSample;
          return {
            id: "humidity.plugin",
            onLoad() {
              host.devices.register({
                driverId: "humidity",
                instanceId: "office",
                name: "Office humidity",
                vendor: "Test",
                dataChannels: [
                  { key: "relativeHumidity", type: "number", unit: "%RH" }
                ],
                commands: [{
                  id: "sampleNow",
                  resultsSchema: {
                    type: "object",
                    properties: { relativeHumidity: { type: "number" } }
                  }
                }]
              }, {
                connect(transport) {
                  return transport.open({
                    kind: "websocket",
                    url: "ws://127.0.0.1:${humidityServer.port}/sensor"
                  }).then((opened) => {
                    transportHandle = opened.handle;
                    host.transport.onEvent(transportHandle, (event) => {
                      if (event.type !== "data" || event.dataType !== "text") return;
                      const sample = JSON.parse(event.data);
                      device.publish({ relativeHumidity: sample.relativeHumidity });
                      if (pendingSample) {
                        pendingSample.resolve({ relativeHumidity: sample.relativeHumidity });
                        pendingSample = null;
                      }
                    });
                  });
                },
                disconnect() {
                  return transportHandle
                    ? host.transport.close(transportHandle)
                    : Promise.resolve();
                },
                execute(command) {
                  if (command.commandId !== "sampleNow") {
                    return Promise.reject(new Error("unknown command"));
                  }
                  return new Promise((resolve, reject) => {
                    pendingSample = { resolve: resolve, reject: reject };
                    host.transport.send(transportHandle, {
                      type: "text",
                      data: JSON.stringify({ command: "sampleNow" })
                    }).catch((error) => {
                      pendingSample = null;
                      reject(error);
                    });
                  });
                }
              }).then((registeredDevice) => {
                device = registeredDevice;
                host.emit("registered", device.deviceId);
              });
            }
          };
        }
      ''',
    );

    final deviceId = await registered.timeout(const Duration(seconds: 2));
    final sensor = await sensorController.sensorRegistry
        .map((sensors) => sensors[deviceId])
        .where((sensor) => sensor != null)
        .first;
    await sensor!.connectionState
        .where((state) => state == ConnectionState.connected)
        .first
        .timeout(const Duration(seconds: 2));

    final devicesResponse = await _get(
      client,
      Uri.parse('http://127.0.0.1:${apiServer.port}/api/v1/devices'),
    );
    expect(devicesResponse.single['id'], deviceId);
    expect(devicesResponse.single['type'], 'sensor');

    final sensorsResponse = await _get(
      client,
      Uri.parse('http://127.0.0.1:${apiServer.port}/api/v1/sensors'),
    );
    expect(sensorsResponse.single['id'], deviceId);
    expect(sensorsResponse.single['info']['data'].single, {
      'key': 'relativeHumidity',
      'type': 'number',
      'unit': '%RH',
    });
    expect(sensorsResponse.single['info']['commands'].single['resultsSchema'], {
      'type': 'object',
      'properties': {
        'relativeHumidity': {'type': 'number'},
      },
    });

    snapshotChannel = IOWebSocketChannel.connect(
      Uri.parse(
        'ws://127.0.0.1:${apiServer.port}/ws/v1/sensors/'
        '$deviceId/snapshot',
      ),
    );
    final snapshot = snapshotChannel.stream.first;
    final commandResponse = await _post(
      client,
      Uri.parse(
        'http://127.0.0.1:${apiServer.port}/api/v1/sensors/'
        '$deviceId/execute',
      ),
      {'commandId': 'sampleNow', 'params': null},
    );

    expect(commandResponse, {
      'status': 'ok',
      'result': {'relativeHumidity': 52.4},
    });
    expect(jsonDecode(await snapshot as String), {'relativeHumidity': 52.4});
  });
}

Future<HttpServer> _startHumidityServer() async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    if (!WebSocketTransformer.isUpgradeRequest(request)) {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }
    final socket = await WebSocketTransformer.upgrade(request);
    socket.listen((message) {
      final command = jsonDecode(message as String) as Map<String, dynamic>;
      if (command['command'] == 'sampleNow') {
        socket.add(jsonEncode({'relativeHumidity': 52.4}));
      }
    });
  });
  return server;
}

Future<List<dynamic>> _get(HttpClient client, Uri uri) async {
  final response = await (await client.getUrl(uri)).close();
  return jsonDecode(await utf8.decoder.bind(response).join()) as List<dynamic>;
}

Future<Map<String, dynamic>> _post(
  HttpClient client,
  Uri uri,
  Map<String, dynamic> body,
) async {
  final request = await client.postUrl(uri);
  request.headers.contentType = ContentType.json;
  request.write(jsonEncode(body));
  final response = await request.close();
  return jsonDecode(await utf8.decoder.bind(response).join())
      as Map<String, dynamic>;
}
