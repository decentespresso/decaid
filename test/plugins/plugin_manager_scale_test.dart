import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/scale_controller.dart';
import 'package:reaprime/src/models/device/scale.dart';
import 'package:reaprime/src/plugins/plugin_device_service.dart';
import 'package:reaprime/src/plugins/plugin_manager.dart';
import 'package:reaprime/src/plugins/plugin_manifest.dart';
import 'package:reaprime/src/plugins/plugin_scale.dart';
import 'package:reaprime/src/models/device/device.dart' as device;

import 'plugin_test_helpers.dart';

void main() {
  for (final suspended in [false, true]) {
    test(
      'manager retirement gates reconnect after ${suspended ? "suspended" : "successful"} connect',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final sockets = <WebSocket>[];
        final frames = <dynamic>[];
        server.listen((request) async {
          final socket = await WebSocketTransformer.upgrade(request);
          sockets.add(socket);
          socket.listen(frames.add);
        });
        final manager = PluginManager(
          kvStore: FakeKeyValueStoreService(),
          deviceInvocationTimeout: const Duration(seconds: 1),
          deviceService: PluginDeviceService(
            scaleInvocationTimeout: const Duration(milliseconds: 250),
          ),
        );
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
        final opened = manager.emitStream
            .where((e) => e['event'] == 'opened')
            .first;
        await manager.loadPlugin(
          id: 'boundary.scale',
          manifest: testManifest(
            'boundary.scale',
            permissions: {
              PluginPermissions.emit,
              PluginPermissions.networkWebsocket,
            },
            drivers: const [
              PluginDriverDeclaration(
                id: 'scale',
                type: PluginDriverType.scale,
              ),
            ],
          ),
          settings: {},
          jsCode:
              '''
          function createPlugin(host) {
            let connections = 0;
            return {id: "boundary.scale", onLoad() {
              return host.devices.register({driverId: "scale", instanceId: "one", name: "Scale"}, {
                async connect(context) {
                  connections++;
                  const opened = await context.transport.open({kind: "websocket", url: "ws://127.0.0.1:${server.port}/"});
                  if (connections === 1) {
                    globalThis.oldScaleSend = () => context.transport.send(opened.handle, {type: "text", data: "stale"})
                      .then(() => host.emit("stale-send", false), () => host.emit("stale-send", true));
                    host.emit("opened", true);
                    if ($suspended) await new Promise(() => {});
                  }
                  await context.publish({weight: 1});
                },
                disconnect() { if (connections === 1) return new Promise(() => {}); }
              }).then(() => host.emit("registered", true));
            }};
          }
        ''',
        );
        await registered.timeout(const Duration(seconds: 2));
        final scale =
            (await manager.deviceService.devices.first).single as PluginScale;
        final first = scale.onConnect();
        final firstFinished = suspended
            ? expectLater(first, throwsA(anything))
            : first;
        await opened.timeout(const Duration(seconds: 2));
        if (!suspended) await firstFinished;
        var disconnectSettled = false;
        final disconnected = expectLater(scale.disconnect(), throwsA(anything))
            .then((_) {
              disconnectSettled = true;
            });
        await firstFinished;
        var reconnected = false;
        final replacement = scale.onConnect().then((_) {
          reconnected = true;
        });
        await Future<void>.delayed(
          scale.invocationTimeout + const Duration(milliseconds: 50),
        );
        expect(disconnectSettled, false);
        expect(reconnected, false);
        expect(
          await scale.connectionState.first,
          device.ConnectionState.disconnecting,
        );
        expect(manager.liveTransportCount, 1);
        await disconnected;
        await replacement;
        expect(manager.liveTransportCount, 1);
        final rejected = manager.emitStream
            .where((e) => e['event'] == 'stale-send')
            .first;
        manager.js.evaluate('globalThis.oldScaleSend()');
        while (manager.js.executePendingJob() > 0) {}
        expect(
          (await rejected.timeout(const Duration(seconds: 2)))['payload'],
          true,
        );
        expect(frames, isEmpty);
      },
    );
  }

  for (final cleanup in ['success', 'throws', 'hangs']) {
    test(
      'never-settling connects release bookkeeping after $cleanup cleanup',
      () async {
        final manager = PluginManager(
          kvStore: FakeKeyValueStoreService(),
          deviceInvocationTimeout: const Duration(milliseconds: 200),
        );
        addTearDown(manager.dispose);
        final registered = manager.emitStream
            .where((e) => e['event'] == 'registered')
            .first;
        await manager.loadPlugin(
          id: 'hung.scale',
          manifest: testManifest(
            'hung.scale',
            permissions: {PluginPermissions.emit},
            drivers: const [
              PluginDriverDeclaration(
                id: 'scale',
                type: PluginDriverType.scale,
              ),
            ],
          ),
          settings: {},
          jsCode:
              '''
          function createPlugin(host) {
            return {id: "hung.scale", onLoad() {
              return host.devices.register({driverId: "scale", instanceId: "one", name: "Scale"}, {
                connect() {
                  host.emit("suspended", true);
                  return new Promise(() => {});
                },
                disconnect() {
                  if ("$cleanup" === "throws") throw new Error("cleanup failed");
                  if ("$cleanup" === "hangs") return new Promise(() => {});
                }
              }).then(() => host.emit("registered", true));
            }};
          }
        ''',
        );
        await registered.timeout(const Duration(seconds: 2));
        final scale =
            (await manager.deviceService.devices.first).single as Scale;
        addTearDown((scale as PluginDeviceAdapter).dispose);
        for (var attempt = 0; attempt < 4; attempt++) {
          final suspended = manager.emitStream
              .where((e) => e['event'] == 'suspended')
              .first;
          final connecting = expectLater(
            scale.onConnect(),
            throwsA(isA<PluginDeviceException>()),
          );
          await suspended.timeout(const Duration(seconds: 2));
          expect(manager.deviceConnectAttemptCount, 1);
          final disconnecting = scale.disconnect();
          expect(manager.deviceConnectAttemptCount, 0);
          expect(manager.retiredDeviceConnectCount, 1);
          if (cleanup == 'success') {
            await disconnecting;
          } else {
            await expectLater(
              disconnecting,
              throwsA(isA<PluginDeviceException>()),
            );
          }
          await connecting;
          expect(
            [
              manager.deviceConnectAttemptCount,
              manager.retiredDeviceConnectCount,
            ],
            [0, 0],
          );
          expect(manager.liveTransportCount, 0);
        }
      },
    );
  }

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
      expect(manager.deviceConnectAttemptCount, 0);
      expect(manager.retiredDeviceConnectCount, 0);
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
          permissions: {
            PluginPermissions.emit,
            PluginPermissions.networkWebsocket,
          },
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
                  if (!globalThis.openOldScaleTransport) {
                    globalThis.openOldScaleTransport = () => context.transport.open({
                      kind: "websocket", url: "ws://127.0.0.1:1/"
                    }).then(
                      () => host.emit("old-open", "unexpected success"),
                      error => host.emit("old-open", error.message)
                    );
                  }
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
        throwsA(
          isA<ScaleOperationException>().having(
            (e) => e.code,
            'code',
            'unsupported_operation',
          ),
        ),
      );
      await scale.disconnect();
      await controller.connectToScale(scale);
      expect(manager.liveTransportCount, 0);
      expect(manager.deviceConnectAttemptCount, 0);
      expect(manager.retiredDeviceConnectCount, 0);
      final oldOpen = manager.emitStream
          .where((event) => event['event'] == 'old-open')
          .first;
      manager.js.evaluate('globalThis.openOldScaleTransport()');
      while (manager.js.executePendingJob() > 0) {}
      expect(
        (await oldOpen.timeout(const Duration(seconds: 2)))['payload'],
        'Plugin device connect retired',
      );
      expect(manager.liveTransportCount, 0);
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
