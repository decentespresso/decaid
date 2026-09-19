import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/plugins/plugin_ble_matcher.dart';
import 'package:reaprime/src/plugins/plugin_ble_registry.dart';
import 'package:reaprime/src/plugins/plugin_manager.dart';
import 'package:reaprime/src/plugins/plugin_manifest.dart';
import 'package:reaprime/src/plugins/plugin_scale.dart';

import '../helpers/plugin_ble_fixture.dart';
import 'plugin_test_helpers.dart';

void main() {
  test(
    'BLE Scale context exposes domain identity and metadata publication',
    () async {
      final manager = PluginManager(kvStore: FakeKeyValueStoreService());
      addTearDown(manager.dispose);
      final manifest = testManifest(
        'ble.metadata.scale',
        permissions: {PluginPermissions.emit, PluginPermissions.transportBle},
        drivers: [
          PluginDriverDeclaration(
            id: 'scale',
            type: PluginDriverType.scale,
            capabilities: {PluginScaleCapability.battery},
            ble: PluginBleMatcher.fromJson({
              'serviceUuids': ['180f'],
            }),
          ),
        ],
      );
      final bound = manager.emitStream.firstWhere(
        (event) => event['event'] == 'bound',
      );
      await manager.loadPlugin(
        id: 'ble.metadata.scale',
        manifest: manifest,
        settings: {},
        jsCode: '''
        function createPlugin(host) {
          return {id: 'ble.metadata.scale', async onLoad() {
            await host.devices.bindDriver('scale', {create() {
              return {
                async connect(context) {
                  globalThis.oldContext = globalThis.currentContext;
                  globalThis.currentContext = context;
                  globalThis.publishOld = () => oldContext.publishInfo({batteryLevel: 0}).then(
                    () => host.emit('stale', false), error => host.emit('stale', error.code));
                  globalThis.publishOversize = () => context.publishInfo({firmwareVersion: 'x'.repeat(65536)})
                    .then(() => host.emit('oversize', false), error => host.emit('oversize', error.code));
                  host.emit('connection', context.connectionId);
                  await context.publish({weight: 0});
                  await context.publishInfo({firmwareVersion: 'R029', batteryLevel: 100});
                },
                disconnect() {}
              };
            }});
            host.emit('bound', true);
          }};
        }
      ''',
      );
      await bound.timeout(const Duration(seconds: 2));
      final evidence = BleAdvertisementEvidence(serviceUuids: ['180f']);
      final transports = <PluginBleFixtureTransport>[];
      final scale =
          await manager.bleService.createCandidate(
                driver: manager.bleService.registry
                    .decide(evidence)
                    .drivers
                    .single,
                physicalId: 'AA:BB',
                evidence: evidence,
                createTransport: () {
                  final transport = PluginBleFixtureTransport('AA:BB');
                  transports.add(transport);
                  return transport;
                },
                admit: () => true,
              )
              as PluginScale;
      final connection = manager.emitStream.firstWhere(
        (event) => event['event'] == 'connection',
      );
      await scale.onConnect();
      expect((await connection)['payload'], isA<String>());
      expect(scale.currentDeviceInformation?.toJson(), {
        'firmwareVersion': 'R029',
        'batteryLevel': 100,
      });
      final oversize = manager.emitStream.firstWhere(
        (event) => event['event'] == 'oversize',
      );
      manager.js.evaluate('publishOversize();');
      while (manager.js.executePendingJob() > 0) {}
      expect((await oversize)['payload'], 'resource_limit');
      expect(scale.connectionId, (await connection)['payload']);
      manager.bleService.revokeSessions();
      await transports.first.disposed.future.timeout(
        const Duration(seconds: 2),
      );
      expect(scale.currentDeviceInformation, isNull);
      await scale.disconnect();
      expect(scale.currentDeviceInformation, isNull);
      await scale.onConnect();
      expect(scale.currentDeviceInformation?.firmwareVersion, 'R029');
      transports.last.states.add(ConnectionState.disconnected);
      await transports.last.disposed.future.timeout(const Duration(seconds: 2));
      expect(scale.currentDeviceInformation, isNull);
      expect(scale.connectionId, isNull);
      final stale = manager.emitStream.firstWhere(
        (event) => event['event'] == 'stale',
      );
      manager.js.evaluate('publishOld();');
      while (manager.js.executePendingJob() > 0) {}
      expect((await stale)['payload'], 'stale_session');
    },
  );
}
