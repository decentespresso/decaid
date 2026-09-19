import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/scale.dart';
import 'package:reaprime/src/plugins/plugin_ble_registry.dart';
import 'package:reaprime/src/plugins/plugin_ble_session.dart';
import 'package:reaprime/src/plugins/plugin_manager.dart';
import 'package:reaprime/src/plugins/plugin_protocol_device.dart';

import '../helpers/skale_plugin_fixture.dart';
import 'plugin_test_helpers.dart';

final _settings = SkaleSettingsFixture();

void main() {
  setUpAll(() async {
    await _settings.start();
  });
  setUp(() {
    _settings.values.clear();
    _settings.defaultUsbPower = false;
    _settings.defaultSquareAction = false;
    _settings.error = false;
    _settings.delay = Duration.zero;
    _settings.machineDelay = Duration.zero;
    _settings.holdStartResponse = null;
    _settings.startRequestStarted = null;
    _settings.scaleConnections = {'primary': null};
    _settings.machineState = {
      'deviceId': 'MockDe1',
      'connectionGeneration': 1,
      'state': {'state': 'idle', 'substate': 'idle'},
    };
    _settings.machineInfo = {
      'version': '1.0',
      'model': 'MockDe1',
      'serialNumber': 'mock',
      'GHC': false,
    };
    _settings.machineRequests.clear();
  });

  tearDownAll(() async {
    await _settings.close();
  });

  test(
    'Skale protocol waits for a valid live weight and parses 4/5/9 bytes',
    () => _withSettings(() async {
      final manager = PluginManager(kvStore: FakeKeyValueStoreService());
      addTearDown(manager.dispose);
      await loadSkalePlugin(manager);

      final transport = SkalePluginTransport('AA:BB');
      final evidence = BleAdvertisementEvidence(
        name: 'Skale2',
        serviceUuids: ['ff08'],
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
      final snapshots = <ScaleSnapshot>[];
      final snapshotSubscription = scale.currentSnapshot.listen(snapshots.add);
      addTearDown(snapshotSubscription.cancel);
      (scale as ScaleSnapshotHandoff).activateSnapshots();

      final connecting = scale.onConnect();
      await transport.weightSubscribed.future.timeout(
        const Duration(seconds: 5),
      );
      transport.emitWeight([1, 2]);
      transport.emitWeight([0, 0, 0, 0, 0, 0]);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      var connected = false;
      connecting.then((_) => connected = true);
      await Future<void>.delayed(Duration.zero);
      expect(connected, isFalse);

      transport.emitWeight(skaleFourBytePacket(99));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(connected, isFalse);

      await transport.finalEnable.future.timeout(const Duration(seconds: 5));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      transport.emitWeight(skaleFourBytePacket(100));
      await connecting.timeout(const Duration(seconds: 5));
      (scale as ScaleSnapshotHandoff).activateSnapshots();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(snapshots.single.weight, closeTo(100, 0.001));
      expect(snapshots.single.batteryLevel, 80);

      transport.emitWeight(skaleFiveBytePacket(12.34));
      transport.emitWeight(skaleNineBytePacket(-12.34));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(snapshots.map((snapshot) => snapshot.weight), [
        100,
        12.34,
        -12.34,
      ]);

      await scale.disconnect();
    }),
  );

  test(
    'Skale host binding limit rejects a second connection without harming the first',
    () => _withSettings(() async {
      final manager = PluginManager(
        kvStore: FakeKeyValueStoreService(),
        bleRegistry: PluginBleRegistry(activeBindingLimit: 1),
      );
      addTearDown(manager.dispose);
      await loadSkalePlugin(manager);
      final evidence = BleAdvertisementEvidence(serviceUuids: ['ff08']);
      final driver = manager.bleService.registry
          .decide(evidence)
          .drivers
          .single;
      final firstTransport = SkalePluginTransport('AA:01');
      final first =
          await manager.bleService.createCandidate(
                driver: driver,
                physicalId: 'AA:01',
                evidence: evidence,
                admit: () => true,
                createTransport: () => firstTransport,
              )
              as Scale;
      final firstSnapshots = <ScaleSnapshot>[];
      final firstSubscription = first.currentSnapshot.listen(
        firstSnapshots.add,
      );
      addTearDown(firstSubscription.cancel);
      (first as ScaleSnapshotHandoff).activateSnapshots();
      final firstConnecting = first.onConnect();
      await firstTransport.finalEnable.future;
      await Future<void>.delayed(const Duration(milliseconds: 20));
      firstTransport.emitWeight(skaleFourBytePacket(1));
      await firstConnecting;
      (first as ScaleSnapshotHandoff).activateSnapshots();

      final second = SkalePluginTransport('AA:02');
      final secondScale =
          await manager.bleService.createCandidate(
                driver: driver,
                physicalId: 'AA:02',
                evidence: evidence,
                admit: () => true,
                createTransport: () => second,
              )
              as Scale;
      await expectLater(
        secondScale.onConnect(),
        throwsA(
          isA<PluginBleException>().having(
            (error) => error.code,
            'code',
            'resource_limit',
          ),
        ),
      );
      firstTransport.emitWeight(skaleFourBytePacket(2));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(firstTransport.connectCalls, 1);
      expect(second.connectCalls, 0);
      expect(firstTransport.states.value, ConnectionState.connected);
      expect(manager.bleService.registry.activeBindingCount, 1);
      expect(firstSnapshots.last.weight, closeTo(2, 0.001));
      await first.disconnect();
      await manager.bleService.discard(secondScale);
    }),
  );

  test(
    'Skale initializes display and timer/tare writes without response',
    () => _withSettings(() async {
      final manager = PluginManager(kvStore: FakeKeyValueStoreService());
      addTearDown(manager.dispose);
      await loadSkalePlugin(manager);

      final transport = SkalePluginTransport('AA:BB');
      final evidence = BleAdvertisementEvidence(
        name: 'Skale2',
        serviceUuids: ['ff08'],
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
      final connecting = scale.onConnect();
      await transport.finalEnable.future.timeout(const Duration(seconds: 5));
      transport.emitWeight(skaleFourBytePacket(1));
      await connecting.timeout(const Duration(seconds: 5));
      await scale.tare();
      await scale.startTimer();
      await scale.stopTimer();
      await scale.resetTimer();
      await scale.sleepDisplay();
      await scale.wakeDisplay();

      expect(
        transport.writes.map((write) => write.data.toList()),
        containsAllInOrder([
          [0xed],
          [0xec],
          [0xed],
          [0xec],
          [0x03],
          [0x10],
          [0xdd],
          [0xd1],
          [0xd0],
          [0xee],
          [0xed],
          [0xec],
        ]),
      );
      expect(transport.writes.every((write) => !write.withResponse), isTrue);
      await scale.disconnect();
      expect(transport.writes.last.data.toList(), [0xee]);
    }),
  );

  test(
    'Skale cancels readiness when disconnected and fences a same-ID reconnect',
    () => _withSettings(() async {
      _settings.defaultUsbPower = true;
      final manager = PluginManager(
        kvStore: FakeKeyValueStoreService(),
        bleRegistry: PluginBleRegistry(activeBindingLimit: 1),
      );
      addTearDown(manager.dispose);
      await loadSkalePlugin(manager);
      final evidence = BleAdvertisementEvidence(serviceUuids: ['ff08']);
      final driver = manager.bleService.registry
          .decide(evidence)
          .drivers
          .single;
      final transports = <SkalePluginTransport>[];
      Future<Scale> candidate() async =>
          await manager.bleService.createCandidate(
                driver: driver,
                physicalId: 'AA:01',
                evidence: evidence,
                admit: () => true,
                createTransport: () {
                  final transport = SkalePluginTransport('AA:01');
                  transports.add(transport);
                  return transport;
                },
              )
              as Scale;

      final first = await candidate();
      final firstConnecting = first.onConnect();
      final firstTransport = transports.single;
      await firstTransport.finalEnable.future.timeout(
        const Duration(seconds: 5),
      );
      firstTransport.emitWeight(skaleFourBytePacket(1));
      await firstConnecting.timeout(const Duration(seconds: 5));
      final retiredSubscriber =
          firstTransport.subscribers[skaleWeightCharacteristicUuid];
      firstTransport.dropLink();
      for (var i = 0; i < 3; i++) {
        await pumpEventQueue();
      }
      expect(manager.bleService.registry.activeBindingCount, 0);
      await manager.bleService.discard(first);

      final second = await candidate();
      final secondSnapshots = <ScaleSnapshot>[];
      final secondSubscription = second.currentSnapshot.listen(
        secondSnapshots.add,
      );
      addTearDown(secondSubscription.cancel);
      final secondConnecting = second.onConnect();
      while (transports.length < 2) {
        await pumpEventQueue();
      }
      final secondTransport = transports.last;
      await secondTransport.finalEnable.future.timeout(
        const Duration(seconds: 5),
      );
      secondTransport.emitWeight(skaleFourBytePacket(7));
      await pumpEventQueue();
      await secondConnecting.timeout(const Duration(seconds: 5));
      (second as ScaleSnapshotHandoff).activateSnapshots();

      final settingsResponse = manager.registerPendingHttp(
        skaleManifest().id,
        'reconnect-settings',
      );
      manager.dispatchEvent(skaleManifest().id, 'httpRequest', {
        'requestId': 'reconnect-settings',
        'endpoint': 'device-settings',
        'method': 'POST',
        'headers': <String, String>{},
        'body': {'usbPower': false},
        'query': {'deviceId': second.deviceId},
      });
      expect((await settingsResponse)['status'], 200);
      expect(secondTransport.batteryReads, 1);

      retiredSubscriber?.call(Uint8List.fromList(skaleFourBytePacket(99)));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(secondSnapshots.map((snapshot) => snapshot.weight), [7]);
      await second.disconnect();
    }),
  );

  test(
    'Skale rejects pending readiness when the link drops',
    () => _withSettings(() async {
      final manager = PluginManager(kvStore: FakeKeyValueStoreService());
      addTearDown(manager.dispose);
      await loadSkalePlugin(manager);
      final evidence = BleAdvertisementEvidence(serviceUuids: ['ff08']);
      final driver = manager.bleService.registry
          .decide(evidence)
          .drivers
          .single;
      final transport = SkalePluginTransport('AA:02');
      final scale =
          await manager.bleService.createCandidate(
                driver: driver,
                physicalId: 'AA:02',
                evidence: evidence,
                admit: () => true,
                createTransport: () => transport,
              )
              as Scale;
      final connecting = scale.onConnect();
      final readinessFailure = expectLater(connecting, throwsA(isA<Object>()));
      transport.dropLink();
      await readinessFailure;
    }),
  );

  test(
    'Skale publishes optional firmware and battery metadata after readiness',
    () => _withSettings(() async {
      final manager = PluginManager(kvStore: FakeKeyValueStoreService());
      addTearDown(manager.dispose);
      await loadSkalePlugin(manager);
      final transport = SkalePluginTransport(
        'AA:03',
        deviceInformationPresent: true,
        firmwareValue: [...'R029'.codeUnits, 0, 0],
      );
      final evidence = BleAdvertisementEvidence(serviceUuids: ['ff08']);
      final scale =
          await manager.bleService.createCandidate(
                driver: manager.bleService.registry
                    .decide(evidence)
                    .drivers
                    .single,
                physicalId: 'AA:03',
                evidence: evidence,
                admit: () => true,
                createTransport: () => transport,
              )
              as Scale;
      final metadata = (scale as DeviceInformationCapable).deviceInformation
          .firstWhere((info) => info?.firmwareVersion == 'R029');
      final connecting = scale.onConnect();
      await transport.finalEnable.future.timeout(const Duration(seconds: 5));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      transport.emitWeight(skaleFourBytePacket(3));
      await connecting.timeout(const Duration(seconds: 5));
      final info = await metadata.timeout(const Duration(seconds: 5));
      expect(info?.firmwareVersion, 'R029');
      expect(info?.batteryLevel, 80);
      await scale.disconnect();
    }),
  );

  test(
    'Skale publishes battery metadata when device information is absent',
    () => _withSettings(() async {
      final manager = PluginManager(kvStore: FakeKeyValueStoreService());
      addTearDown(manager.dispose);
      await loadSkalePlugin(manager);
      final transport = SkalePluginTransport(
        'AA:04',
        batteryPresent: true,
        deviceInformationPresent: false,
      );
      final evidence = BleAdvertisementEvidence(serviceUuids: ['ff08']);
      final scale =
          await manager.bleService.createCandidate(
                driver: manager.bleService.registry
                    .decide(evidence)
                    .drivers
                    .single,
                physicalId: 'AA:04',
                evidence: evidence,
                admit: () => true,
                createTransport: () => transport,
              )
              as Scale;
      final info = (scale as DeviceInformationCapable).deviceInformation
          .firstWhere((value) => value?.batteryLevel == 80);
      final connecting = scale.onConnect();
      await transport.finalEnable.future.timeout(const Duration(seconds: 5));
      transport.emitWeight(skaleFourBytePacket(4));
      await connecting.timeout(const Duration(seconds: 5));
      final metadata = await info.timeout(const Duration(seconds: 5));
      expect(metadata?.firmwareVersion, isNull);
      expect(metadata?.batteryLevel, 80);
      expect(transport.batteryReads, 1);
      await scale.disconnect();
    }),
  );

  test(
    'Skale device settings endpoint validates the per-device declaration',
    () => _withSettings(() async {
      final manager = PluginManager(kvStore: FakeKeyValueStoreService());
      addTearDown(manager.dispose);
      await loadSkalePlugin(manager);

      final responseFuture = manager.registerPendingHttp(
        skaleManifest().id,
        'settings-invalid',
      );
      manager.dispatchEvent(skaleManifest().id, 'httpRequest', {
        'requestId': 'settings-invalid',
        'endpoint': 'device-settings',
        'method': 'POST',
        'headers': <String, String>{},
        'body': {'usbPower': 'yes'},
        'query': {'deviceId': 'plugin:skale.reaplugin:skale:AA:01'},
      });
      final response = await responseFuture.timeout(const Duration(seconds: 5));
      expect(response['status'], 400);
    }),
  );

  test(
    'Skale device settings page exposes USB without machine controls',
    () => _withSettings(() async {
      final manager = PluginManager(kvStore: FakeKeyValueStoreService());
      addTearDown(manager.dispose);
      await loadSkalePlugin(manager);
      final responseFuture = manager.registerPendingHttp(
        skaleManifest().id,
        'settings-page',
      );
      manager.dispatchEvent(skaleManifest().id, 'httpRequest', {
        'requestId': 'settings-page',
        'endpoint': 'device-settings',
        'method': 'GET',
        'headers': <String, String>{},
        'query': {'ui': '1'},
      });
      final response = await responseFuture.timeout(const Duration(seconds: 5));
      expect(response['status'], 200);
      expect(response['body'], contains('name="viewport"'));
      expect(response['body'], contains('system-ui'));
      expect(response['body'], contains('deviceName'));
      expect(response['body'], contains('USB powered'));
      expect(response['body'], isNot(contains('squareAction')));
    }),
  );

  test(
    'Skale optional firmware read failure does not block first weight',
    () => _withSettings(() async {
      final manager = PluginManager(kvStore: FakeKeyValueStoreService());
      addTearDown(manager.dispose);
      await loadSkalePlugin(manager);
      final transport = SkalePluginTransport(
        'AA:04',
        deviceInformationPresent: true,
      );
      final evidence = BleAdvertisementEvidence(serviceUuids: ['ff08']);
      final scale =
          await manager.bleService.createCandidate(
                driver: manager.bleService.registry
                    .decide(evidence)
                    .drivers
                    .single,
                physicalId: 'AA:04',
                evidence: evidence,
                admit: () => true,
                createTransport: () => transport,
              )
              as Scale;
      final connecting = scale.onConnect();
      await transport.finalEnable.future.timeout(const Duration(seconds: 5));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      transport.emitWeight(skaleFourBytePacket(4));
      await connecting.timeout(const Duration(seconds: 5));
      await scale.disconnect();
    }),
  );

  test(
    'Skale waits for a delayed enabled setting instead of reading battery',
    () => _withSettings(() async {
      _settings.defaultUsbPower = true;
      _settings.delay = const Duration(milliseconds: 100);
      final manager = PluginManager(kvStore: FakeKeyValueStoreService());
      addTearDown(manager.dispose);
      await loadSkalePlugin(manager);
      final transport = SkalePluginTransport('AA:05');
      final evidence = BleAdvertisementEvidence(serviceUuids: ['ff08']);
      final scale =
          await manager.bleService.createCandidate(
                driver: manager.bleService.registry
                    .decide(evidence)
                    .drivers
                    .single,
                physicalId: 'AA:05',
                evidence: evidence,
                admit: () => true,
                createTransport: () => transport,
              )
              as Scale;
      final connecting = scale.onConnect();
      await transport.finalEnable.future.timeout(const Duration(seconds: 5));
      transport.emitWeight(skaleFourBytePacket(5));
      await connecting.timeout(const Duration(seconds: 5));
      expect(transport.batteryReads, 0);
      await scale.disconnect();
    }),
  );

  test(
    'Skale setting enable fences an in-flight battery publication',
    () => _withSettings(() async {
      final manager = PluginManager(kvStore: FakeKeyValueStoreService());
      addTearDown(manager.dispose);
      await loadSkalePlugin(manager);
      final transport = SkalePluginTransport(
        'AA:07',
        batteryReadDelay: const Duration(milliseconds: 100),
      );
      final evidence = BleAdvertisementEvidence(serviceUuids: ['ff08']);
      final scale =
          await manager.bleService.createCandidate(
                driver: manager.bleService.registry
                    .decide(evidence)
                    .drivers
                    .single,
                physicalId: 'AA:07',
                evidence: evidence,
                admit: () => true,
                createTransport: () => transport,
              )
              as Scale;
      final connecting = scale.onConnect();
      await transport.finalEnable.future;
      transport.emitWeight(skaleFourBytePacket(7));
      await connecting;
      await Future<void>.delayed(const Duration(milliseconds: 10));
      final responseFuture = manager.registerPendingHttp(
        skaleManifest().id,
        'battery-enable',
      );
      manager.dispatchEvent(skaleManifest().id, 'httpRequest', {
        'requestId': 'battery-enable',
        'endpoint': 'device-settings',
        'method': 'POST',
        'headers': <String, String>{},
        'body': {'usbPower': true},
        'query': {'deviceId': scale.deviceId},
      });
      expect((await responseFuture)['status'], 200);
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(
        (scale as DeviceInformationCapable).currentDeviceInformation,
        isNull,
      );
      await scale.disconnect();
    }),
  );

  test(
    'Skale setting disable waits for the old read before refreshing battery',
    () => _withSettings(() async {
      final manager = PluginManager(kvStore: FakeKeyValueStoreService());
      addTearDown(manager.dispose);
      await loadSkalePlugin(manager);
      final transport = SkalePluginTransport(
        'AA:08',
        batteryReadDelay: const Duration(milliseconds: 100),
      )..batteryValues.addAll([81, 42]);
      final evidence = BleAdvertisementEvidence(serviceUuids: ['ff08']);
      final scale =
          await manager.bleService.createCandidate(
                driver: manager.bleService.registry
                    .decide(evidence)
                    .drivers
                    .single,
                physicalId: 'AA:08',
                evidence: evidence,
                admit: () => true,
                createTransport: () => transport,
              )
              as Scale;
      final connecting = scale.onConnect();
      await transport.finalEnable.future;
      transport.emitWeight(skaleFourBytePacket(8));
      await connecting;
      await Future<void>.delayed(const Duration(milliseconds: 10));

      Future<Map<String, dynamic>> updateSettings(
        String requestId,
        bool usb,
      ) async {
        final response = manager.registerPendingHttp(
          skaleManifest().id,
          requestId,
        );
        manager.dispatchEvent(skaleManifest().id, 'httpRequest', {
          'requestId': requestId,
          'endpoint': 'device-settings',
          'method': 'POST',
          'headers': <String, String>{},
          'body': {'usbPower': usb},
          'query': {'deviceId': scale.deviceId},
        });
        return response;
      }

      final enable = updateSettings('battery-enable-pending', true);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      final disable = updateSettings('battery-disable-pending', false);
      expect((await enable)['status'], 200);
      expect((await disable)['status'], 200);
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(transport.batteryReads, 2);
      expect(
        (scale as DeviceInformationCapable)
            .currentDeviceInformation
            ?.batteryLevel,
        42,
      );
      await scale.disconnect();
    }),
  );

  test(
    'Skale does not fall back to battery reads when settings fail',
    () => _withSettings(() async {
      _settings.error = true;
      final manager = PluginManager(kvStore: FakeKeyValueStoreService());
      addTearDown(manager.dispose);
      await loadSkalePlugin(manager);
      final transport = SkalePluginTransport('AA:06');
      final evidence = BleAdvertisementEvidence(serviceUuids: ['ff08']);
      final scale =
          await manager.bleService.createCandidate(
                driver: manager.bleService.registry
                    .decide(evidence)
                    .drivers
                    .single,
                physicalId: 'AA:06',
                evidence: evidence,
                admit: () => true,
                createTransport: () => transport,
              )
              as Scale;
      final connecting = scale.onConnect();
      await expectLater(connecting, throwsA(isA<Object>()));
      expect(transport.batteryReads, 0);
    }),
  );

  test(
    'Skale square button has no machine action in the runtime consumer',
    () => _withSettings(() async {
      _settings.defaultSquareAction = true;
      final manager = PluginManager(kvStore: FakeKeyValueStoreService());
      addTearDown(manager.dispose);
      await loadSkalePlugin(manager);
      final evidence = BleAdvertisementEvidence(serviceUuids: ['ff08']);
      final transport = SkalePluginTransport('AA:12');
      final scale =
          await manager.bleService.createCandidate(
                driver: manager.bleService.registry
                    .decide(evidence)
                    .drivers
                    .single,
                physicalId: 'AA:12',
                evidence: evidence,
                admit: () => true,
                createTransport: () => transport,
              )
              as Scale;
      final connecting = scale.onConnect();
      await transport.finalEnable.future;
      transport.emitWeight(skaleFourBytePacket(1));
      await connecting;
      final session = scale as PluginProtocolDevice;
      _settings.scaleConnections = {
        'primary': {
          'deviceId': scale.deviceId,
          'connectionId': session.connectionId,
          'selectionId': 'primary-selection',
        },
      };
      transport.emitButton(2);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(_settings.machineRequests, isEmpty);
      await scale.disconnect();
    }),
  );
}

Future<T> _withSettings<T>(Future<T> Function() body) async {
  HttpOverrides.global = SkaleSettingsHttpOverrides(_settings);
  try {
    return await body();
  } finally {
    HttpOverrides.global = null;
  }
}
