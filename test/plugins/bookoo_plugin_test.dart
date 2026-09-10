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
      expect(transport.subscribers.keys.single, bookooDataCharacteristicUuid);
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

  Future<Scale> bookooCandidate(
    PluginManager manager,
    BookooPluginTransport transport,
  ) async {
    final evidence = BleAdvertisementEvidence(
      name: 'BOOKOO',
      serviceUuids: ['0ffe'],
    );
    return await manager.bleService.createCandidate(
          driver: manager.bleService.registry.decide(evidence).drivers.single,
          physicalId: 'AA:BB',
          evidence: evidence,
          admit: () => true,
          createTransport: () => transport,
        )
        as Scale;
  }

  test(
    'Bookoo refused subscription fails the attempt without leftovers',
    () async {
      final manager = PluginManager(kvStore: FakeKeyValueStoreService());
      addTearDown(manager.dispose);
      await loadBookooPlugin(manager);
      final transport = BookooPluginTransport(
        'AA:BB',
        subscriptionFailure: StateError('Bookoo subscription refused'),
      );
      final scale = await bookooCandidate(manager, transport);
      final states = <ConnectionState>[];
      final subscription = scale.connectionState.listen(states.add);
      addTearDown(subscription.cancel);

      final outcome = await scale.onConnect().then<Object?>(
        (_) => null,
        onError: (Object error) => error,
      );
      expect(
        outcome,
        isNotNull,
        reason: 'a refused subscription must fail the attempt',
      );

      // Startup teardown already retired the session here, so a late link drop
      // cannot be delivered through this seam: the abandoned readiness promise
      // and its later disconnect rejection are asserted by the plugin-runtime
      // harness in scripts/test_bookoo_readiness_rejection.mjs. This test covers
      // the observable leftovers instead.
      transport.dropLink();
      await pumpEventQueue();

      expect(states, isNot(contains(ConnectionState.connected)));
      expect(manager.activeTimerCount, 0);
      expect(manager.bleService.registry.activeBindingCount, 0);
    },
  );

  test(
    'Bookoo disconnect before the first packet reports the disconnect',
    () async {
      final manager = PluginManager(kvStore: FakeKeyValueStoreService());
      addTearDown(manager.dispose);
      await loadBookooPlugin(manager);
      final transport = BookooPluginTransport('AA:BB');
      final scale = await bookooCandidate(manager, transport);

      final connecting = scale.onConnect().then<Object?>(
        (_) => null,
        onError: (Object error) => error,
      );
      await transport.subscribed.future;
      transport.dropLink();

      final outcome = await connecting;
      expect(
        outcome,
        isNotNull,
        reason: 'a link loss before readiness must fail the attempt',
      );
      expect(await scale.connectionState.first, ConnectionState.disconnected);
      expect(manager.activeTimerCount, 0);
      expect(manager.bleService.registry.activeBindingCount, 0);
    },
  );

  test('Bookoo keeps publishing after readiness', () async {
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
    );
    final scale = await bookooCandidate(manager, transport);
    final samples = <WeightSnapshot>[];
    final subscription = controller.weightSnapshot.listen(samples.add);
    addTearDown(subscription.cancel);

    await controller.connectToScale(scale);
    expect(await scale.connectionState.first, ConnectionState.connected);

    transport.emit(bookooPacket(-12.5));
    await pumpEventQueue();

    expect(
      samples,
      isNotEmpty,
      reason: 'a successful start must not stop the live session',
    );
    expect(samples.last.weight, closeTo(-12.5, 1e-9));
    expect(
      manager.activeTimerCount,
      1,
      reason: 'the live session keeps exactly one silence watchdog armed',
    );

    await scale.disconnect();
    await pumpEventQueue();
    expect(
      manager.activeTimerCount,
      0,
      reason: 'teardown must not leave a watchdog armed',
    );
  });

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
        expect(transport.subscribers.keys.single, bookooDataCharacteristicUuid);
        for (final invalid in invalidBookooPackets()) {
          transport.emit(invalid);
        }
        await pumpEventQueue();
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

      final weightThree = newScale.currentSnapshot.firstWhere(
        (sample) => sample.weight == 3,
      );
      newTransport.emit(bookooPacket(3));
      await weightThree.timeout(const Duration(seconds: 1));
      expect(samples.map((sample) => sample.weight), [2, 3]);
      await newScale.disconnect();
    },
  );
}
