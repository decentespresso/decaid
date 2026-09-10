import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/device/sensor.dart';
import 'package:reaprime/src/plugins/plugin_ble_registry.dart';
import 'package:reaprime/src/plugins/plugin_manager.dart';
import 'package:reaprime/src/services/ble/universal_ble_transport.dart';
import 'package:universal_ble/universal_ble.dart';

import '../helpers/plugin_ble_fixture.dart';
import 'plugin_manager_ble_test.dart' show bleSensorManifest, bleSensorSource;
import 'plugin_test_helpers.dart';

/// Platform recovery is owned by the transport, not by the plugin host.
///
/// The configured BlueZ recovery sequence - first connect fails, device cache
/// refresh with its own scan, retry, post-connect settle - is longer than the
/// plugin invocation timeout here, so a plugin-imposed deadline would kill a
/// recovery the transport considers healthy. Fake time advances the whole
/// sequence and the native operation log proves the order it ran in.
void main() {
  const pluginTimeout = Duration(milliseconds: 200);

  test('BlueZ recovery may exceed the plugin invocation timeout', () {
    final platform = PluginBleFixturePlatform()..connectFailures = 1;
    UniversalBle.setInstance(platform);
    UniversalBle.queueType = QueueType.perDevice;
    addTearDown(() {
      UniversalBle.clearQueue();
      UniversalBle.queueType = QueueType.global;
    });

    fakeAsync((async) {
      final manager = PluginManager(
        kvStore: FakeKeyValueStoreService(),
        deviceInvocationTimeout: pluginTimeout,
      );
      Object? loadError;
      manager
          .loadPlugin(
            id: 'ble.sensor',
            manifest: bleSensorManifest(),
            settings: {},
            jsCode: bleSensorSource,
          )
          .then(
            (_) {},
            onError: (Object error) {
              loadError = error;
            },
          );
      async.elapse(const Duration(seconds: 1));
      expect(loadError, isNull, reason: 'the sensor fixture must load');

      final evidence = BleAdvertisementEvidence(serviceUuids: ['180f']);
      Sensor? sensor;
      var settled = false;
      Object? outcome;
      manager.bleService
          .createCandidate(
            driver: manager.bleService.registry.decide(evidence).drivers.single,
            physicalId: 'AA:BB',
            evidence: evidence,
            admit: () => true,
            createTransport: () => UniversalBleTransport(
              device: BleDevice(deviceId: 'AA:BB', name: 'Fixture'),
              isAndroidOverride: false,
              isLinuxOverride: true,
              bluezScanSettleDelay: const Duration(milliseconds: 60),
              bluezCacheRefreshScan: const Duration(milliseconds: 90),
              bluezPostConnectDelay: const Duration(milliseconds: 60),
            ),
          )
          .then((device) {
            sensor = device as Sensor;
            return sensor!.onConnect();
          })
          .then(
            (_) {
              settled = true;
            },
            onError: (Object error) {
              settled = true;
              outcome = error;
            },
          );

      async.elapse(const Duration(seconds: 30));

      expect(
        settled,
        isTrue,
        reason:
            'the recovery must complete inside the transport policy even '
            'though it outlives the plugin invocation timeout',
      );
      expect(outcome, isNull);
      expect(
        async.elapsed,
        greaterThan(pluginTimeout),
        reason: 'the exercised recovery is longer than the plugin budget',
      );
      expect(
        platform.connectCalls,
        2,
        reason: 'the first acquisition fails and the retry is the second one',
      );

      final operations = platform.operations;
      final firstConnect = operations.indexOf('connect');
      final refreshScan = operations.indexOf('startScan', firstConnect + 1);
      final retry = operations.indexOf('connect', firstConnect + 1);
      final pluginRan = operations.indexOf('discoverServices');
      expect(firstConnect, greaterThanOrEqualTo(0));
      expect(
        refreshScan,
        greaterThan(firstConnect),
        reason: 'the device cache refresh scans before the retry',
      );
      expect(
        retry,
        greaterThan(refreshScan),
        reason: 'the retry follows the cache-refresh scan',
      );
      expect(
        pluginRan,
        greaterThan(retry),
        reason: 'the plugin protocol starts only after recovery connects',
      );
      expect(
        platform.scanFilters.length,
        greaterThanOrEqualTo(1),
        reason: 'the device cache refresh ran its own scan',
      );

      manager.dispose().ignore();
      async.elapse(const Duration(seconds: 2));
    });
  });
}
