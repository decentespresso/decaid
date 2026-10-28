import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/de1_controller.dart';
import 'package:reaprime/src/controllers/device_controller.dart';
import 'package:reaprime/src/models/device/de1_interface.dart';
import 'package:reaprime/src/models/device/impl/de1/de1.models.dart';
import 'package:reaprime/src/models/device/impl/de1/unified_de1/unified_de1.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/settings/machine_settings_store.dart';

import '../helpers/fake_ble_transport.dart';

class _MemoryMachineSettingsStore implements MachineSettingsStore {
  final Map<String, MachineSettings> _settings = {};

  @override
  Future<MachineSettings?> read(String identity) async => _settings[identity];

  @override
  Future<void> update(
    String identity, {
    int? fanThreshold,
    De1RefillKitSettings? refillKitSetting,
  }) async {
    final current = _settings[identity];
    _settings[identity] = MachineSettings(
      fanThreshold: fanThreshold ?? current?.fanThreshold,
      refillKitSetting: refillKitSetting ?? current?.refillKitSetting,
    );
  }

  @override
  Future<void> clear(String identity) async => _settings.remove(identity);
}

const _shotSettings = <int>[
  0,
  150,
  30,
  75,
  50,
  30,
  36,
  94,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
];

Future<({De1Controller controller, FakeBleTransport transport})> _connect({
  MachineSettingsStore? settings,
}) async {
  final transport = FakeBleTransport()
    ..queueOnConnectResponses()
    ..queueRead(
      Endpoint.stateInfo.uuid,
      Uint8List.fromList([2, ...List.filled(19, 0)]),
    )
    ..queueRead(Endpoint.shotSettings.uuid, Uint8List.fromList(_shotSettings));
  final de1 = UnifiedDe1(transport: transport);
  final devices = DeviceController(const <DeviceDiscoveryService>[]);
  await devices.initialize();
  final controller = De1Controller(
    controller: devices,
    machineSettings: settings,
  );
  await controller.connectToDe1(de1);
  await controller.initSettled.firstWhere((generation) => generation != null);
  return (controller: controller, transport: transport);
}

List<int> _refillRegisterWrites(FakeBleTransport transport) {
  final address = MMRItem.refillKitPresent.address;
  return transport.writes
      .where(
        (write) =>
            write.characteristicUUID == Endpoint.writeToMMR.uuid &&
            write.data.length >= 8 &&
            write.data[1] == ((address >> 16) & 0xff) &&
            write.data[2] == ((address >> 8) & 0xff) &&
            write.data[3] == (address & 0xff),
      )
      .map(
        (write) => ByteData.sublistView(write.data).getUint32(4, Endian.little),
      )
      .toList();
}

void main() {
  test('fresh connect without saved refill writes auto exactly once', () async {
    final harness = await _connect();
    addTearDown(harness.controller.dispose);

    expect(_refillRegisterWrites(harness.transport), [
      De1RefillKitSettings.auto.hex,
    ]);
  });

  test('fan-only saved settings do not add a refill write', () async {
    final settings = _MemoryMachineSettingsStore();
    await settings.update('serial:12345', fanThreshold: 42);
    final harness = await _connect(settings: settings);
    addTearDown(harness.controller.dispose);

    expect(_refillRegisterWrites(harness.transport), [
      De1RefillKitSettings.auto.hex,
    ]);
  });

  for (final setting in [
    De1RefillKitSettings.forceOn,
    De1RefillKitSettings.forceOff,
  ]) {
    test('saved ${setting.name} follows auto on the wire', () async {
      final settings = _MemoryMachineSettingsStore();
      await settings.update('serial:12345', refillKitSetting: setting);
      final harness = await _connect(settings: settings);
      addTearDown(harness.controller.dispose);

      expect(_refillRegisterWrites(harness.transport), [
        De1RefillKitSettings.auto.hex,
        setting.hex,
      ]);
    });
  }
}
