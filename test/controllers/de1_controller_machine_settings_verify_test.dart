import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/de1_controller.dart';
import 'package:reaprime/src/controllers/device_controller.dart';
import 'package:reaprime/src/controllers/machine_settings_write_report.dart';
import 'package:reaprime/src/models/device/impl/mock_de1/mock_de1.dart';
import 'package:reaprime/src/models/errors.dart';

import '../helpers/mock_device_discovery_service.dart';

class _SettingsDe1 extends MockDe1 {
  bool ignoreFanWrite = false;
  bool ignoreScaledWrites = false;
  bool failFanReadBack = false;
  bool failFlushFlowReadBack = false;
  double? hotWaterFlowCeiling;

  @override
  Future<void> setFanThreshhold(int temp) async {
    if (ignoreFanWrite) return;
    await super.setFanThreshhold(temp);
  }

  @override
  Future<int> getFanThreshhold() async {
    if (failFanReadBack) {
      throw const MmrTimeoutException('fanThreshold', Duration(seconds: 4));
    }
    return super.getFanThreshhold();
  }

  @override
  Future<void> setSteamFlow(double newFlow) async {
    if (ignoreScaledWrites) return;
    await super.setSteamFlow(newFlow);
  }

  @override
  Future<void> setHotWaterFlow(double newFlow) async {
    if (ignoreScaledWrites) return;
    final ceiling = hotWaterFlowCeiling;
    await super.setHotWaterFlow(
      ceiling == null ? newFlow : newFlow.clamp(0.0, ceiling),
    );
  }

  @override
  Future<void> setFlushFlow(double newFlow) async {
    if (ignoreScaledWrites) return;
    await super.setFlushFlow(newFlow);
  }

  @override
  Future<double> getFlushFlow() async {
    if (failFlushFlowReadBack) {
      throw const MmrTimeoutException('flushFlowRate', Duration(seconds: 4));
    }
    return super.getFlushFlow();
  }

  Future<void> presetSteamFlow(double value) => super.setSteamFlow(value);

  Future<void> presetFlushFlow(double value) => super.setFlushFlow(value);
}

