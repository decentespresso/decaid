import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/scale_controller.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/scale.dart';
import 'package:reaprime/src/models/device/sensor.dart';
import 'package:reaprime/src/plugins/plugin_ble_registry.dart';
import 'package:reaprime/src/plugins/plugin_manager.dart';
import 'package:reaprime/src/services/ble/universal_ble_transport.dart';
import 'package:universal_ble/universal_ble.dart';

import '../helpers/felicita_plugin_fixture.dart';
import '../helpers/plugin_ble_fixture.dart';
import 'plugin_manager_ble_test.dart' show bleSensorManifest, bleSensorSource;
import 'plugin_test_helpers.dart';

/// Cross-layer interactions between the BLE queue, the transport and a live
/// plugin session (#809).
///
/// Stage 1 owns the queue-level behaviour and Stage 2 owns the connection-phase
/// deadlines; these compose them through a real plugin binding. The slow
/// recovery cases live in `plugin_ble_connect_phases_test.dart` and
/// `plugin_ble_bluez_recovery_test.dart`.
void main() {
  test(
    'a stale disconnect with queued GATT work leaves the plugin session live',
    () async {
      final platform = PluginBleFixturePlatform();
      UniversalBle.setInstance(platform);
      UniversalBle.queueType = QueueType.perDevice;
      addTearDown(() {
        UniversalBle.clearQueue();
        UniversalBle.queueType = QueueType.global;
      });

      final manager = PluginManager(kvStore: FakeKeyValueStoreService());
      addTearDown(manager.dispose);
      await manager.loadPlugin(
        id: 'ble.sensor',
        manifest: bleSensorManifest(),
        settings: {},
        jsCode: bleSensorSource,
      );

      const deviceId = 'AA:BB';
      const serviceUuid = '0000180f-0000-1000-8000-00805f9b34fb';
      const characteristicUuid = '00002a19-0000-1000-8000-00805f9b34fb';
      platform.connectionStates[deviceId] = BleConnectionState.connected;
      final evidence = BleAdvertisementEvidence(serviceUuids: ['180f']);
      late UniversalBleTransport transport;
      final sensor =
          await manager.bleService.createCandidate(
                driver: manager.bleService.registry
                    .decide(evidence)
                    .drivers
                    .single,
                physicalId: deviceId,
                evidence: evidence,
                admit: () => true,
                createTransport: () => transport = UniversalBleTransport(
                  device: BleDevice(deviceId: deviceId, name: 'Fixture'),
                  isAndroidOverride: false,
                  isLinuxOverride: false,
                ),
              )
              as Sensor;
      final states = <ConnectionState>[];
      final stateSubscription = sensor.connectionState.listen(states.add);
      addTearDown(stateSubscription.cancel);
      final samples = <Map<String, dynamic>>[];
      final dataSubscription = sensor.data.listen(samples.add);
      addTearDown(dataSubscription.cancel);

      await sensor.onConnect();
      expect(await sensor.connectionState.first, ConnectionState.connected);

      // Occupy the device queue, then queue a second write behind it.
      platform.hangWrites = true;
      final writeBlocker = Completer<void>();
      platform.writeBlocker = writeBlocker;
      final inFlight = transport.write(
        serviceUuid,
        characteristicUuid,
        Uint8List.fromList([1]),
      );
      final queued = transport.write(
        serviceUuid,
        characteristicUuid,
        Uint8List.fromList([2]),
      );

      // A late physical disconnect for a link the platform still reports
      // connected must not disturb the live session or its queued work.
      platform.connectionStates[deviceId] = BleConnectionState.connected;
      platform.updateConnection(deviceId, false);
      await pumpEventQueue();

      expect(
        states,
        isNot(contains(ConnectionState.disconnected)),
        reason: 'a stale disconnect must not retire the live session',
      );
      expect(
        manager.bleService.registry.activeBindingCount,
        1,
        reason: 'the session keeps its BLE ownership',
      );

      writeBlocker.complete();
      platform.hangWrites = false;
      await inFlight;
      await queued;

      platform.updateCharacteristicValue(
        deviceId,
        '2a19',
        Uint8List.fromList([52]),
        null,
      );
      await pumpEventQueue();
      expect(
        samples,
        isNotEmpty,
        reason: 'subscriptions continue after the stale event',
      );
      expect(
        await sensor.connectionState.first,
        ConnectionState.connected,
        reason: 'observed states: $states',
      );
    },
  );

  test('a genuine disconnect then reconnect gives the new session a clean '
      'start', () async {
    final manager = PluginManager(kvStore: FakeKeyValueStoreService());
    addTearDown(manager.dispose);
    await loadFelicitaPlugin(manager);
    final evidence = BleAdvertisementEvidence(name: 'Felicita Arc');
    final transports = <FelicitaPluginTransport>[];

    Future<Scale> candidate() async =>
        await manager.bleService.createCandidate(
              driver: manager.bleService.registry
                  .decide(evidence)
                  .drivers
                  .single,
              physicalId: 'AA:BB',
              evidence: evidence,
              admit: () => true,
              createTransport: () {
                final transport = FelicitaPluginTransport(
                  'AA:BB',
                  firstPacket: felicitaPacket(transports.length + 1),
                );
                transports.add(transport);
                return transport;
              },
            )
            as Scale;

    final first = await candidate();
    final firstSamples = <ScaleSnapshot>[];
    final firstSubscription = first.currentSnapshot.listen(firstSamples.add);
    addTearDown(firstSubscription.cancel);
    await first.onConnect();
    expect(await first.connectionState.first, ConnectionState.connected);
    final retiredSubscriber =
        transports.first.subscribers[felicitaCharacteristicUuid];

    // Genuine link loss: the retired session must not publish into whatever
    // replaces it.
    transports.first.states.add(ConnectionState.disconnected);
    await first.connectionState
        .firstWhere((state) => state == ConnectionState.disconnected)
        .timeout(const Duration(seconds: 2));
    await pumpEventQueue();
    expect(manager.bleService.registry.activeBindingCount, 0);

    final second = await candidate();
    final controller = ScaleController();
    addTearDown(controller.dispose);
    final secondSamples = <WeightSnapshot>[];
    final secondSubscription = controller.weightSnapshot.listen(
      secondSamples.add,
    );
    addTearDown(secondSubscription.cancel);
    await controller.connectToScale(second);
    expect(await second.connectionState.first, ConnectionState.connected);
    expect(transports, hasLength(2));
    expect(transports.last.connectCalls, 1);
    expect(manager.bleService.registry.activeBindingCount, 1);

    // The retired session cannot inject its own packets into the replacement.
    retiredSubscriber?.call(Uint8List.fromList(felicitaPacket(99)));
    await pumpEventQueue();
    expect(
      secondSamples.where((sample) => sample.weight == 99),
      isEmpty,
      reason: 'a retired generation must not publish into the new session',
    );

    transports.last.emit(felicitaPacket(7));
    await pumpEventQueue();
    expect(secondSamples.map((sample) => sample.weight), contains(7));

    await second.disconnect();
    await pumpEventQueue();
    expect(manager.bleService.registry.activeBindingCount, 0);
  });
}
