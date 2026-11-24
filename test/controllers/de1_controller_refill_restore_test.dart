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
import '../helpers/memory_machine_settings_store.dart';

class _EmptyTransport extends FakeBleTransport {
  @override
  String get id => '';
}

class _SessionTransport extends FakeBleTransport {
  @override
  String get id => 'usb-2e8a-a-unknown-7';
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
}) async {
  final activeTransport = (transport ?? FakeBleTransport())
    ..queueOnConnectResponses(serialN: serialN, calFlowEst: calFlowEst);
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

List<int> _fanRegisterWrites(FakeBleTransport transport) {
  final address = MMRItem.fanThreshold.address;
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

List<int> _refillLevelWrites(FakeBleTransport transport) {
  return transport.writes
      .where((write) => write.characteristicUUID == Endpoint.waterLevels.uuid)
      .map(
        (write) =>
            ByteData.sublistView(write.data).getUint16(2, Endian.big) ~/ 256,
      )
      .toList();
}

void main() {
  test('absent refill level does not write water levels at connect', () async {
    final harness = await _connect();
    addTearDown(harness.controller.dispose);

    expect(_refillLevelWrites(harness.transport), isEmpty);
  });

  test('saved refill level is rewritten at connect', () async {
    final settings = MemoryMachineSettingsStore();
    await settings.update('serial:12345', refillLevel: 12);
    final harness = await _connect(settings: settings);
    addTearDown(harness.controller.dispose);

    expect(_refillLevelWrites(harness.transport), [12]);
  });

  test(
    'unknown machine identity preserves calibration without a write',
    () async {
      final harness = await _connect(serialN: 777, calFlowEst: 1700);
      addTearDown(harness.controller.dispose);

      expect(_flowRegisterWrites(harness.transport), isEmpty);
      expect(harness.controller.connectedDe1OrNull?.cachedFlowEstimation, 1.7);
    },
  );

  test('missing serial and transport identity preserve calibration without a write', () async {
    final settings = MemoryMachineSettingsStore();
    await settings.update('serial:12345', flowCalibration: 1.25);
    await settings.update('', flowCalibration: 1.5);
    expect(await settings.read(''), isNull);
    final harness = await _connect(
      settings: settings,
      transport: _EmptyTransport(),
      serialN: 0,
      calFlowEst: 1700,
    );
    addTearDown(harness.controller.dispose);

    expect(_flowRegisterWrites(harness.transport), isEmpty);
    expect(harness.controller.connectedDe1OrNull?.cachedFlowEstimation, 1.7);
  });

  for (final serial in [0, 12345]) {
    test(
      'session USB identity uses only verified MMR serial $serial for settings',
      () async {
        final settings = MemoryMachineSettingsStore();
        await settings.update(
          'device:usb-2e8a-a-unknown-7',
          flowCalibration: 1.5,
        );
        await settings.update(
          'serial:12345',
          fanThreshold: 42,
          flowCalibration: 1.25,
        );
        final harness = await _connect(
          settings: settings,
          transport: _SessionTransport(),
          serialN: serial,
        );
        addTearDown(harness.controller.dispose);
        expect(settings.reads, isNot(contains('device:usb-2e8a-a-unknown-7')));
        expect(_flowRegisterWrites(harness.transport), isEmpty);
        // 50 (not 55) is the MMR-clamped fan default: an unknown identity has
        // no saved fan, and the write proves the defaults branch still ran.
        expect(
          _fanRegisterWrites(harness.transport),
          serial == 0 ? [50] : [42],
        );
      },
    );
  }

  test('absent calibration override does not write flow at connect', () async {
    final harness = await _connect();
    addTearDown(harness.controller.dispose);

    expect(_flowRegisterWrites(harness.transport), isEmpty);
  });

  for (final (raw, expected) in [(800, 0.8), (1250, 1.25), (1000, 1.0)]) {
    test(
      'first connection reports machine multiplier $expected without a write',
      () async {
        final harness = await _connect(calFlowEst: raw);
        addTearDown(harness.controller.dispose);

        expect(
          harness.controller.connectedDe1OrNull?.cachedFlowEstimation,
          closeTo(expected, 1e-9),
        );
        expect(_flowRegisterWrites(harness.transport), isEmpty);
      },
    );
  }

  for (final legacy in [1.0, 1.5]) {
    test(
      'legacy stored multiplier $legacy is never replayed over machine 0.8',
      () async {
        final settings = MemoryMachineSettingsStore();
        await settings.update(
          'serial:12345',
          fanThreshold: 42,
          flowCalibration: legacy,
        );
        final harness = await _connect(settings: settings, calFlowEst: 800);
        addTearDown(harness.controller.dispose);

        expect(_flowRegisterWrites(harness.transport), isEmpty);
        expect(
          harness.controller.connectedDe1OrNull?.cachedFlowEstimation,
          closeTo(0.8, 1e-9),
        );
        expect(_fanRegisterWrites(harness.transport), [42]);
      },
    );
  }

  test(
    'two machines report their own multiplier and replay no legacy override',
    () async {
      final settings = MemoryMachineSettingsStore();
      await settings.update('serial:12345', flowCalibration: 1.25);
      await settings.update('serial:54321', flowCalibration: 1.5);
      final firstA = await _connect(
        settings: settings,
        serialN: 12345,
        calFlowEst: 800,
      );
      final secondA = await _connect(
        settings: settings,
        serialN: 54321,
        calFlowEst: 1250,
      );
      final firstB = await _connect(
        settings: settings,
        serialN: 12345,
        calFlowEst: 1000,
      );
      addTearDown(firstA.controller.dispose);
      addTearDown(secondA.controller.dispose);
      addTearDown(firstB.controller.dispose);

      expect(_flowRegisterWrites(firstA.transport), isEmpty);
      expect(_flowRegisterWrites(secondA.transport), isEmpty);
      expect(_flowRegisterWrites(firstB.transport), isEmpty);
      expect(
        firstA.controller.connectedDe1OrNull?.cachedFlowEstimation,
        closeTo(0.8, 1e-9),
      );
      expect(
        secondA.controller.connectedDe1OrNull?.cachedFlowEstimation,
        closeTo(1.25, 1e-9),
      );
      expect(
        firstB.controller.connectedDe1OrNull?.cachedFlowEstimation,
        closeTo(1.0, 1e-9),
      );
    },
  );

  test(
    'legacy raw serial fallback keeps one identity and replays nothing',
    () async {
      final settings = MemoryMachineSettingsStore();
      await settings.update('device:fake-ble', flowCalibration: 1.25);
      final first = await _connect(settings: settings, serialN: 0);
      final second = await _connect(settings: settings, serialN: 999);
      addTearDown(first.controller.dispose);
      addTearDown(second.controller.dispose);

      expect(settings.reads, contains('device:fake-ble'));
      expect(settings.reads, contains('serial:999'));
      expect(_flowRegisterWrites(first.transport), isEmpty);
      expect(_flowRegisterWrites(second.transport), isEmpty);
    },
  );

  test('fresh connect without saved refill writes auto exactly once', () async {
    final harness = await _connect();
    addTearDown(harness.controller.dispose);

    expect(_refillRegisterWrites(harness.transport), [
      De1RefillKitSettings.auto.hex,
    ]);
  });

  test('fan-only saved settings do not add a refill write', () async {
    final settings = MemoryMachineSettingsStore();
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
      final settings = MemoryMachineSettingsStore();
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
