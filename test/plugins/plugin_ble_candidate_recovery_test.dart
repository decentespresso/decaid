import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/scale.dart';
import 'package:reaprime/src/plugins/plugin_ble_registry.dart';
import 'package:reaprime/src/plugins/plugin_manager.dart';

import '../helpers/felicita_plugin_fixture.dart';
import 'plugin_test_helpers.dart';

/// Host BLE candidate recovery after an in-process disconnect (#809).
///
/// A deliberate disconnect closes the binding session and the discovery
/// inventory drops the device. A subsequent advertisement must create a fresh
/// candidate, not reuse the retired device whose replayed `disconnected` state
/// can never be re-adopted (observed on hardware: device stuck unavailable
/// until an app restart).
void main() {
  test('a retired binding is discarded so a new advertisement creates a fresh '
      'reconnectable candidate', () async {
    final manager = PluginManager(kvStore: FakeKeyValueStoreService());
    addTearDown(manager.dispose);
    await loadFelicitaPlugin(manager);
    final evidence = BleAdvertisementEvidence(name: 'Felicita Arc');
    final transports = <FelicitaPluginTransport>[];

    Future<Scale> createCandidate() async =>
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
                  firstPacket: felicitaPacket(1),
                );
                transports.add(transport);
                return transport;
              },
            )
            as Scale;

    final first = await createCandidate();
    expect(manager.bleService.registry.activeBindingCount, 0);
    await first.onConnect();
    expect(await first.connectionState.first, ConnectionState.connected);
    expect(manager.bleService.registry.activeBindingCount, 1);

    // Concurrent advertisements while connected must not duplicate.
    final concurrent = await createCandidate();
    expect(identical(concurrent, first), isTrue);

    await first.disconnect();
    expect(await first.connectionState.first, ConnectionState.disconnected);
    expect(manager.bleService.registry.activeBindingCount, 0);

    // The retired binding must not be reused: a fresh advertisement yields a
    // new device in the discovered state that can connect again.
    final second = await createCandidate();
    expect(identical(second, first), isFalse);
    expect(await second.connectionState.first, ConnectionState.discovered);
    await second.onConnect();
    expect(await second.connectionState.first, ConnectionState.connected);
    expect(transports, hasLength(2));
    expect(transports[1].connectCalls, 1);
    expect(manager.bleService.registry.activeBindingCount, 1);
    await second.disconnect();
    expect(manager.bleService.registry.activeBindingCount, 0);
  });

  test(
    'stale callbacks from the retired binding cannot publish or reconnect',
    () async {
      final manager = PluginManager(kvStore: FakeKeyValueStoreService());
      addTearDown(manager.dispose);
      await loadFelicitaPlugin(manager);
      final evidence = BleAdvertisementEvidence(name: 'Felicita Arc');
      final transports = <FelicitaPluginTransport>[];

      Future<Scale> createCandidate() async =>
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
                    firstPacket: felicitaPacket(1),
                  );
                  transports.add(transport);
                  return transport;
                },
              )
              as Scale;

      final first = await createCandidate();
      await first.onConnect();
      final stale = transports[0].subscribers[felicitaCharacteristicUuid]!;
      await first.disconnect();

      final second = await createCandidate();
      expect(identical(second, first), isFalse);
      final samples = <ScaleSnapshot>[];
      final subscription = second.currentSnapshot.listen(samples.add);
      addTearDown(subscription.cancel);
      final secondConnect = second.onConnect();
      await transports[1].subscribed.future;
      (second as ScaleSnapshotHandoff).activateSnapshots();
      await secondConnect;
      await Future<void>.delayed(Duration.zero);
      expect(samples.map((sample) => sample.weight), [1]);

      // The retired transport callback cannot publish into the new session.
      stale(Uint8List.fromList(felicitaPacket(99)));
      await Future<void>.delayed(Duration.zero);
      expect(samples.map((sample) => sample.weight), [1]);

      // The retired device object cannot command the replacement session.
      await expectLater(
        first.tare(),
        throwsA(
          isA<ScaleOperationException>().having(
            (error) => error.code,
            'code',
            'stale_session',
          ),
        ),
      );
      await second.disconnect();
    },
  );
}
