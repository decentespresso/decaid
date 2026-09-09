import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/scale_controller.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/scale.dart';
import 'package:reaprime/src/plugins/plugin_ble_registry.dart';
import 'package:reaprime/src/plugins/plugin_manager.dart';

import '../helpers/bookoo_packets.dart';
import '../helpers/bookoo_plugin_fixture.dart';
import 'plugin_test_helpers.dart';

void main() {
  test(
    'Bookoo subscription setup does not consume the packet deadline',
    () async {
      final manager = PluginManager(kvStore: FakeKeyValueStoreService());
      final controller = ScaleController();
      addTearDown(() async {
        controller.dispose();
        await manager.dispose();
      });
      await loadBookooPlugin(manager);
      final transport = BookooPluginTransport(
        'AA:BB',
        firstPacket: bookooPacket(1),
        subscriptionDelay: const Duration(milliseconds: 2300),
      );
      final evidence = BleAdvertisementEvidence(
        name: 'Bookoo',
        serviceUuids: ['0ffe'],
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
      await controller.connectToScale(scale);
      expect(await scale.connectionState.first, ConnectionState.connected);
      expect(transport.disconnectCalls, 0);
      expect(
        transport.subscribers.keys.single,
        bookooDataCharacteristicUuid,
      );
      await scale.disconnect();
      expect(manager.activeTimerCount, 0);
    },
  );

  for (final (label, firstPacket, ready) in [
    ('no packets', null, false),
    ('malformed packet', <int>[0], false),
    ('valid packet', bookooPacket(1), true),
  ]) {
    test(
      'Bookoo protocol silence after $label reports host failure without a reconnect loop',
      () async {
        final manager = PluginManager(kvStore: FakeKeyValueStoreService());
        final controller = ScaleController();
        addTearDown(() async {
          controller.dispose();
          await manager.dispose();
        });
        await loadBookooPlugin(manager);
        final transport = BookooPluginTransport(
          'AA:BB',
          firstPacket: firstPacket,
        );
        final evidence = BleAdvertisementEvidence(
          name: 'Bookoo',
          serviceUuids: ['0ffe'],
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
        final elapsed = Stopwatch()..start();
        final connect = controller.connectToScale(scale);
        final completion = ready
            ? connect
            : expectLater(connect, throwsA(anything));
        await transport.subscribed.future;
        await scale.connectionState
            .firstWhere((state) => state == ConnectionState.disconnected)
            .timeout(const Duration(seconds: 4));
        await completion;
        expect(
          elapsed.elapsed,
          greaterThanOrEqualTo(const Duration(milliseconds: 1800)),
        );
        await transport.disposed.future.timeout(const Duration(seconds: 2));
        expect(transport.connectCalls, 1);
        expect(manager.bleService.registry.activeBindingCount, 0);
        expect(manager.activeTimerCount, 0);
      },
    );
  }

  test(
    'Bookoo JS validates native fixtures, readiness, commands and reconnect',
    () async {
      final manager = PluginManager(kvStore: FakeKeyValueStoreService());
      final controller = ScaleController();
      final transports = <BookooPluginTransport>[];
      addTearDown(() async {
        controller.dispose();
        await manager.dispose();
      });
      await loadBookooPlugin(manager);
      final evidence = BleAdvertisementEvidence(
        name: 'BOOKOO',
        serviceUuids: ['0ffe'],
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
                createTransport: () {
                  final t = BookooPluginTransport('AA:BB');
                  transports.add(t);
                  return t;
                },
              )
              as Scale;
      for (var attempt = 0; attempt < 2; attempt++) {
        final samples = <WeightSnapshot>[];
        final subscription = controller.weightSnapshot.listen(samples.add);
        final connect = controller.connectToScale(scale);
        await Future<void>.delayed(Duration.zero);
        final transport = transports.last;
        await transport.subscribed.future;
        expect(
          transport.subscribers.keys.single,
          bookooDataCharacteristicUuid,
        );
        for (final invalid in invalidBookooPackets()) {
          transport.emit(invalid);
        }
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(await scale.connectionState.first, ConnectionState.connecting);
        expect(samples, isEmpty);
        final firstSample = controller.weightSnapshot.first;
        transport.emit(bookooPacket(123.45, battery: 101));
        await connect;
        expect((await firstSample).battery, isNull);
        final battery = controller.weightSnapshot.firstWhere(
          (s) => s.battery == 72,
        );
        transport.emit(bookooPacket(123.45, battery: 72));
        await battery;
        final negative = controller.weightSnapshot.firstWhere(
          (s) => s.weight == -12.34,
        );
        transport.emit(bookooPacket(-12.34, battery: 101));
        expect((await negative).battery, 72);
        expect(samples.map((s) => s.weight), [123.45, 123.45, -12.34]);
        await scale.tare();
        await scale.startTimer();
        await scale.stopTimer();
        await scale.resetTimer();
        expect(transport.writes.map((w) => w.data.toList()), bookooCommands);
        expect(transport.writes.every((w) => w.withResponse), isTrue);
        expect(
          transport.writes.every(
            (w) => w.characteristicUUID == bookooCommandCharacteristicUuid,
          ),
          isTrue,
        );
        final oldNotification =
            transport.subscribers[bookooDataCharacteristicUuid]!;
        await scale.sleepDisplay();
        oldNotification(Uint8List.fromList(bookooPacket(99)));
        await Future<void>.delayed(Duration.zero);
        expect(samples.last.weight, -12.34);
        expect(manager.bleService.registry.activeBindingCount, 0);
        await subscription.cancel();
      }
      expect(scale.deviceId, 'plugin:bookoo-mini.reaplugin:bookoo:aa:bb');
    },
  );

  test(
    'Bookoo reload preserves identity and fences the retired generation',
    () async {
      final manager = PluginManager(kvStore: FakeKeyValueStoreService());
      addTearDown(manager.dispose);
      final manifest = bookooManifest();
      await loadBookooPlugin(manager);
      final evidence = BleAdvertisementEvidence(
        name: 'Bookoo Mini',
        serviceUuids: ['0ffe'],
      );

      Future<Scale> createScale(BookooPluginTransport transport) async =>
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

      final firstGeneration = manager.pluginGeneration(manifest.id);
      final oldTransport = BookooPluginTransport(
        'AA:BB',
        firstPacket: bookooPacket(1),
      );
      final oldScale = await createScale(oldTransport);
      await oldScale.onConnect();
      expect(await oldScale.connectionState.first, ConnectionState.connected);
      final stableId = oldScale.deviceId;
      final oldNotification =
          oldTransport.subscribers[bookooDataCharacteristicUuid]!;

      await manager.unloadPlugin(manifest.id);
      await loadBookooPlugin(manager);
      expect(manager.pluginGeneration(manifest.id), isNot(firstGeneration));

      final newTransport = BookooPluginTransport(
        'AA:BB',
        firstPacket: bookooPacket(2),
      );
      final newScale = await createScale(newTransport);
      expect(newScale.deviceId, stableId);
      expect(identical(newScale, oldScale), isFalse);

      final samples = <ScaleSnapshot>[];
      final snapshotSubscription = newScale.currentSnapshot.listen(samples.add);
      addTearDown(snapshotSubscription.cancel);
      await newScale.onConnect();
      (newScale as ScaleSnapshotHandoff).activateSnapshots();
      await Future<void>.delayed(Duration.zero);
      expect(samples.map((sample) => sample.weight), [2]);

      await expectLater(
        oldScale.tare(),
        throwsA(
          isA<ScaleOperationException>().having(
            (error) => error.code,
            'code',
            'stale_session',
          ),
        ),
      );
      oldNotification(Uint8List.fromList(bookooPacket(99)));
      await Future<void>.delayed(Duration.zero);
      expect(samples.map((sample) => sample.weight), [2]);

      newTransport.emit(bookooPacket(3));
      await Future<void>.delayed(Duration.zero);
      expect(samples.map((sample) => sample.weight), [2, 3]);
      await newScale.disconnect();
    },
  );
}
