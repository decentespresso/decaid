import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/plugins/plugin_device_contract.dart';
import 'package:reaprime/src/plugins/plugin_manager.dart';
import 'package:reaprime/src/plugins/plugin_manifest.dart';
import 'package:reaprime/src/plugins/plugin_scale.dart';

import 'plugin_test_helpers.dart';

PluginScale _scale(
  String id,
  void Function(String) onSession, {
  Set<PluginScaleCapability> capabilities = const {
    PluginScaleCapability.battery,
  },
}) {
  late PluginScale scale;
  scale = PluginScale(
    deviceId: id,
    name: id,
    capabilities: capabilities,
    invoke: (operation, payload) async {
      if (operation == PluginDeviceOperation.connect) {
        onSession(payload['session'] as String);
        scale.publish({'weight': 0}, session: payload['session'] as String);
      }
      return {};
    },
  );
  return scale;
}

void main() {
  test('scale metadata is validated, session scoped, and cleared', () async {
    String? firstSession;
    String? secondSession;
    final first = _scale('first', (session) => firstSession = session);
    final second = _scale('second', (session) => secondSession = session);
    addTearDown(() async {
      await first.dispose();
      await second.dispose();
    });

    await first.onConnect();
    await second.onConnect();
    expect(first.currentDeviceInformation, isNull);
    first.publishInfo({
      'firmwareVersion': 'opaque',
      'batteryLevel': 0,
    }, session: firstSession);
    second.publishInfo({
      'firmwareVersion': 'other',
      'batteryLevel': 100,
    }, session: secondSession);
    expect(first.currentDeviceInformation?.toJson(), {
      'firmwareVersion': 'opaque',
      'batteryLevel': 0,
    });
    String? unsupportedSession;
    final unsupported = _scale(
      'unsupported',
      (session) => unsupportedSession = session,
      capabilities: const {},
    );
    addTearDown(unsupported.dispose);
    await unsupported.onConnect();
    expect(
      () => unsupported.publishInfo({
        'batteryLevel': 1,
      }, session: unsupportedSession),
      throwsA(
        isA<PluginDeviceException>().having(
          (error) => error.code,
          'code',
          'invalid_argument',
        ),
      ),
    );
    expect(second.currentDeviceInformation?.toJson(), {
      'firmwareVersion': 'other',
      'batteryLevel': 100,
    });
    for (final invalid in [
      {'unknown': true},
      {'firmwareVersion': 1},
      {'batteryLevel': -1},
      {'batteryLevel': 101},
      {'batteryLevel': 1.5},
    ]) {
      expect(
        () => first.publishInfo(invalid, session: firstSession),
        throwsA(
          isA<PluginDeviceException>().having(
            (error) => error.code,
            'code',
            'invalid_argument',
          ),
        ),
      );
    }
    first.publishInfo({'batteryLevel': null}, session: firstSession);
    expect(first.currentDeviceInformation?.toJson(), {
      'firmwareVersion': 'opaque',
    });
    await first.disconnect();
    expect(first.currentDeviceInformation, isNull);
    final staleSession = firstSession;
    await first.onConnect();
    expect(first.currentDeviceInformation, isNull);
    expect(
      () => first.publishInfo({'batteryLevel': 50}, session: staleSession),
      throwsA(
        isA<PluginDeviceException>().having(
          (error) => error.code,
          'code',
          'stale_session',
        ),
      ),
    );
  });

  test(
    'metadata alone does not satisfy Scale readiness and failed connect clears it',
    () async {
      late PluginScale scale;
      scale = PluginScale(
        deviceId: 'metadata-only',
        name: 'Metadata only',
        capabilities: const {PluginScaleCapability.battery},
        invocationTimeout: const Duration(milliseconds: 30),
        invoke: (operation, payload) async {
          if (operation == PluginDeviceOperation.connect) {
            scale.publishInfo({
              'firmwareVersion': 'R029',
              'batteryLevel': 0,
            }, session: payload['session'] as String);
          }
          return {};
        },
      );
      addTearDown(scale.dispose);
      await expectLater(scale.onConnect(), throwsA(isA<TimeoutException>()));
      expect(scale.currentDeviceInformation, isNull);
    },
  );

  test(
    'real JS Scale context publishes metadata and fences stale contexts',
    () async {
      final manager = PluginManager(kvStore: FakeKeyValueStoreService());
      addTearDown(manager.dispose);
      final registered = manager.emitStream.firstWhere(
        (event) => event['event'] == 'registered',
      );
      await manager.loadPlugin(
        id: 'metadata.scale',
        manifest: testManifest(
          'metadata.scale',
          permissions: {PluginPermissions.emit},
          drivers: const [
            PluginDriverDeclaration(
              id: 'scale',
              type: PluginDriverType.scale,
              capabilities: {PluginScaleCapability.battery},
            ),
          ],
        ),
        settings: {},
        jsCode: '''
        function createPlugin(host) {
          const contexts = [];
          return {id: 'metadata.scale', onLoad() {
            return host.devices.register(
              {driverId: 'scale', instanceId: 'one', name: 'Metadata Scale'},
              {
                async connect(context) {
                  contexts.push(context);
                  globalThis.publishInvalid = () => context.publishInfo({batteryLevel: 1.5})
                    .then(() => host.emit('invalid', false), error => host.emit('invalid', error.code));
                  globalThis.publishOld = () => contexts[0].publishInfo({batteryLevel: 42})
                    .then(() => host.emit('stale', false), error => host.emit('stale', error.code));
                  host.emit('connection', context.connectionId);
                  await context.publish({weight: 0});
                  await context.publishInfo({firmwareVersion: 'R029', batteryLevel: 0});
                },
                disconnect() {}
              }
            ).then(() => host.emit('registered', true));
          }};
        }
      ''',
      );
      await registered.timeout(const Duration(seconds: 2));
      final scale =
          (await manager.deviceService.devices.first).single as PluginScale;
      final connection = manager.emitStream.firstWhere(
        (event) => event['event'] == 'connection',
      );
      await scale.onConnect();
      final connectionId = (await connection)['payload'];
      expect(connectionId, isA<String>());
      expect(scale.connectionId, connectionId);
      expect(scale.currentDeviceInformation?.toJson(), {
        'firmwareVersion': 'R029',
        'batteryLevel': 0,
      });

      final invalid = manager.emitStream.firstWhere(
        (event) => event['event'] == 'invalid',
      );
      manager.js.evaluate('publishInvalid();');
      while (manager.js.executePendingJob() > 0) {}
      expect((await invalid)['payload'], 'invalid_argument');

      await scale.disconnect();
      expect(scale.currentDeviceInformation, isNull);
      expect(scale.connectionId, isNull);
      await scale.onConnect();
      final stale = manager.emitStream.firstWhere(
        (event) => event['event'] == 'stale',
      );
      manager.js.evaluate('publishOld();');
      while (manager.js.executePendingJob() > 0) {}
      expect((await stale)['payload'], 'stale_session');
    },
  );
}
