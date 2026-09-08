import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/device/sensor.dart';
import 'package:reaprime/src/plugins/plugin_ble_registry.dart';
import 'package:reaprime/src/plugins/plugin_manager.dart';
import 'package:reaprime/src/services/ble/universal_ble_transport.dart';
import 'package:universal_ble/universal_ble.dart';

import '../helpers/plugin_ble_fixture.dart';
import 'plugin_manager_ble_test.dart' show bleSensorSource, bleSensorManifest;
import 'plugin_test_helpers.dart';

void main() {
  test(
    'real bridge resets native CCCD and preserves native error distinctions',
    () async {
      final platform = PluginBleFixturePlatform();
      UniversalBle.setInstance(platform);
      final manager = PluginManager(kvStore: FakeKeyValueStoreService());
      addTearDown(manager.dispose);
      await manager.loadPlugin(
        id: 'ble.sensor',
        manifest: bleSensorManifest(),
        settings: {},
        jsCode: bleSensorSource.replaceFirst(
          "const services = await session.gatt.discoverServices();",
          '''
          globalThis.checkRead = () => session.gatt.read('180f', '2a19')
            .then(value => host.emit('read', value), error => host.emit('read', error.code));
          globalThis.checkWrite = () => session.gatt.writeWithResponse('180f', '2a19', 'AQ==')
            .then(() => host.emit('write', 'ok'), error => host.emit('write', error.code));
          globalThis.replaceSubscription = async () => {
            const old = await session.gatt.subscribe('180f', '2a19', () => {});
            await session.gatt.subscribe('0000180f-0000-1000-8000-00805f9b34fb', '2a19',
              data => host.emit('replacement', data));
            await old.unsubscribe();
            host.emit('replaced', true);
          };
          const services = await session.gatt.discoverServices();
        ''',
        ),
      );
      final evidence = BleAdvertisementEvidence(serviceUuids: ['180f']);
      final sensor =
          await manager.bleService.createCandidate(
                driver: manager.bleService.registry
                    .decide(evidence)
                    .drivers
                    .single,
                physicalId: 'AA:BB',
                evidence: evidence,
                admit: () => true,
                createTransport: () => UniversalBleTransport(
                  device: BleDevice(deviceId: 'AA:BB', name: 'Fixture'),
                  isLinuxOverride: false,
                  isAndroidOverride: false,
                ),
              )
              as Sensor;
      await sensor.onConnect();
      final replaced = manager.emitStream.firstWhere(
        (e) => e['event'] == 'replaced',
      );
      manager.js.evaluate('replaceSubscription();');
      while (manager.js.executePendingJob() > 0) {}
      await replaced.timeout(const Duration(seconds: 2));
      expect(platform.notificationProperties, [
        BleInputProperty.notification,
        BleInputProperty.disabled,
        BleInputProperty.notification,
        BleInputProperty.disabled,
        BleInputProperty.notification,
      ]);
      final replacement = manager.emitStream.firstWhere(
        (e) => e['event'] == 'replacement',
      );
      platform.updateCharacteristicValue(
        'AA:BB',
        '00002a19-0000-1000-8000-00805f9b34fb',
        Uint8List.fromList([53]),
        null,
      );
      expect(
        (await replacement.timeout(const Duration(seconds: 2)))['payload'],
        'NQ==',
      );
      for (final (code, expected) in [
        (UniversalBleErrorCode.characteristicNotFound, 'attribute_unavailable'),
        (UniversalBleErrorCode.operationCancelled, 'operationCancelled'),
      ]) {
        platform.readError = UniversalBleException(
          code: code,
          message: 'fixture',
        );
        final result = manager.emitStream.firstWhere(
          (e) => e['event'] == 'read',
        );
        manager.js.evaluate('checkRead();');
        expect(
          (await result.timeout(const Duration(seconds: 2)))['payload'],
          expected,
        );
      }
      platform.writeError = UniversalBleException(
        code: UniversalBleErrorCode.characteristicDoesNotSupportWrite,
        message: 'fixture',
      );
      final written = manager.emitStream.firstWhere(
        (e) => e['event'] == 'write',
      );
      manager.js.evaluate('checkWrite();');
      expect(
        (await written.timeout(const Duration(seconds: 2)))['payload'],
        'characteristicDoesNotSupportWrite',
      );
      expect(platform.writeProperties, [BleOutputProperty.withResponse]);
      platform.writeError = null;
      await sensor.disconnect();
      expect(manager.bleService.registry.activeBindingCount, 0);
    },
  );
}
