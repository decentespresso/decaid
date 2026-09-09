import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/connection_manager.dart';
import 'package:reaprime/src/controllers/de1_controller.dart';
import 'package:reaprime/src/controllers/device_controller.dart';
import 'package:reaprime/src/controllers/scale_controller.dart';
import 'package:reaprime/src/models/device/scale.dart';
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
  for (final timers in [true, false]) {
    test(
      'public non-BLE Scale REST/WS and reload with timers=$timers',
      () async {
        final manager = PluginManager(kvStore: FakeKeyValueStoreService());
        final devices = DeviceController([manager.deviceService]);
        await devices.initialize();
        final scales = ScaleController();
        final de1 = De1Controller(controller: devices);
        final settings = SettingsController(MockSettingsService());
        await settings.loadSettings();
        final connections = ConnectionManager(
          deviceScanner: devices,
          de1Controller: de1,
          scaleController: scales,
          settingsController: settings,
        );
        final router = Router().plus;
        ScaleHandler(
          controller: scales,
          de1Controller: de1,
          settingsController: settings,
        ).addRoutes(router);
        final inventory = DevicesHandler(
          controller: devices,
          connectionManager: connections,
        );
        inventory.addRoutes(router);
        final server = await shelf_io.serve(router.call, '127.0.0.1', 0);
        final client = HttpClient();
        final channel = IOWebSocketChannel.connect(
          Uri.parse('ws://127.0.0.1:${server.port}/ws/v1/scale/snapshot'),
        );
        final messages = <Map<String, dynamic>>[];
        final subscription = channel.stream.listen(
          (data) => messages.add(jsonDecode(data as String)),
        );
        addTearDown(() async {
          await channel.sink.close();
          await subscription.cancel();
          client.close(force: true);
          await manager.dispose();
          inventory.dispose();
          connections.dispose();
          scales.dispose();
          devices.dispose();
          await server.close(force: true);
        });
        await channel.ready;
        Future<dynamic> request(
          String method,
          String path, {
          int status = 200,
        }) async {
          final response = await (await client.openUrl(
            method,
            Uri.parse('http://127.0.0.1:${server.port}$path'),
          )).close();
          expect(response.statusCode, status);
          return jsonDecode(await utf8.decoder.bind(response).join());
        }

        Future<void> load() => manager.loadPlugin(
          id: 'api.scale',
          manifest: testManifest(
            'api.scale',
            permissions: {PluginPermissions.emit},
            drivers: [
              PluginDriverDeclaration(
                id: 'scale',
                type: PluginDriverType.scale,
                capabilities: {
                  if (timers) PluginScaleCapability.tare,
                  if (timers) PluginScaleCapability.timerControl,
                },
              ),
            ],
          ),
          settings: {},
          jsCode:
              '''
          function createPlugin(host) {
            let context;
            return {id: 'api.scale', async onLoad() {
              await host.devices.register({driverId:'scale', instanceId:'one', name:'API Scale'}, {
                async connect(session) { context = session; await session.publish({weight:12.5}); },
                disconnect() {},
                ${timers ? 'async tare() { await context.publish({weight:0}); },' : ''}
                ${timers ? "startTimer() {host.emit('timer','start');}, stopTimer() {host.emit('timer','stop');}, resetTimer() {host.emit('timer','reset');}," : ''}
              });
            }};
          }
        ''',
        );
        String? publicId;
        for (var generation = 0; generation < 2; generation++) {
          await load();
          final scale =
              (await manager.deviceService.devices.firstWhere(
                    (list) => list.isNotEmpty,
                  )).single
                  as Scale;
          publicId ??= scale.deviceId;
          expect(scale.deviceId, publicId);
          final first = scales.weightSnapshot.first;
          await connections.connect(scaleOnly: true);
          expect((await first).weight, 12.5);
          expect(scales.lastConnectedDeviceId, publicId);
          expect(settings.preferredScaleId, publicId);
          final listed = await request('GET', '/api/v1/devices') as List;
          expect(listed.single['id'], publicId);
          expect(listed.single['type'], 'scale');
          final tare = await request(
            'PUT',
            '/api/v1/scale/tare',
            status: timers ? 200 : 500,
          );
          if (!timers) expect(tare['code'], 'unsupported_operation');
          for (final operation in ['start', 'stop', 'reset']) {
            final event = timers
                ? manager.emitStream.firstWhere((e) => e['event'] == 'timer')
                : null;
            final result = await request(
              'PUT',
              '/api/v1/scale/timer/$operation',
              status: timers ? 200 : 500,
            );
            if (timers) {
              expect((await event!)['payload'], operation);
            } else {
              expect(result['code'], 'unsupported_operation');
            }
          }
          await Future<void>.delayed(const Duration(milliseconds: 20));
          if (timers) {
            expect(
              messages.any((m) => m['weight'] == 0 && m['battery'] == null),
              isTrue,
            );
          }
          await manager.unloadPlugin('api.scale');
        }
      },
    );
  }
}
