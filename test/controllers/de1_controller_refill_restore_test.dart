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
    double? flowCalibration,
  }) async {
    final current = _settings[identity];
    _settings[identity] = MachineSettings(
      fanThreshold: fanThreshold ?? current?.fanThreshold,
      refillKitSetting: refillKitSetting ?? current?.refillKitSetting,
      flowCalibration: flowCalibration ?? current?.flowCalibration,
    );
  }

  @override
  Future<void> clear(String identity) async => _settings.remove(identity);

  @override
  Future<void> clearExceptFlowCalibration(String identity) async {
    final current = _settings[identity];
    _settings.remove(identity);
    if (current?.flowCalibration != null) {
      _settings[identity] = MachineSettings(
        flowCalibration: current?.flowCalibration,
      );
    }
  }
}

class _EmptyTransport extends FakeBleTransport {
  @override
  String get id => '';
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
  FakeBleTransport? transport,
  int serialN = 12345,
  int calFlowEst = 1000,
  List<int>? calFlowEstSequence,
}) async {
  final activeTransport = (transport ?? FakeBleTransport())
    ..queueOnConnectResponses(serialN: serialN, calFlowEst: calFlowEst);
  if (calFlowEstSequence != null) {
    activeTransport.queueMmrResponseIntSequence(
      MMRItem.calFlowEst,
      calFlowEstSequence,
    );
  }
  activeTransport
    ..queueRead(
      Endpoint.stateInfo.uuid,
      Uint8List.fromList([2, ...List.filled(19, 0)]),
    )
    ..queueRead(Endpoint.shotSettings.uuid, Uint8List.fromList(_shotSettings));
  final de1 = UnifiedDe1(transport: activeTransport);
  final devices = DeviceController(const <DeviceDiscoveryService>[]);
  await devices.initialize();
  final controller = De1Controller(
    controller: devices,
    machineSettings: settings,
  );
  await controller.connectToDe1(de1);
  await controller.initSettled.firstWhere((generation) => generation != null);
  return (controller: controller, transport: activeTransport);
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

List<int> _flowRegisterWrites(FakeBleTransport transport) {
  final address = MMRItem.calFlowEst.address;
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
  test(
    'unknown machine identity preserves calibration without a write',
    () async {
      final harness = await _connect(serialN: 777, calFlowEst: 1700);
      addTearDown(harness.controller.dispose);

      expect(_flowRegisterWrites(harness.transport), isEmpty);
      expect(harness.controller.connectedDe1OrNull?.cachedFlowEstimation, 1.7);
    },
  );

  test(
    'missing serial and transport identity preserve calibration without a write',
    () async {
      final settings = _MemoryMachineSettingsStore();
      await settings.update('serial:12345', flowCalibration: 1.25);
      final harness = await _connect(
        settings: settings,
        transport: _EmptyTransport(),
        serialN: 0,
        calFlowEst: 1700,
      );
      addTearDown(harness.controller.dispose);

      expect(_flowRegisterWrites(harness.transport), isEmpty);
      expect(harness.controller.connectedDe1OrNull?.cachedFlowEstimation, 1.7);
    },
  );

  test('absent calibration override does not write flow at connect', () async {
    final harness = await _connect();
    addTearDown(harness.controller.dispose);

    expect(_flowRegisterWrites(harness.transport), isEmpty);
  });

  test('saved calibration override writes explicit 1.0 at connect', () async {
    final settings = _MemoryMachineSettingsStore();
    await settings.update('serial:12345', flowCalibration: 1.0);
    final harness = await _connect(
      settings: settings,
      calFlowEstSequence: [1000, 1000],
    );
    addTearDown(harness.controller.dispose);

    expect(_flowRegisterWrites(harness.transport), [1000]);
  });

  test(
    'two machine identities restore independent calibration overrides',
    () async {
      final settings = _MemoryMachineSettingsStore();
      await settings.update('serial:12345', flowCalibration: 1.25);
      await settings.update('serial:54321', flowCalibration: 1.5);
      final firstA = await _connect(
        settings: settings,
        serialN: 12345,
        calFlowEstSequence: [1000, 1250],
      );
      final secondA = await _connect(
        settings: settings,
        serialN: 54321,
        calFlowEstSequence: [1000, 1500],
      );
      final firstB = await _connect(
        settings: settings,
        serialN: 12345,
        calFlowEstSequence: [1000, 1250],
      );
      final secondB = await _connect(
        settings: settings,
        serialN: 54321,
        calFlowEstSequence: [1000, 1500],
      );
      addTearDown(firstA.controller.dispose);
      addTearDown(secondA.controller.dispose);
      addTearDown(firstB.controller.dispose);
      addTearDown(secondB.controller.dispose);

      expect(_flowRegisterWrites(firstA.transport), [1250]);
      expect(_flowRegisterWrites(secondA.transport), [1500]);
      expect(_flowRegisterWrites(firstB.transport), [1250]);
      expect(_flowRegisterWrites(secondB.transport), [1500]);
      expect(firstA.controller.connectedDe1OrNull?.cachedFlowEstimation, 1.25);
      expect(secondA.controller.connectedDe1OrNull?.cachedFlowEstimation, 1.5);
      expect(firstB.controller.connectedDe1OrNull?.cachedFlowEstimation, 1.25);
      expect(secondB.controller.connectedDe1OrNull?.cachedFlowEstimation, 1.5);
    },
  );

  test('legacy raw serial fallback keeps one calibration identity', () async {
    final settings = _MemoryMachineSettingsStore();
    await settings.update('device:fake-ble', flowCalibration: 1.25);
    final first = await _connect(
      settings: settings,
      serialN: 0,
      calFlowEstSequence: [1000, 1250],
    );
    final second = await _connect(settings: settings, serialN: 999);
    addTearDown(first.controller.dispose);
    addTearDown(second.controller.dispose);

    expect(_flowRegisterWrites(first.transport), [1250]);
    expect(_flowRegisterWrites(second.transport), isEmpty);
  });

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