void main() {
  late De1Controller controller;
  late _SettingsDe1 de1;

  setUp(() async {
    final deviceController = DeviceController([MockDeviceDiscoveryService()]);
    await deviceController.initialize();
    controller = De1Controller(controller: deviceController);
    de1 = _SettingsDe1();
    await controller.connectToDe1(de1);
  });

  tearDown(() async {
    await controller.dispose();
  });

  MachineSettingWriteResult resultFor(
    MachineSettingsWriteReport report,
    String field,
  ) {
    final result = report.results[field];
    expect(result, isNotNull, reason: 'expected a report entry for $field');
    return result!;
  }

  test('an unbounded field the device stores reports applied', () async {
    final report = await controller.updateMachineSettings(steamPurgeMode: 1);

    final result = resultFor(report, 'steamPurgeMode');
    expect(result.status, MachineSettingWriteStatus.applied);
    expect(result.requested, 1);
    expect(result.actual, 1);
  });

  test('a device-side clamp reports adjusted with the stored value', () async {
    final report = await controller.updateMachineSettings(fan: 51);

    final result = resultFor(report, 'fan');
    expect(result.status, MachineSettingWriteStatus.adjusted);
    expect(result.requested, 51);
    expect(result.actual, 50);
  });

  test('an in-band write reports applied', () async {
    final report = await controller.updateMachineSettings(fan: 45);

    final result = resultFor(report, 'fan');
    expect(result.status, MachineSettingWriteStatus.applied);
    expect(result.actual, 45);
  });

  test('a write the device ignores reports adjusted, not applied', () async {
    de1.ignoreFanWrite = true;
    final before = await de1.getFanThreshhold();

    final report = await controller.updateMachineSettings(fan: 45);

    final result = resultFor(report, 'fan');
    expect(result.status, MachineSettingWriteStatus.adjusted);
    expect(result.actual, before);
  });

  test('a failed read-back reports unverified, not applied', () async {
    de1.failFanReadBack = true;

    final report = await controller.updateMachineSettings(fan: 45);

    final result = resultFor(report, 'fan');
    expect(result.status, MachineSettingWriteStatus.unverified);
    expect(result.requested, 45);
    expect(result.actual, isNull);
  });

  test('a failed read-back on one field leaves the others verified', () async {
    de1.failFanReadBack = true;

    final report = await controller.updateMachineSettings(
      fan: 45,
      steamPurgeMode: 2,
    );

    expect(
      resultFor(report, 'fan').status,
      MachineSettingWriteStatus.unverified,
    );
    expect(
      resultFor(report, 'steamPurgeMode').status,
      MachineSettingWriteStatus.applied,
    );
  });

  test('only requested fields appear in the report', () async {
    final report = await controller.updateMachineSettings(fan: 45);
    expect(report.results.keys, ['fan']);
  });

  test('a request with no fields reports nothing', () async {
    final report = await controller.updateMachineSettings();
    expect(report.results, isEmpty);
  });

  test('usb is reported as booleans on both sides', () async {
    final report = await controller.updateMachineSettings(usb: true);

    final result = resultFor(report, 'usb');
    expect(result.requested, true);
    expect(result.actual, true);
    expect(result.status, MachineSettingWriteStatus.applied);
  });

  group('scaled-field tolerance', () {
    test('a tenth-LSB field tolerates float representation noise', () async {
      await de1.presetFlushFlow(4.1000000000000005);
      de1.ignoreScaledWrites = true;

      final report = await controller.updateMachineSettings(flushFlow: 4.1);

      expect(
        resultFor(report, 'flushFlow').status,
        MachineSettingWriteStatus.applied,
      );
    });

    test('a one-LSB drop on a tenth-LSB field is reported adjusted', () async {
      await de1.presetFlushFlow(3.2);
      de1.ignoreScaledWrites = true;

      final report = await controller.updateMachineSettings(flushFlow: 3.3);

      final result = resultFor(report, 'flushFlow');
      expect(result.status, MachineSettingWriteStatus.adjusted);
      expect(result.actual, 3.2);
    });

    test('a hundredth-LSB field keeps its own tighter tolerance', () async {
      final applied = await controller.updateMachineSettings(steamFlow: 1.23);
      expect(
        resultFor(applied, 'steamFlow').status,
        MachineSettingWriteStatus.applied,
      );

      await de1.presetSteamFlow(1.22);
      de1.ignoreScaledWrites = true;

      final report = await controller.updateMachineSettings(steamFlow: 1.23);
      expect(
        resultFor(report, 'steamFlow').status,
        MachineSettingWriteStatus.adjusted,
      );
    });
  });

  group('publishes', () {
    test('publish the verified actual, not the requested value', () async {
      de1.hotWaterFlowCeiling = 6.0;
      final emitted = <double>[];
      final sub = controller.hotWaterData.listen((d) => emitted.add(d.flow));

      final report = await controller.updateMachineSettings(hotWaterFlow: 9.0);
      await Future<void>.delayed(Duration.zero);

      expect(
        resultFor(report, 'hotWaterFlow').status,
        MachineSettingWriteStatus.adjusted,
      );
      expect(emitted.last, 6.0);
      await sub.cancel();
    });

    test('publish the requested value when the read-back failed', () async {
      de1.failFlushFlowReadBack = true;
      final emitted = <double>[];
      final sub = controller.rinseData.listen((r) => emitted.add(r.flow));

      final report = await controller.updateMachineSettings(flushFlow: 4.0);
      await Future<void>.delayed(Duration.zero);

      expect(
        resultFor(report, 'flushFlow').status,
        MachineSettingWriteStatus.unverified,
      );
      expect(emitted.last, 4.0);
      await sub.cancel();
    });

    test('a verified steam flow publishes the machine value', () async {
      final emitted = <double>[];
      final sub = controller.steamData.listen((s) => emitted.add(s.flow));

      await controller.updateMachineSettings(steamFlow: 1.5);
      await Future<void>.delayed(Duration.zero);

      expect(emitted.last, 1.5);
      await sub.cancel();
    });
  });
}
