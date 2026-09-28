import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/auxiliary_scale_registry.dart';
import 'package:reaprime/src/controllers/connection_manager.dart';
import 'package:reaprime/src/controllers/device_controller.dart';
import 'package:reaprime/src/controllers/scale_controller.dart';
import 'package:reaprime/src/models/device/scale.dart';
import 'package:reaprime/src/models/scan_report.dart';
import 'package:reaprime/src/plugins/plugin_manager.dart';
import 'package:reaprime/src/plugins/plugin_ble_registry.dart';
import 'package:reaprime/src/settings/settings_controller.dart';

import '../helpers/mock_de1_controller.dart';
import '../helpers/mock_device_discovery_service.dart';
import '../helpers/mock_device_scanner.dart';
import '../helpers/mock_settings_service.dart';
import '../helpers/skale_plugin_fixture.dart';
import 'plugin_test_helpers.dart';

void main() {
  test('connects a primary and two auxiliary Skales independently', () async {
    final hostSettings = SkaleSettingsFixture();
    await hostSettings.start();
    final previousOverrides = HttpOverrides.current;
    HttpOverrides.global = SkaleSettingsHttpOverrides(hostSettings);
    addTearDown(() async {
      HttpOverrides.global = previousOverrides;
      await hostSettings.close();
    });
    final pluginManager = PluginManager(kvStore: FakeKeyValueStoreService());
    final scanner = MockDeviceScanner();
    final discovery = MockDeviceDiscoveryService();
    final devices = DeviceController([discovery]);
    final de1 = MockDe1Controller(controller: devices);
    final settings = SettingsController(MockSettingsService());
    await settings.loadSettings();
    final primaryController = ScaleController();
    final connectionManager = ConnectionManager(
      deviceScanner: scanner,
      de1Controller: de1,
      scaleController: primaryController,
      auxiliaryScaleRegistry: AuxiliaryScaleRegistry(),
      settingsController: settings,
      connectTimeout: const Duration(seconds: 5),
    );
    addTearDown(() async {
      await connectionManager.dispose();
      await pluginManager.dispose();
      scanner.dispose();
      discovery.dispose();
      devices.dispose();
      primaryController.dispose();
    });
    await loadSkalePlugin(pluginManager);

    final evidence = BleAdvertisementEvidence(
      name: 'Skale2',
      serviceUuids: ['ff08'],
    );
    final driver = pluginManager.bleService.registry
        .decide(evidence)
        .drivers
        .single;
    final transports = <SkalePluginTransport>[];
    Future<Scale> candidate(String physicalId) async =>
        await pluginManager.bleService.createCandidate(
              driver: driver,
              physicalId: physicalId,
              evidence: evidence,
              admit: () => true,
              createTransport: () {
                final transport = SkalePluginTransport(
                  physicalId,
                  batteryPresent: false,
                );
                transports.add(transport);
                return transport;
              },
            )
            as Scale;

    final primary = await candidate('AA:01');
    final auxiliaryOne = await candidate('AA:02');
    final auxiliaryTwo = await candidate('AA:03');
    final primarySnapshots = <WeightSnapshot>[];
    final auxiliaryOneSnapshots = <ScaleSnapshot>[];
    final auxiliaryTwoSnapshots = <ScaleSnapshot>[];
    final primarySubscription = primaryController.weightSnapshot.listen(
      primarySnapshots.add,
    );
    addTearDown(primarySubscription.cancel);

    Future<ConnectionResult> connect(
      Scale scale,
      int transportIndex, {
      ScaleConnectionRole role = ScaleConnectionRole.primary,
    }) async {
      final connecting = connectionManager.connectScale(scale, role: role);
      final transport = await _transportAt(transports, transportIndex);
      await transport.finalEnable.future.timeout(
        const Duration(seconds: 5),
        onTimeout: () => throw StateError(
          'Skale transport $transportIndex did not reach final enable',
        ),
      );
      transport.emitWeight(skaleFourBytePacket(1));
      return connecting;
    }

    expect((await connect(primary, 0)).success, isTrue);
    expect(
      (await connect(
        auxiliaryOne,
        1,
        role: ScaleConnectionRole.auxiliary,
      )).success,
      isTrue,
    );
    expect(
      (await connect(
        auxiliaryTwo,
        2,
        role: ScaleConnectionRole.auxiliary,
      )).success,
      isTrue,
    );

    final auxiliaryOneConnection = connectionManager.auxiliaryScaleRegistry
        .connectionFor(auxiliaryOne.deviceId)!;
    final auxiliaryTwoConnection = connectionManager.auxiliaryScaleRegistry
        .connectionFor(auxiliaryTwo.deviceId)!;
    final auxiliaryOneSubscription = auxiliaryOneConnection.snapshots.listen(
      auxiliaryOneSnapshots.add,
    );
    final auxiliaryTwoSubscription = auxiliaryTwoConnection.snapshots.listen(
      auxiliaryTwoSnapshots.add,
    );
    addTearDown(auxiliaryOneSubscription.cancel);
    addTearDown(auxiliaryTwoSubscription.cancel);

    final primaryTransport = transports[0];
    final auxiliaryOneTransport = transports[1];
    final auxiliaryTwoTransport = transports[2];
    primaryTransport.emitWeight(skaleFourBytePacket(12));
    auxiliaryOneTransport.emitWeight(skaleFourBytePacket(34));
    auxiliaryTwoTransport.emitWeight(skaleFourBytePacket(56));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(primarySnapshots.last.weight, closeTo(12, 0.001));
    expect(auxiliaryOneSnapshots.last.weight, closeTo(34, 0.001));
    expect(auxiliaryTwoSnapshots.last.weight, closeTo(56, 0.001));
    expect(pluginManager.bleService.registry.activeBindingCount, 3);

    final preferredScaleId = settings.preferredScaleId;
    final primaryWrites = primaryTransport.writes.length;
    final auxiliaryOneWrites = auxiliaryOneTransport.writes.length;
    final auxiliaryTwoWrites = auxiliaryTwoTransport.writes.length;
    await primaryController.tare();
    await auxiliaryOneConnection.scale.tare();
    await auxiliaryTwoConnection.scale.tare();
    expect(primaryTransport.writes.length, primaryWrites + 1);
    expect(auxiliaryOneTransport.writes.length, auxiliaryOneWrites + 1);
    expect(auxiliaryTwoTransport.writes.length, auxiliaryTwoWrites + 1);
    expect(settings.preferredScaleId, preferredScaleId);

    expect(
      (await connectionManager.auxiliaryScaleRegistry.disconnect(
        auxiliaryOne.deviceId,
      )).success,
      isTrue,
    );
    auxiliaryTwoTransport.emitWeight(skaleFourBytePacket(78));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(auxiliaryTwoSnapshots.last.weight, closeTo(78, 0.001));

    final reconnect = connect(
      auxiliaryOne,
      3,
      role: ScaleConnectionRole.auxiliary,
    );
    expect((await reconnect).success, isTrue);
    final reconnectedTransport = transports[3];
    final reconnectedSnapshots = <ScaleSnapshot>[];
    final reconnectedSubscription = connectionManager.auxiliaryScaleRegistry
        .connectionFor(auxiliaryOne.deviceId)!
        .snapshots
        .listen(reconnectedSnapshots.add);
    addTearDown(reconnectedSubscription.cancel);
    reconnectedTransport.emitWeight(skaleFourBytePacket(90));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(
      connectionManager.auxiliaryScaleRegistry.connectionFor(
        auxiliaryOne.deviceId,
      ),
      isNotNull,
    );
    expect(reconnectedSnapshots.last.weight, closeTo(90, 0.001));
    expect(auxiliaryTwoSnapshots.last.weight, closeTo(78, 0.001));
  });
}

Future<SkalePluginTransport> _transportAt(
  List<SkalePluginTransport> transports,
  int index,
) async {
  if (transports.length > index) return transports[index];
  return _waitForTransport(transports, count: index + 1);
}

Future<SkalePluginTransport> _waitForTransport(
  List<SkalePluginTransport> transports, {
  required int count,
}) async {
  for (var attempt = 0; attempt < 100 && transports.length < count; attempt++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(transports.length, greaterThanOrEqualTo(count));
  return transports[count - 1];
}
