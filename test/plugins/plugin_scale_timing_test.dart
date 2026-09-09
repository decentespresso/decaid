import 'dart:typed_data';
import 'package:clock/clock.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/scale_controller.dart';
import 'package:reaprime/src/models/device/scale.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/plugins/plugin_ble_matcher.dart';
import 'package:reaprime/src/plugins/plugin_ble_registry.dart';
import 'package:reaprime/src/plugins/plugin_manager.dart';
import 'package:reaprime/src/plugins/plugin_manifest.dart';
import '../helpers/plugin_ble_fixture.dart';
import '../helpers/test_scale.dart';
import '../helpers/scale_timing_shot.dart';
import 'plugin_test_helpers.dart';

void main() {
  for (final (batchSize, publicationDelay) in [
    (1, 0),
    (4, 0),
    (1, 150),
    (4, 150),
  ]) {
    test(
      'full JS Scale preserves native timestamps and flow: batch=$batchSize, publicationDelay=$publicationDelay',
      () async {
        var now = DateTime.utc(2026, 1, 1);
        await withClock(Clock(() => now), () async {
          final manager = PluginManager(kvStore: FakeKeyValueStoreService());
          var transport = PluginBleFixtureTransport('AA:BB');
          final nativeScale = TestScale();
          final native = ScaleController();
          final plugin = ScaleController();
          final nativeSamples = <WeightSnapshot>[];
          final pluginSamples = <WeightSnapshot>[];
          final deliveryAges = <Duration>[];
          final nativeSub = native.weightSnapshot.listen(nativeSamples.add);
          final pluginSub = plugin.weightSnapshot.listen((sample) {
            pluginSamples.add(sample);
            deliveryAges.add(now.difference(sample.timestamp));
          });
          addTearDown(() async {
            await nativeSub.cancel();
            await pluginSub.cancel();
            native.dispose();
            plugin.dispose();
            nativeScale.dispose();
            await manager.dispose();
          });
          await native.connectToScale(nativeScale);
          await manager.loadPlugin(
            id: 'timing.scale',
            settings: {},
            manifest: testManifest(
              'timing.scale',
              permissions: {
                PluginPermissions.emit,
                PluginPermissions.transportBle,
              },
              drivers: [
                PluginDriverDeclaration(
                  id: 'scale',
                  type: PluginDriverType.scale,
                  ble: PluginBleMatcher.fromJson({
                    'serviceUuids': ['180f'],
                  }),
                ),
              ],
            ),
            jsCode: '''
            function createPlugin(host) {
              return {id:'timing.scale', onLoad() {
                return host.devices.bindDriver('scale', {create() {
                  return {async connect(session) {
                    globalThis.context = session;
                    globalThis.trySample = sample => session.publish({weight:99}, sample)
                      .then(() => host.emit('duplicate','accepted'), error => host.emit('duplicate',error.code));
                    await session.gatt.subscribe('180f','2a19', async (data, sample) => {
                      try {
                      if (globalThis.crash) throw Object.assign(new Error('protocol failed'), {code:'stale_sample'});
                      globalThis.lastSample = sample;
                      if (globalThis.hold) {
                        globalThis.hold = false;
                        await new Promise(resolve => {globalThis.release = resolve; host.emit('held',true);});
                      }
                      const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
                      const value = (alphabet.indexOf(data[0]) << 2) | (alphabet.indexOf(data[1]) >> 4);
                      await session.publish({weight:value / 10}, sample);
                      host.emit('sample',value);
                      } catch (error) { host.emit('rejection',error.code); throw error; }
                      finally { host.emit('settled',true); }
                    });
                  }, disconnect() {}};
                }});
              }};
            }
          ''',
          );
          final evidence = BleAdvertisementEvidence(serviceUuids: ['180f']);
          final scale =
              await manager.bleService.createCandidate(
                    driver: manager.bleService.registry
                        .decide(evidence)
                        .drivers
                        .single,
                    physicalId: 'AA:BB',
                    evidence: evidence,
                    admit: () => true,
                    createTransport: () => transport,
                  )
                  as Scale;
          await plugin.connectToScale(scale);
          nativeScale.emitSnapshot(
            ScaleSnapshot(timestamp: now, weight: 5.2, batteryLevel: null),
          );
          for (var batch = 0; batch < 4; batch++) {
            final last = 53 + batch * batchSize + batchSize - 1;
            final finished = manager.emitStream.firstWhere(
              (e) => e['event'] == 'sample' && e['payload'] == last,
            );
            final held = manager.emitStream.firstWhere(
              (e) => e['event'] == 'held',
            );
            manager.js.evaluate('globalThis.hold = true');
            for (var offset = 0; offset < batchSize; offset++) {
              now = now.add(const Duration(milliseconds: 100));
              final value = 53 + batch * batchSize + offset;
              nativeScale.emitSnapshot(
                ScaleSnapshot(
                  timestamp: now,
                  weight: value / 10,
                  batteryLevel: null,
                ),
              );
              transport.subscribers.values.single(Uint8List.fromList([value]));
              if (offset == 0) await held.timeout(const Duration(seconds: 2));
            }
            now = now.add(Duration(milliseconds: publicationDelay));
            manager.js.evaluate('globalThis.release()');
            while (manager.js.executePendingJob() > 0) {}
            await finished.timeout(const Duration(seconds: 2));
          }
          expect(pluginSamples.length, nativeSamples.length);
          expect(
            deliveryAges
                .skip(1)
                .any(
                  (age) =>
                      age.inMilliseconds >=
                      (batchSize - 1) * 100 + publicationDelay,
                ),
            isTrue,
          );
          for (var i = 0; i < nativeSamples.length; i++) {
            expect(
              pluginSamples[i].timestamp,
              nativeSamples[i].timestamp,
              reason: 'sample $i',
            );
            expect(pluginSamples[i].weight, nativeSamples[i].weight);
            expect(
              pluginSamples[i].weightFlow,
              closeTo(nativeSamples[i].weightFlow, 1e-9),
            );
            expect(
              pluginSamples[i].controlWeightFlow,
              closeTo(nativeSamples[i].controlWeightFlow, 1e-9),
            );
          }
          final duplicate = manager.emitStream.firstWhere(
            (e) => e['event'] == 'duplicate',
          );
          manager.js.evaluate('globalThis.trySample(globalThis.lastSample)');
          while (manager.js.executePendingJob() > 0) {}
          expect(
            (await duplicate.timeout(const Duration(seconds: 2)))['payload'],
            'stale_sample',
          );
          final nativeStop = await scaleTimingStopIndex(nativeSamples);
          expect(nativeStop, isNotNull);
          expect(await scaleTimingStopIndex(pluginSamples), nativeStop);
          expect(
            await scaleTimingStopIndex(
              pluginSamples,
              deliveryAge: const Duration(seconds: 3),
            ),
            isNull,
          );
          if (batchSize == 1) {
            Future<void> holdSample() async {
              final held = manager.emitStream.firstWhere(
                (e) => e['event'] == 'held',
              );
              manager.js.evaluate('globalThis.hold = true');
              transport.subscribers.values.single(Uint8List.fromList([80]));
              await held.timeout(const Duration(seconds: 2));
            }

            void release() {
              manager.js.evaluate('globalThis.release()');
              while (manager.js.executePendingJob() > 0) {}
            }

            await holdSample();
            final beforeExpiry = pluginSamples.length;
            now = now.add(const Duration(seconds: 3));
            final settled = manager.emitStream.firstWhere(
              (e) => e['event'] == 'settled',
            );
            final rejected = manager.emitStream.firstWhere(
              (e) => e['event'] == 'rejection',
            );
            release();
            await settled.timeout(const Duration(seconds: 2));
            expect((await rejected)['payload'], 'stale_sample');
            expect(pluginSamples.length, beforeExpiry);
            final fresh = manager.emitStream.firstWhere(
              (e) => e['event'] == 'sample' && e['payload'] == 81,
            );
            transport.subscribers.values.single(Uint8List.fromList([81]));
            await fresh.timeout(const Duration(seconds: 2));
            expect(
              await scale.connectionState.first,
              ConnectionState.connected,
            );
            if (publicationDelay != 0) await holdSample();
            now = now.subtract(const Duration(seconds: 1));
            if (publicationDelay == 0) {
              transport.subscribers.values.single(Uint8List.fromList([82]));
            } else {
              release();
            }
            await transport.disposed.future.timeout(const Duration(seconds: 2));
            await scale.connectionState.firstWhere(
              (s) => s == ConnectionState.disconnected,
            );
            transport = PluginBleFixtureTransport('AA:BB');
            final restarted = plugin.weightSnapshot.first;
            await plugin.connectToScale(scale);
            expect((await restarted).timestamp, now);
            final pluginFailure = manager.emitStream.firstWhere(
              (e) =>
                  e['event'] == 'rejection' && e['payload'] == 'stale_sample',
            );
            manager.js.evaluate('globalThis.crash = true');
            transport.subscribers.values.single(Uint8List.fromList([83]));
            expect(
              (await pluginFailure.timeout(
                const Duration(seconds: 2),
              ))['payload'],
              'stale_sample',
            );
            await transport.disposed.future.timeout(const Duration(seconds: 2));
          }
        });
      },
    );
  }
}
