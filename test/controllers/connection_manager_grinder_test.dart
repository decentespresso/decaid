import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/connection_manager.dart';
import 'package:reaprime/src/controllers/device_controller.dart';
import 'package:reaprime/src/models/device/de1_interface.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/scale.dart';
import 'package:reaprime/src/settings/settings_controller.dart';

import '../helpers/mock_de1_controller.dart';
import '../helpers/mock_device_discovery_service.dart';
import '../helpers/mock_device_scanner.dart';
import '../helpers/mock_scale_controller.dart';
import '../helpers/mock_settings_service.dart';
import '../helpers/test_de1.dart';
import '../helpers/test_grinder.dart';
import '../helpers/test_scale.dart';

void main() {
  late MockDeviceScanner scanner;
  late MockDeviceDiscoveryService discovery;
  late DeviceController devices;
  late _GatedMachineController machineController;
  late _GatedScaleController scaleController;
  late SettingsController settings;
  late ConnectionManager manager;
  late TestDe1 machine;
  late TestScale scale;
  late TestGrinder grinder;
  late Completer<void> grinderGate;

  setUp(() async {
    scanner = MockDeviceScanner()..supportsWatch = true;
    discovery = MockDeviceDiscoveryService();
    devices = DeviceController([discovery]);
    machineController = _GatedMachineController(controller: devices);
    scaleController = _GatedScaleController();
    settings = SettingsController(MockSettingsService());
    await settings.loadSettings();
    manager = ConnectionManager(
      deviceScanner: scanner,
      de1Controller: machineController,
      scaleController: scaleController,
      settingsController: settings,
      connectTimeout: const Duration(seconds: 1),
    );
    machine = TestDe1(deviceId: 'machine');
    scale = TestScale(deviceId: 'scale');
    grinderGate = Completer<void>();
    grinder = TestGrinder(deviceId: 'grinder', connectGate: grinderGate);
    await settings.setPreferredGrinderDeviceId(grinder.deviceId);
  });

  tearDown(() async {
    if (!machineController.proceed.isCompleted) {
      machineController.proceed.complete();
    }
    if (!scaleController.proceed.isCompleted) {
      scaleController.proceed.complete();
    }
    if (!grinderGate.isCompleted) grinderGate.complete();
    await manager.dispose();
    await machineController.de1Subject.close();
    await scaleController.connectionStateSubject.close();
    scanner.dispose();
    devices.dispose();
    discovery.dispose();
    settings.dispose();
    await machine.dispose();
    await grinder.dispose();
  });

  for (final explicit in [false, true]) {
    test(
      '${explicit ? 'explicit' : 'automatic'} scan settles machine and scale before grinder',
      () async {
        scanner.addDevice(machine);
        scanner.addDevice(scale);
        scanner.addDevice(grinder);

        final scan = explicit ? manager.scanAndConnect() : manager.connect();
        await machineController.started.future.timeout(
          const Duration(seconds: 2),
        );
        expect(grinder.onConnectCalls, 0);
        expect(scaleController.connectCalls, isEmpty);
        machineController.proceed.complete();
        await scaleController.started.future.timeout(
          const Duration(seconds: 2),
        );
        expect(grinder.onConnectCalls, 0);
        scaleController.proceed.complete();
        await scan.timeout(const Duration(milliseconds: 500));
        await Future<void>.delayed(Duration.zero);

        expect(grinder.onConnectCalls, 1);
        expect(grinderGate.isCompleted, isFalse);
        expect(manager.currentStatus.phase, ConnectionPhase.ready);
        expect(manager.currentStatus.error, isNull);
        expect(manager.currentStatus.pendingAmbiguity, isNull);
        expect(manager.lastScanReport, isNotNull);
      },
    );
  }

  for (final timeout in [false, true]) {
    test(
      'grinder ${timeout ? 'timeout' : 'failure'} leaves primary status unchanged',
      () async {
        grinder = TestGrinder(
          deviceId: 'grinder',
          connectGate: grinderGate,
          connectError: timeout
              ? null
              : StateError('grinder initialization failed'),
        );
        scanner.addDevice(machine);
        scanner.addDevice(scale);
        scanner.addDevice(grinder);
        machineController.proceed.complete();
        scaleController.proceed.complete();

        await manager.scanAndConnect().timeout(
          const Duration(milliseconds: 500),
        );
        final status = manager.currentStatus;
        final report = manager.lastScanReport;
        final disconnected = manager.grinderController.connectionState
            .firstWhere((state) => state == ConnectionState.disconnected);
        if (!timeout) grinderGate.complete();
        await disconnected.timeout(const Duration(seconds: 2));
        if (timeout) grinderGate.complete();
        await Future<void>.delayed(Duration.zero);

        expect(status.phase, ConnectionPhase.ready);
        expect(manager.currentStatus, same(status));
        expect(manager.currentStatus.error, isNull);
        expect(manager.lastScanReport, same(report));
        expect(manager.currentStatus.pendingAmbiguity, isNull);
        expect(settings.preferredMachineId, machine.deviceId);
        expect(settings.preferredScaleId, scale.deviceId);
        expect(manager.grinderController.isOccupied, isFalse);
      },
    );
  }

  test('scale-only recovery never attempts the preferred grinder', () async {
    scanner.addDevice(scale);
    scanner.addDevice(grinder);
    scaleController.proceed.complete();

    await manager.connect(scaleOnly: true);

    expect(scaleController.connectCalls, [same(scale)]);
    expect(grinder.onConnectCalls, 0);
    expect(machineController.connectCalls, isEmpty);
  });

  test(
    'occupied machine settles before grinder and scale recovery stays independent',
    () async {
      machineController.proceed.complete();
      expect((await manager.connectMachine(machine)).success, isTrue);
      scanner.addDevice(machine);
      scanner.addDevice(grinder);

      await manager.scanAndConnect().timeout(const Duration(milliseconds: 500));
      await Future<void>.delayed(Duration.zero);
      expect(manager.currentStatus.phase, ConnectionPhase.ready);
      expect(grinder.onConnectCalls, 1);
      expect(grinderGate.isCompleted, isFalse);

      scanner.addDevice(scale);
      scaleController.proceed.complete();
      await manager
          .connect(scaleOnly: true)
          .timeout(const Duration(milliseconds: 500));

      expect(scaleController.connectCalls, [same(scale)]);
      expect(machineController.connectCalls, [same(machine)]);
      expect(grinder.onConnectCalls, 1);
      expect(manager.currentStatus.phase, ConnectionPhase.ready);
    },
  );

  test(
    'machine picker defers grinder until machine and scale settle',
    () async {
      final alternative = TestDe1(deviceId: 'alternative');
      addTearDown(alternative.dispose);
      scanner.addDevice(machine);
      scanner.addDevice(alternative);
      scanner.addDevice(scale);
      scanner.addDevice(grinder);

      await manager.scanAndConnect().timeout(const Duration(milliseconds: 500));
      await Future<void>.delayed(Duration.zero);
      expect(
        manager.currentStatus.pendingAmbiguity,
        AmbiguityReason.machinePicker,
      );
      expect(manager.currentStatus.foundMachines, [machine, alternative]);
      expect(manager.currentStatus.foundScales, [scale]);
      expect(manager.lastScanReport, isNull);
      expect(grinder.onConnectCalls, 0);

      final selection = manager.selectMachine(machine);
      await machineController.started.future.timeout(
        const Duration(seconds: 2),
      );
      expect(grinder.onConnectCalls, 0);
      machineController.proceed.complete();
      await scaleController.started.future.timeout(const Duration(seconds: 2));
      expect(grinder.onConnectCalls, 0);
      scaleController.proceed.complete();
      expect(
        (await selection.timeout(const Duration(milliseconds: 500))).success,
        isTrue,
      );
      await Future<void>.delayed(Duration.zero);

      expect(grinder.onConnectCalls, 1);
      expect(manager.currentStatus.phase, ConnectionPhase.ready);
      expect(manager.currentStatus.pendingAmbiguity, isNull);
      expect(manager.lastScanReport, isNotNull);
      expect(grinderGate.isCompleted, isFalse);
      expect(scanner.scanCallCount, 1);
    },
  );

  for (final occupiedMachine in [false, true]) {
    test(
      'scale picker defers grinder with ${occupiedMachine ? 'occupied' : 'new'} machine',
      () async {
        final alternative = TestScale(deviceId: 'alternative-scale');
        machineController.proceed.complete();
        if (occupiedMachine) {
          expect((await manager.connectMachine(machine)).success, isTrue);
        }
        scanner.addDevice(machine);
        scanner.addDevice(scale);
        scanner.addDevice(alternative);
        scanner.addDevice(grinder);

        await manager.scanAndConnect().timeout(
          const Duration(milliseconds: 500),
        );
        await Future<void>.delayed(Duration.zero);
        expect(
          manager.currentStatus.pendingAmbiguity,
          AmbiguityReason.scalePicker,
        );
        expect(manager.lastScanReport, isNull);
        expect(grinder.onConnectCalls, 0);

        final selection = manager.selectScale(scale);
        await scaleController.started.future.timeout(
          const Duration(seconds: 2),
        );
        expect(grinder.onConnectCalls, 0);
        scaleController.proceed.complete();
        expect(
          (await selection.timeout(const Duration(milliseconds: 500))).success,
          isTrue,
        );
        await Future<void>.delayed(Duration.zero);

        expect(grinder.onConnectCalls, 1);
        expect(grinderGate.isCompleted, isFalse);
        expect(manager.currentStatus.phase, ConnectionPhase.ready);
        expect(manager.currentStatus.pendingAmbiguity, isNull);
        expect(manager.currentStatus.error, isNull);
        expect(manager.lastScanReport, isNotNull);
        expect(scanner.scanCallCount, 1);
      },
    );
  }

  test(
    'machine picker followed by scale picker defers grinder through both',
    () async {
      final alternativeMachine = TestDe1(deviceId: 'alternative-machine');
      addTearDown(alternativeMachine.dispose);
      final alternativeScale = TestScale(deviceId: 'alternative-scale');
      scanner.addDevice(machine);
      scanner.addDevice(alternativeMachine);
      scanner.addDevice(scale);
      scanner.addDevice(alternativeScale);
      scanner.addDevice(grinder);
      machineController.proceed.complete();

      await manager.scanAndConnect().timeout(const Duration(milliseconds: 500));
      await Future<void>.delayed(Duration.zero);
      expect(
        manager.currentStatus.pendingAmbiguity,
        AmbiguityReason.machinePicker,
      );
      expect(grinder.onConnectCalls, 0);

      expect((await manager.selectMachine(machine)).success, isTrue);
      await Future<void>.delayed(Duration.zero);
      expect(
        manager.currentStatus.pendingAmbiguity,
        AmbiguityReason.scalePicker,
      );
      expect(manager.lastScanReport, isNull);
      expect(grinder.onConnectCalls, 0);

      scaleController.proceed.complete();
      expect((await manager.selectScale(scale)).success, isTrue);
      await Future<void>.delayed(Duration.zero);
      expect(grinder.onConnectCalls, 1);
      expect(grinderGate.isCompleted, isFalse);
      expect(manager.currentStatus.phase, ConnectionPhase.ready);
      expect(manager.currentStatus.pendingAmbiguity, isNull);
      expect(manager.lastScanReport, isNotNull);
    },
  );

  test(
    'cancelled selection does not retain a preferred grinder attempt',
    () async {
      final alternative = TestDe1(deviceId: 'alternative');
      addTearDown(alternative.dispose);
      scanner.addDevice(machine);
      scanner.addDevice(alternative);
      scanner.addDevice(scale);
      scanner.addDevice(grinder);

      await manager.scanAndConnect().timeout(const Duration(milliseconds: 500));
      await Future<void>.delayed(Duration.zero);
      expect(
        manager.currentStatus.pendingAmbiguity,
        AmbiguityReason.machinePicker,
      );
      expect(grinder.onConnectCalls, 0);
      manager.cancelSelectionSession();
      await Future<void>.delayed(Duration.zero);
      expect(grinder.onConnectCalls, 0);

      scanner.removeDevice(alternative.deviceId);
      scanner.removeDevice(grinder.deviceId);
      machineController.proceed.complete();
      scaleController.proceed.complete();
      await manager.scanAndConnect().timeout(const Duration(milliseconds: 500));
      await Future<void>.delayed(Duration.zero);
      expect(manager.currentStatus.phase, ConnectionPhase.ready);
      expect(manager.currentStatus.pendingAmbiguity, isNull);
      expect(grinder.onConnectCalls, 0);
    },
  );
}

class _GatedMachineController extends MockDe1Controller {
  _GatedMachineController({required super.controller});

  final started = Completer<void>();
  final proceed = Completer<void>();

  @override
  Future<void> connectToDe1(De1Interface machine) async {
    if (!started.isCompleted) started.complete();
    await proceed.future;
    await super.connectToDe1(machine);
  }
}

class _GatedScaleController extends MockScaleController {
  final started = Completer<void>();
  final proceed = Completer<void>();

  @override
  Future<void> connectToScale(Scale scale) async {
    if (!started.isCompleted) started.complete();
    await proceed.future;
    await super.connectToScale(scale);
  }
}
