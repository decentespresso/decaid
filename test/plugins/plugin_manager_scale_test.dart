import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/scale_controller.dart';
import 'package:reaprime/src/models/device/scale.dart';
import 'package:reaprime/src/plugins/plugin_device_service.dart';
import 'package:reaprime/src/plugins/plugin_manager.dart';
import 'package:reaprime/src/plugins/plugin_manifest.dart';

import 'plugin_test_helpers.dart';

void main() {
  test(
    'retiring a suspended Scale connect rejects late transport opens',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final sockets = <WebSocket>[];
      server.listen((request) async {
        sockets.add(await WebSocketTransformer.upgrade(request));
      });
      final manager = PluginManager(kvStore: FakeKeyValueStoreService());
      addTearDown(() async {
        await manager.dispose();
        for (final socket in sockets) {
          await socket.close();
        }
        await server.close(force: true);
      });
      final registered = manager.emitStream
          .where((e) => e['event'] == 'registered')
          .first;
      final suspended = manager.emitStream
          .where((e) => e['event'] == 'suspended')
          .first;
      final rejected = manager.emitStream
          .where((e) => e['event'] == 'rejected')
          .first;
      await manager.loadPlugin(
        id: 'retiring.scale',
        manifest: testManifest(
          'retiring.scale',
          permissions: {
            PluginPermissions.emit,
            PluginPermissions.networkWebsocket,
          },
          drivers: const [
            PluginDriverDeclaration(id: 'scale', type: PluginDriverType.scale),
          ],
        ),
        settings: {},
        jsCode:
            '''
        function createPlugin(host) {
          return {id: "retiring.scale", onLoad() {
            return host.devices.register({driverId: "scale", instanceId: "one", name: "Scale"}, {
              async connect(context) {
                const options = {kind: "websocket", url: "ws://127.0.0.1:${server.port}/"};
                await context.transport.open(options);
                await new Promise(resolve => {
                  globalThis.resumeScale = resolve;
                  host.emit("suspended", true);
                });
                try {
                  await context.transport.open(options);
                  host.emit("rejected", false);
                } catch (error) { host.emit("rejected", true); }
              },
              disconnect() {}
            }).then(() => host.emit("registered", true));
          }};
        }
      ''',
      );
      await registered.timeout(const Duration(seconds: 2));
      final scale = (await manager.deviceService.devices.first).single as Scale;
      final connecting = expectLater(
        scale.onConnect(),
        throwsA(isA<PluginDeviceException>()),
      );
      await suspended.timeout(const Duration(seconds: 2));
      expect(manager.liveTransportCount, 1);
      await scale.disconnect();
      await connecting;
      manager.js.evaluate('globalThis.resumeScale()');
      while (manager.js.executePendingJob() > 0) {}
      expect(
        (await rejected.timeout(const Duration(seconds: 2)))['payload'],
        true,
      );
      expect(manager.liveTransportCount, 0);
    },
  );

  test(
    'direct Scale registration cannot omit a declared command handler',
    () async {
      final manager = PluginManager(kvStore: FakeKeyValueStoreService());
      addTearDown(manager.dispose);
      final rejected = manager.emitStream
          .where((event) => event['event'] == 'rejected')
          .first;
      await manager.loadPlugin(
        id: 'direct.scale',
        manifest: testManifest(
          'direct.scale',
          permissions: {PluginPermissions.emit},
          drivers: const [
            PluginDriverDeclaration(
              id: 'scale',
              type: PluginDriverType.scale,
              capabilities: {PluginScaleCapability.tare},
            ),
          ],
        ),
        settings: {},
        jsCode: '''
        function createPlugin(host) {
          return {
            id: "direct.scale",
            onLoad() {
              __deviceSetHandlers("direct_scale", {
                pluginId: "direct.scale", generation: pluginGeneration,
                bridgeToken: pluginBridgeToken,
                handlers: {connect() {}, disconnect() {}}
              });
              __deviceRegisterPending("direct_scale_request", {
                bridgeToken: pluginBridgeToken,
                resolve: () => host.emit("rejected", "unexpected success"),
                reject: error => host.emit("rejected", error.code)
              });
              pluginHostBridge.deviceRequest(pluginBridgeToken, pluginGeneration,
                "direct_scale_request", "register", {
                  registrationHandle: "direct_scale",
                  definition: {driverId: "scale", instanceId: "one", name: "Scale"}
                });
            }
          };
        }
      ''',
      );
      expect(
        (await rejected.timeout(const Duration(seconds: 2)))['payload'],
        'invalid_argument',
      );
      expect(await manager.deviceService.devices.first, isEmpty);
    },
  );

  test(
    'public non-BLE Scale registration captures each connect session',
    () async {
      final manager = PluginManager(kvStore: FakeKeyValueStoreService());
      final controller = ScaleController();
      addTearDown(() async {
        controller.dispose();
        await manager.dispose();
      });
      final registered = manager.emitStream
          .where((event) => event['event'] == 'registered')
          .first;
      await manager.loadPlugin(
        id: 'memory.scale',
        manifest: testManifest(
          'memory.scale',
          permissions: {PluginPermissions.emit},
          drivers: const [
            PluginDriverDeclaration(
              id: 'scale',
              type: PluginDriverType.scale,
              capabilities: {PluginScaleCapability.tare},
            ),
          ],
        ),
        settings: {},
        jsCode: '''
        function createPlugin(host) {
          return {
            id: "memory.scale",
            onLoad() {
              return host.devices.register({
                driverId: "scale", instanceId: "memory", name: "Memory scale"
              }, {
                async connect(context) {
                  globalThis.previousScaleContext = globalThis.scaleContext;
                  globalThis.scaleContext = context;
                  await context.publish({weight: -2.5});
                },
                disconnect() {},
                tare() { return globalThis.scaleContext.publish({weight: 0}); }
              }).then(device => host.emit("registered", device.deviceId));
            }
          };
        }
      ''',
      );
      await registered.timeout(const Duration(seconds: 2));
      final scale = (await manager.deviceService.devices.first).single as Scale;
      final firstSample = controller.weightSnapshot.first;
      await controller.connectToScale(scale);
      expect((await firstSample).weight, -2.5);
      expect(controller.currentWeightSnapshot!.battery, isNull);
      final tareSample = controller.weightSnapshot.first;
      await scale.tare();
      expect((await tareSample).weight, 0);
      await expectLater(
        scale.startTimer(),
        throwsA(isA<PluginDeviceException>()),
      );
      await scale.disconnect();
      await controller.connectToScale(scale);
      manager.js.evaluate('''
      globalThis.previousScaleContext.publish({weight: 99}).catch(error => {
        globalThis.staleScaleError = error.code;
      });
    ''');
      manager.js.executePendingJob();
      await scale.tare();
      expect(
        manager.js.evaluate('globalThis.staleScaleError').stringResult,
        'stale_session',
      );
      await manager.unloadPlugin('memory.scale');
      expect(await manager.deviceService.devices.first, isEmpty);
    },
  );
}
