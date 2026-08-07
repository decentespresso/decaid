import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/de1_controller.dart';
import 'package:reaprime/src/controllers/device_controller.dart';
import 'package:reaprime/src/controllers/hot_water_sequencer.dart';
import 'package:reaprime/src/controllers/scale_controller.dart';
import 'package:reaprime/src/home_feature/forms/hot_water_form.dart';
import 'package:reaprime/src/models/device/impl/mock_de1/mock_de1.dart';
import 'package:reaprime/src/models/device/impl/mock_scale/mock_scale.dart';
import 'package:reaprime/src/models/device/machine.dart';
import 'package:reaprime/src/models/device/scan_filter.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/settings/gateway_mode.dart';
import 'package:reaprime/src/settings/settings_controller.dart';

import '../helpers/mock_settings_service.dart';

/// Integration tier: wires the real [De1Controller], [ScaleController],
/// [SettingsController] and [HotWaterSequencer] with the simulated MockDe1 +
/// MockScale — the same objects `main.dart` constructs. MockDe1 has no
/// autonomous hot-water stop, so a `hotWater → idle` transition can only have
/// been driven by the sequencer requesting idle.
class _EmptyDiscovery extends DeviceDiscoveryService {
  @override
  Stream<List<Device>> get devices => const Stream.empty();
  @override
  Future<void> initialize() async {}
  @override
  Future<void> scanForDevices({ScanFilter? filter}) async {}
}

void main() {
  late De1Controller de1Controller;
  late ScaleController scaleController;
  late SettingsController settings;
  late HotWaterSequencer sequencer;

  setUp(() async {
    de1Controller = De1Controller(
      controller: DeviceController([_EmptyDiscovery()]),
    );
    scaleController = ScaleController();
    settings = SettingsController(MockSettingsService());
    await settings.loadSettings();
    sequencer = HotWaterSequencer(
      de1Controller: de1Controller,
      scaleController: scaleController,
      settingsController: settings,
    );
  });

  tearDown(() async {
    await sequencer.dispose();
    scaleController.dispose();
  });

  /// Waits for the machine to reach [state], failing after [within].
  Future<void> waitForState(
    MockDe1 machine,
    MachineState state, {
    Duration within = const Duration(seconds: 12),
  }) async {
    await machine.currentSnapshot
        .firstWhere((s) => s.state.state == state)
        .timeout(within);
  }

  test('tares the scale and stops hot water at the target weight', () async {
    final machine = MockDe1();
    await de1Controller.connectToDe1(machine);
    final scale = MockScale();
    scale.attachMachine(machine);
    await scaleController.connectToScale(scale);

    await de1Controller.updateHotWaterSettings(
      HotWaterFormSettings(
        targetTemperature: 85,
        flow: 2.0,
        volume: 5,
        duration: 30,
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 300));

    await machine.requestState(MachineState.hotWater);
    await waitForState(machine, MachineState.hotWater);
    expect(
      sequencer.isArmed,
      isTrue,
      reason: 'sequencer should arm on hotWater entry',
    );

    // The scale weight ramps past 5 g; the sequencer must request idle.
    await waitForState(machine, MachineState.idle);
    expect(
      sequencer.isArmed,
      isFalse,
      reason: 'sequencer should disarm once hot water ends',
    );

    await machine.disconnect();
  });

  test('does not arm in full gateway mode', () async {
    await settings.updateGatewayMode(GatewayMode.full);
    final machine = MockDe1();
    await de1Controller.connectToDe1(machine);
    final scale = MockScale();
    await scaleController.connectToScale(scale);
    await de1Controller.updateHotWaterSettings(
      HotWaterFormSettings(
        targetTemperature: 85,
        flow: 2.0,
        volume: 5,
        duration: 30,
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 300));

    await machine.requestState(MachineState.hotWater);
    await waitForState(machine, MachineState.hotWater);
    // Give the sequencer a few snapshots' worth of time to (not) arm.
    await Future<void>.delayed(const Duration(seconds: 2));

    expect(sequencer.isArmed, isFalse);
    await machine.disconnect();
  });
}
