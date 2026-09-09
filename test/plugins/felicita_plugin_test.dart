import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/scale_controller.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/scale.dart';
import 'package:reaprime/src/plugins/plugin_manager.dart';
import 'package:reaprime/src/plugins/plugin_ble_registry.dart';

import '../helpers/felicita_plugin_fixture.dart';
import 'plugin_test_helpers.dart';

void main() {
  test(
    'Felicita JS waits for a valid first packet and maps native protocol',
    () async {
      final manager = PluginManager(kvStore: FakeKeyValueStoreService());
      final controller = ScaleController();
      addTearDown(() async {
        controller.dispose();
        await manager.dispose();
      });
      await loadFelicitaPlugin(manager);
      final evidence = BleAdvertisementEvidence(name: 'FELICITA ARC');
      final transport = FelicitaPluginTransport('AA:BB');
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
      final samples = <WeightSnapshot>[];
      final sampleSubscription = controller.weightSnapshot.listen(samples.add);
      addTearDown(sampleSubscription.cancel);
      final connect = controller.connectToScale(scale);
      await transport.subscribed.future;
      expect(await scale.connectionState.first, ConnectionState.connecting);
      transport.emit(felicitaPacket(-12.34, battery: 143));
      await connect;
      final first = await controller.weightSnapshot.first;
      expect(first.weight, -12.34);
      expect(first.battery, 48);
      final positive = controller.weightSnapshot.first;
      transport.emit(felicitaPacket(0, battery: 129, sign: 32));
      expect((await positive).weight, 0);
      expect(samples.last.battery, 0);
      final fullBattery = controller.weightSnapshot.first;
      transport.emit(felicitaPacket(1.23, battery: 158));
      expect((await fullBattery).weight, 1.23);
      expect(samples.last.battery, 100);
      final retainedBattery = controller.weightSnapshot.first;
      transport.emit(felicitaPacket(2.34, battery: 200));
      expect((await retainedBattery).weight, 2.34);
      expect(samples.last.battery, 100);
      await scale.tare();
      await scale.startTimer();
      await scale.stopTimer();
      await scale.resetTimer();
      expect(transport.writes.map((write) => write.data.single), [
        0x54,
        0x52,
        0x53,
        0x43,
      ]);
      expect(transport.writes.every((write) => write.withResponse), isTrue);
      await scale.disconnect();
    },
  );

  test(
    'Felicita invalid packets do not satisfy readiness or publish',
    () async {
      final manager = PluginManager(kvStore: FakeKeyValueStoreService());
      addTearDown(manager.dispose);
      await loadFelicitaPlugin(manager);
      final evidence = BleAdvertisementEvidence(name: 'Felicita Arc');
      final transport = FelicitaPluginTransport('AA:BB');
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
      final snapshots = <ScaleSnapshot>[];
      final snapshotSubscription = scale.currentSnapshot.listen(snapshots.add);
      addTearDown(snapshotSubscription.cancel);
      final connect = expectLater(scale.onConnect(), throwsA(anything));
      await transport.subscribed.future;
      final invalidLength = [...felicitaPacket(1), 0];
      final invalidDigit = felicitaPacket(1)..[3] = 65;
      transport.emit(invalidLength);
      transport.emit(invalidDigit);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(snapshots, isEmpty);
      await connect;
    },
  );

  test('Felicita battery starts unknown and resets between sessions', () async {
    final manager = PluginManager(kvStore: FakeKeyValueStoreService());
    addTearDown(manager.dispose);
    await loadFelicitaPlugin(manager);
    final evidence = BleAdvertisementEvidence(name: 'Felicita Arc');
    final transports = <FelicitaPluginTransport>[];
    Future<Scale> createScale({List<int>? firstPacket}) async {
      final transport = FelicitaPluginTransport(
        'AA:BB',
        firstPacket: firstPacket,
      );
      transports.add(transport);
      return await manager.bleService.createCandidate(
            driver: manager.bleService.registry.decide(evidence).drivers.single,
            physicalId: 'AA:BB',
            evidence: evidence,
            admit: () => true,
            createTransport: () => transport,
          )
          as Scale;
    }

    final first = await createScale(
      firstPacket: felicitaPacket(1, battery: 200),
    );
    final firstConnect = first.onConnect();
    await transports[0].subscribed.future;
    (first as ScaleSnapshotHandoff).activateSnapshots();
    final firstSnapshot = first.currentSnapshot.first;
    transports[0].emit(felicitaPacket(1, battery: 200));
    expect((await firstSnapshot).batteryLevel, isNull);
    await firstConnect;
    await first.disconnect();
    await transports[0].disposed.future;
    await manager.unloadPlugin(felicitaManifest().id);
    await loadFelicitaPlugin(manager);
    final second = await createScale(
      firstPacket: felicitaPacket(2, battery: 158),
    );
    final secondSnapshot = second.currentSnapshot.first;
    final secondConnect = second.onConnect();
    await transports[1].subscribed.future;
    (second as ScaleSnapshotHandoff).activateSnapshots();
    await secondConnect;
    expect((await secondSnapshot).batteryLevel, 100);
    await second.disconnect();
  });

  test('Felicita service and subscription failures reject cleanly', () async {
    final manager = PluginManager(kvStore: FakeKeyValueStoreService());
    addTearDown(manager.dispose);
    await loadFelicitaPlugin(manager);
    final evidence = BleAdvertisementEvidence(name: 'Felicita Arc');
    Future<Scale> create(FelicitaPluginTransport transport) async =>
        await manager.bleService.createCandidate(
              driver: manager.bleService.registry
                  .decide(evidence)
                  .drivers
                  .single,
              physicalId: transport.physicalId,
              evidence: evidence,
              admit: () => true,
              createTransport: () => transport,
            )
            as Scale;
    final missing = await create(
      FelicitaPluginTransport('missing', servicePresent: false),
    );
    await expectLater(missing.onConnect(), throwsA(isA<Exception>()));
    final failed = await create(
      FelicitaPluginTransport(
        'failed',
        subscriptionFailure: StateError('subscribe'),
      ),
    );
    await expectLater(failed.onConnect(), throwsA(anything));
  });

  test('Felicita delayed subscription and silence are host-owned', () async {
    final manager = PluginManager(kvStore: FakeKeyValueStoreService());
    addTearDown(manager.dispose);
    await loadFelicitaPlugin(manager);
    final evidence = BleAdvertisementEvidence(name: 'Felicita Arc');
    final delayedTransport = FelicitaPluginTransport(
      'delayed',
      firstPacket: felicitaPacket(1),
      subscriptionDelay: const Duration(milliseconds: 2300),
    );
    final delayed =
        await manager.bleService.createCandidate(
              driver: manager.bleService.registry
                  .decide(evidence)
                  .drivers
                  .single,
              physicalId: 'delayed',
              evidence: evidence,
              admit: () => true,
              createTransport: () => delayedTransport,
            )
            as Scale;
    await delayed.onConnect();
    expect(await delayed.connectionState.first, ConnectionState.connected);
    await delayed.disconnect();
    final silentTransport = FelicitaPluginTransport(
      'silent',
      firstPacket: felicitaPacket(1),
    );
    final silent =
        await manager.bleService.createCandidate(
              driver: manager.bleService.registry
                  .decide(evidence)
                  .drivers
                  .single,
              physicalId: 'silent',
              evidence: evidence,
              admit: () => true,
              createTransport: () => silentTransport,
            )
            as Scale;
    await silent.onConnect();
    await expectLater(
      silent.connectionState.firstWhere(
        (s) => s == ConnectionState.disconnected,
      ),
      completes,
    );
  });

  test('Felicita matcher unload removes plugin ownership', () async {
    final manager = PluginManager(kvStore: FakeKeyValueStoreService());
    addTearDown(manager.dispose);
    await loadFelicitaPlugin(manager);
    final matching = BleAdvertisementEvidence(name: 'FELICITA ARC');
    expect(manager.bleService.registry.decide(matching).drivers, hasLength(1));
    expect(
      manager.bleService.registry
          .decide(BleAdvertisementEvidence(name: 'Bookoo'))
          .drivers,
      isEmpty,
    );
    await manager.unloadPlugin(felicitaManifest().id);
    expect(manager.bleService.registry.decide(matching).drivers, isEmpty);
  });

  test('Felicita reload fences old callbacks and preserves identity', () async {
    final manager = PluginManager(kvStore: FakeKeyValueStoreService());
    addTearDown(manager.dispose);
    await loadFelicitaPlugin(manager);
    final evidence = BleAdvertisementEvidence(name: 'Felicita Arc');
    final firstTransport = FelicitaPluginTransport(
      'AA:BB',
      firstPacket: felicitaPacket(1),
    );
    final first =
        await manager.bleService.createCandidate(
              driver: manager.bleService.registry
                  .decide(evidence)
                  .drivers
                  .single,
              physicalId: 'AA:BB',
              evidence: evidence,
              admit: () => true,
              createTransport: () => firstTransport,
            )
            as Scale;
    final firstConnect = first.onConnect();
    await firstTransport.subscribed.future;
    final oldCallback = firstTransport.subscribers[felicitaCharacteristicUuid]!;
    await firstConnect;
    final stableId = first.deviceId;
    await manager.unloadPlugin(felicitaManifest().id);
    await loadFelicitaPlugin(manager);
    final secondTransport = FelicitaPluginTransport(
      'AA:BB',
      firstPacket: felicitaPacket(2),
    );
    final second =
        await manager.bleService.createCandidate(
              driver: manager.bleService.registry
                  .decide(evidence)
                  .drivers
                  .single,
              physicalId: 'AA:BB',
              evidence: evidence,
              admit: () => true,
              createTransport: () => secondTransport,
            )
            as Scale;
    final snapshots = <ScaleSnapshot>[];
    final subscription = second.currentSnapshot.listen(snapshots.add);
    addTearDown(subscription.cancel);
    final secondConnect = second.onConnect();
    await secondTransport.subscribed.future;
    (second as ScaleSnapshotHandoff).activateSnapshots();
    await secondConnect;
    expect(second.deviceId, stableId);
    oldCallback(Uint8List.fromList(felicitaPacket(99)));
    await Future<void>.delayed(Duration.zero);
    expect(snapshots.map((sample) => sample.weight), [2]);
    await second.disconnect();
  });

  test('Felicita command write failures remain visible', () async {
    final manager = PluginManager(kvStore: FakeKeyValueStoreService());
    addTearDown(manager.dispose);
    await loadFelicitaPlugin(manager);
    final evidence = BleAdvertisementEvidence(name: 'Felicita Arc');
    final transport = FelicitaPluginTransport(
      'AA:BB',
      firstPacket: felicitaPacket(1),
      writeFailure: StateError('write'),
    );
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
    await scale.onConnect();
    await expectLater(scale.tare(), throwsA(isA<ScaleOperationException>()));
  });
}
