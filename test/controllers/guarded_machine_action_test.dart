import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/de1_controller.dart';
import 'package:reaprime/src/controllers/device_controller.dart';
import 'package:reaprime/src/models/device/machine.dart';

import '../helpers/mock_device_discovery_service.dart';
import '../helpers/test_de1.dart';

final class _GhcDe1 extends TestDe1 {
  _GhcDe1({super.deviceId});

  @override
  MachineInfo get machineInfo => MachineInfo(
    version: '1',
    model: '1',
    serialNumber: serialNumber,
    groupHeadControllerPresent: true,
    extra: const {},
  );
}

GuardedMachineAction _action(
  De1Controller controller,
  TestDe1 machine, {
  MachineState targetState = MachineState.espresso,
  MachineState expectedState = MachineState.idle,
  bool requireInactiveGhc = true,
}) => GuardedMachineAction(
  targetState: targetState,
  expectedMachineId: machine.deviceId,
  expectedMachineGeneration: controller.connectionGeneration,
  expectedState: expectedState,
  requireInactiveGhc: requireInactiveGhc,
  sourceScale: const GuardedScaleSource(
    role: 'primary',
    deviceId: 'brew-scale',
    connectionId: 'session-1',
    selectionId: 'selection-1',
  ),
);

void main() {
  late DeviceController devices;
  late De1Controller controller;
  late TestDe1 machine;

  setUp(() async {
    devices = DeviceController([MockDeviceDiscoveryService()]);
    await devices.initialize();
    controller = De1Controller(controller: devices, maxPendingDeviceWrites: 1);
    machine = TestDe1(deviceId: 'machine-1');
    controller.adoptDevice(machine);
    await controller.initSettled.firstWhere((generation) => generation != null);
  });

  tearDown(() => controller.dispose());

  test(
    'guarded start uses the queued path and preserves legacy stop',
    () async {
      final accepted = await controller.requestGuardedMachineState(
        _action(controller, machine),
        sourceStillValid: () => true,
        startStillAllowed: () => true,
      );

      expect(accepted, isTrue);
      expect(machine.requestedStates, [MachineState.espresso]);

      await controller.requestMachineState(MachineState.idle);
      expect(machine.requestedStates, [
        MachineState.espresso,
        MachineState.idle,
      ]);
    },
  );

  test('queued guarded start is rejected after same-id replacement', () async {
    final release = Completer<void>();
    final started = Completer<void>();
    final active = controller.runDeviceWrite((_) async {
      started.complete();
      await release.future;
    });
    await started.future;

    final pending = controller.requestGuardedMachineState(
      _action(controller, machine),
      sourceStillValid: () => true,
      startStillAllowed: () => true,
    );
    final activeError = expectLater(active, throwsA(isA<StateError>()));
    final replacement = TestDe1(deviceId: machine.deviceId);
    controller.adoptDevice(replacement);
    release.complete();

    expect(await pending, isFalse);
    await activeError;
    expect(machine.requestedStates, isEmpty);
    expect(replacement.requestedStates, isEmpty);
    await replacement.dispose();
  });

  test('stale source and invalid state are safely rejected', () async {
    final stale = await controller.requestGuardedMachineState(
      _action(controller, machine),
      sourceStillValid: () => false,
      startStillAllowed: () => true,
    );
    expect(stale, isFalse);
    expect(machine.requestedStates, isEmpty);
  });

  test(
    'typed guarded API rejects invalid direction and GHC combinations',
    () async {
      final wrongStart = await controller.requestGuardedMachineState(
        _action(
          controller,
          machine,
          expectedState: MachineState.espresso,
          requireInactiveGhc: true,
        ),
        sourceStillValid: () => true,
        startStillAllowed: () => true,
      );
      final wrongStop = await controller.requestGuardedMachineState(
        _action(
          controller,
          machine,
          targetState: MachineState.idle,
          expectedState: MachineState.espresso,
          requireInactiveGhc: true,
        ),
        sourceStillValid: () => true,
        startStillAllowed: () => true,
      );
      expect(wrongStart, isFalse);
      expect(wrongStop, isFalse);
      expect(machine.requestedStates, isEmpty);
    },
  );

  test('active GHC blocks starts but never blocks an immediate stop', () async {
    final ghcMachine = _GhcDe1(deviceId: 'ghc-machine');
    controller.adoptDevice(ghcMachine);
    final start = await controller.requestGuardedMachineState(
      _action(controller, ghcMachine),
      sourceStillValid: () => true,
      startStillAllowed: () => true,
    );
    expect(start, isFalse);

    ghcMachine.emitStateAndSubstate(
      MachineState.espresso,
      MachineSubstate.idle,
    );
    final stop = await controller.requestGuardedMachineState(
      _action(
        controller,
        ghcMachine,
        targetState: MachineState.idle,
        expectedState: MachineState.espresso,
        requireInactiveGhc: false,
      ),
      sourceStillValid: () => true,
      startStillAllowed: () => true,
    );
    expect(stop, isTrue);
    expect(ghcMachine.requestedStates, [MachineState.idle]);
    await ghcMachine.dispose();
  });

  test('queued start rechecks its gateway before writing', () async {
    final release = Completer<void>();
    final started = Completer<void>();
    final active = controller.runDeviceWrite((_) async {
      started.complete();
      await release.future;
    });
    await started.future;

    var gatewayAllowsStart = true;
    final pending = controller.requestGuardedMachineState(
      _action(controller, machine),
      sourceStillValid: () => true,
      startStillAllowed: () => gatewayAllowsStart,
    );
    gatewayAllowsStart = false;
    release.complete();

    expect(await pending, isFalse);
    await active;
    expect(machine.requestedStates, isEmpty);
  });

  test(
    'queued guarded start cannot replay after an intervening stop returns idle',
    () async {
      final release = Completer<void>();
      final started = Completer<void>();
      final active = controller.runDeviceWrite((_) async {
        started.complete();
        await release.future;
      });
      await started.future;

      final pending = controller.requestGuardedMachineState(
        _action(controller, machine),
        sourceStillValid: () => true,
        startStillAllowed: () => true,
      );
      await Future<void>.delayed(Duration.zero);

      machine.emitStateAndSubstate(MachineState.espresso, MachineSubstate.idle);
      final stopped = await controller.requestGuardedMachineState(
        _action(
          controller,
          machine,
          targetState: MachineState.idle,
          expectedState: MachineState.espresso,
          requireInactiveGhc: false,
        ),
        sourceStillValid: () => true,
        startStillAllowed: () => true,
      );
      expect(stopped, isTrue);

      machine.emitStateAndSubstate(MachineState.idle, MachineSubstate.idle);
      release.complete();

      expect(await pending, isFalse);
      await active;
      expect(machine.requestedStates, [MachineState.idle]);
    },
  );

  test('legacy idle also cancels a queued guarded start', () async {
    final release = Completer<void>();
    final started = Completer<void>();
    final active = controller.runDeviceWrite((_) async {
      started.complete();
      await release.future;
    });
    await started.future;

    final pending = controller.requestGuardedMachineState(
      _action(controller, machine),
      sourceStillValid: () => true,
      startStillAllowed: () => true,
    );
    await Future<void>.delayed(Duration.zero);

    machine.emitStateAndSubstate(MachineState.espresso, MachineSubstate.idle);
    await controller.requestMachineState(MachineState.idle);
    machine.emitStateAndSubstate(MachineState.idle, MachineSubstate.idle);
    release.complete();

    expect(await pending, isFalse);
    await active;
    expect(machine.requestedStates, [MachineState.idle]);
  });
}
