import 'dart:async';
import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/connection_error.dart';
import 'package:reaprime/src/controllers/connection_manager.dart';
import 'package:reaprime/src/controllers/remembered_devices_controller.dart';
import 'package:reaprime/src/controllers/scale_controller.dart';
import 'package:reaprime/src/models/device/remembered_device.dart';
import 'package:reaprime/src/models/device/simulated_device.dart';
import 'package:reaprime/src/controllers/device_controller.dart';
import 'package:reaprime/src/models/adapter_state.dart';
import 'package:reaprime/src/models/device/de1_interface.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/machine.dart';
import 'package:reaprime/src/models/device/transport/ble_connect_exception.dart';
import 'package:reaprime/src/models/device/device_implementation.dart';
import 'package:reaprime/src/models/device/transport/data_transport.dart';
import 'package:reaprime/src/models/errors.dart';
import 'package:reaprime/src/models/scan_report.dart';
import 'package:reaprime/src/settings/scale_power_mode.dart';
import 'package:reaprime/src/settings/settings_controller.dart';
import 'package:reaprime/src/settings/settings_service.dart';

import '../helpers/mock_de1_controller.dart';
import '../helpers/mock_device_discovery_service.dart';
import '../helpers/mock_device_scanner.dart';
import '../helpers/mock_scale_controller.dart';
import '../helpers/mock_settings_service.dart';
import '../helpers/test_scale.dart';

class _FakeDe1 implements De1Interface {
  final StreamController<MachineSnapshot> _snapshotController =
      StreamController<MachineSnapshot>.broadcast();

  @override
  final String deviceId;

  @override
  final String name;

  final List<String>? disconnectOrder;
  final Object? disconnectError;
  final Completer<void>? disconnectStarted;
  final Completer<void>? disconnectCompleter;

  @override
  DeviceType get type => DeviceType.machine;

  @override
  DeviceImplementation get implementation => DeviceImplementation.unifiedDe1;

  @override
  TransportType get transportType => TransportType.unknown;

  @override
  Stream<ConnectionState> get connectionState =>
      Stream.value(ConnectionState.connected);

  @override
  Stream<MachineSnapshot> get currentSnapshot => _snapshotController.stream;

  @override
  Stream<bool> get ready => const Stream.empty();

  @override
  Future<void> dispose() async {}

  _FakeDe1({
    this.deviceId = 'fake-de1',
    String? name,
    this.disconnectOrder,
    this.disconnectError,
    this.disconnectStarted,
    this.disconnectCompleter,
  }) : name = name ?? 'DE1-$deviceId';

  void emitState(MachineState state) {
    _snapshotController.add(_machineSnapshot(state));
  }

  @override
  Future<void> disconnect() async {
    disconnectOrder?.add('machine');
    if (disconnectStarted != null && !disconnectStarted!.isCompleted) {
      disconnectStarted!.complete();
    }
    await disconnectCompleter?.future;
    if (disconnectError != null) throw disconnectError!;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _FakeSimulatedDe1 extends _FakeDe1 implements SimulatedDevice {
  _FakeSimulatedDe1({super.deviceId = 'MockDe1'});
}

class _FakeSimulatedScale extends TestScale implements SimulatedDevice {
  _FakeSimulatedScale({super.deviceId = 'MockScale'});
}

class _TrackingScale extends TestScale {
  _TrackingScale(this.disconnectOrder) : super(deviceId: 'tracking-scale');

  final List<String> disconnectOrder;

  @override
  Future<void> disconnect() async => disconnectOrder.add('scale');
}

class _FailingFakeDe1 implements De1Interface {
  @override
  final String deviceId;

  @override
  final String name;

  @override
  DeviceType get type => DeviceType.machine;

  @override
  DeviceImplementation get implementation => DeviceImplementation.unifiedDe1;

  @override
  TransportType get transportType => TransportType.unknown;

  @override
  Stream<ConnectionState> get connectionState =>
      Stream.value(ConnectionState.disconnected);

  @override
  Stream<MachineSnapshot> get currentSnapshot => const Stream.empty();

  _FailingFakeDe1({this.deviceId = 'failing-de1'}) : name = 'DE1-$deviceId';

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

MachineSnapshot _machineSnapshot(MachineState state) {
  return MachineSnapshot(
    timestamp: DateTime.utc(2026),
    state: MachineStateSnapshot(state: state, substate: MachineSubstate.idle),
    flow: 0,
    pressure: 0,
    targetFlow: 0,
    targetPressure: 0,
    mixTemperature: 0,
    groupTemperature: 0,
    targetMixTemperature: 0,
    targetGroupTemperature: 0,
    profileFrame: 0,
    steamTemperature: 0,
  );
}

void main() {
  group('ConnectionStatus', () {
    test('defaults to idle with empty lists', () {
      const status = ConnectionStatus();
      expect(status.phase, ConnectionPhase.idle);
      expect(status.foundMachines, isEmpty);
      expect(status.foundScales, isEmpty);
      expect(status.pendingAmbiguity, isNull);
      expect(status.error, isNull);
      expect(status.intent, ConnectionIntent.automatic);
      expect(status.activeTargetTransport, isNull);
      expect(status.conditions, isEmpty);
    });

    test('copyWith preserves fields not overridden', () {
      const status = ConnectionStatus(phase: ConnectionPhase.scanning);
      final updated = status.copyWith(phase: ConnectionPhase.ready);
      expect(updated.phase, ConnectionPhase.ready);
      expect(updated.foundMachines, isEmpty);
    });

    test('copyWith can null out optional fields', () {
      final status = ConnectionStatus(
        pendingAmbiguity: AmbiguityReason.machinePicker,
        error: ConnectionError(
          kind: ConnectionErrorKind.machineConnectFailed,
          severity: ConnectionErrorSeverity.error,
          timestamp: DateTime.utc(2026),
          message: 'something',
        ),
      );
      final cleared = status.copyWith(
        pendingAmbiguity: () => null,
        error: () => null,
      );
      expect(cleared.pendingAmbiguity, isNull);
      expect(cleared.error, isNull);
    });
  });

  group('ConnectionManager', () {
    late MockDeviceScanner mockScanner;
    late MockDe1Controller mockDe1Controller;
    late MockScaleController mockScaleController;
    late SettingsController settingsController;
    late MockSettingsService mockSettingsService;
    late ConnectionManager connectionManager;

    late MockDeviceDiscoveryService dummyDiscoveryService;

    setUp(() async {
      mockScanner = MockDeviceScanner();
      dummyDiscoveryService = MockDeviceDiscoveryService();
      mockDe1Controller = MockDe1Controller(
        controller: DeviceController([dummyDiscoveryService]),
      );
      mockScaleController = MockScaleController();
      mockSettingsService = MockSettingsService();
      settingsController = SettingsController(mockSettingsService);
      await settingsController.loadSettings();

      connectionManager = ConnectionManager(
        deviceScanner: mockScanner,
        de1Controller: mockDe1Controller,
        scaleController: mockScaleController,
        settingsController: settingsController,
      );
    });

    tearDown(() {
      connectionManager.dispose();
      mockScanner.dispose();
    });

    test('initial status is idle', () {
      expect(connectionManager.currentStatus.phase, ConnectionPhase.idle);
      expect(connectionManager.currentStatus.error, isNull);
    });

    group('shutdown', () {
      test('stops active scan and discards queued and future work', () async {
        final scanCompleter = Completer<void>();
        mockScanner.scanCompleter = scanCompleter;

        final activeScan = connectionManager.connect();
        await Future<void>.delayed(Duration.zero);
        final queuedScaleScan = connectionManager.connect(scaleOnly: true);
        final queuedScan = connectionManager.scanAndConnect();
        await Future<void>.delayed(Duration.zero);
        final stopsBeforeShutdown = mockScanner.stopScanCallCount;
        var shutdownCompleted = false;

        final shutdown = connectionManager.shutdown();
        unawaited(shutdown.then((_) => shutdownCompleted = true));
        await Future<void>.delayed(Duration.zero);

        expect(mockScanner.stopScanCallCount, stopsBeforeShutdown + 1);
        expect(shutdownCompleted, isFalse);

        scanCompleter.complete();
        await Future.wait([activeScan, queuedScaleScan, queuedScan, shutdown]);

        await connectionManager.connect();
        await connectionManager.scanAndConnect();
        await settingsController.setPreferredMachineId('preferred-machine');
        connectionManager.adapterRecoveryDebounce = Duration.zero;
        mockScanner.mockAdapterState(AdapterState.poweredOff);
        mockScanner.mockAdapterState(AdapterState.poweredOn);
        await Future<void>.delayed(Duration.zero);
        expect(mockScanner.scanCallCount, 1);
        expect(mockDe1Controller.connectMachineCallCount, 0);
      });

      test(
        'waits for an in-flight machine connect before disconnecting',
        () async {
          await connectionManager.dispose();
          final connectCompleter = Completer<void>();
          final slowDe1Controller = _SlowMockDe1Controller(
            controller: DeviceController([dummyDiscoveryService]),
          )..connectCompleter = connectCompleter;
          mockScaleController = MockScaleController();
          connectionManager = ConnectionManager(
            deviceScanner: mockScanner,
            de1Controller: slowDe1Controller,
            scaleController: mockScaleController,
            settingsController: settingsController,
          );
          final disconnectOrder = <String>[];
          final machine = _FakeDe1(disconnectOrder: disconnectOrder);

          final connecting = connectionManager.connectMachine(machine);
          await Future<void>.delayed(Duration.zero);
          var shutdownCompleted = false;
          final shutdown = connectionManager.shutdown();
          unawaited(shutdown.then((_) => shutdownCompleted = true));
          await Future<void>.delayed(Duration.zero);

          expect(shutdownCompleted, isFalse);
          expect(disconnectOrder, isEmpty);

          connectCompleter.complete();
          await connecting;
          await shutdown;

          expect(disconnectOrder, ['machine']);
          final blocked = await connectionManager.connectMachine(_FakeDe1());
          expect(blocked.outcome, ConnectionOutcome.conflict);
          expect(slowDe1Controller.connectCalls, [machine]);
        },
      );

      test(
        'waits for a timed-out machine connect to actually finish',
        () async {
          await connectionManager.dispose();
          final connectCompleter = Completer<void>();
          final slowDe1Controller = _SlowMockDe1Controller(
            controller: DeviceController([dummyDiscoveryService]),
          )..connectCompleter = connectCompleter;
          connectionManager = ConnectionManager(
            deviceScanner: mockScanner,
            de1Controller: slowDe1Controller,
            scaleController: mockScaleController,
            settingsController: settingsController,
            connectTimeout: Duration.zero,
          );
          final disconnectOrder = <String>[];
          final machine = _FakeDe1(disconnectOrder: disconnectOrder);

          final result = await connectionManager.connectMachine(machine);
          expect(result.outcome, ConnectionOutcome.timedOut);

          var shutdownCompleted = false;
          final shutdown = connectionManager.shutdown();
          unawaited(shutdown.then((_) => shutdownCompleted = true));
          await Future<void>.delayed(const Duration(milliseconds: 10));

          expect(shutdownCompleted, isFalse);
          expect(disconnectOrder, isEmpty);

          connectCompleter.complete();
          await shutdown;

          expect(disconnectOrder, ['machine']);
        },
      );

      test('waits for an in-flight watchdog reconnect', () async {
        final disconnectStarted = Completer<void>();
        final disconnectCompleter = Completer<void>();
        final machine = _FakeDe1(
          disconnectStarted: disconnectStarted,
          disconnectCompleter: disconnectCompleter,
        );
        connectionManager.snapshotStalenessTimeout = Duration.zero;
        mockDe1Controller.de1Subject.add(machine);

        await disconnectStarted.future;
        mockDe1Controller.de1Subject.add(null);
        await Future<void>.delayed(Duration.zero);

        var shutdownCompleted = false;
        final shutdown = connectionManager.shutdown();
        unawaited(shutdown.then((_) => shutdownCompleted = true));
        await Future<void>.delayed(const Duration(milliseconds: 10));

        expect(shutdownCompleted, isFalse);

        disconnectCompleter.complete();
        await shutdown;
      });

      test(
        'disconnects machine before scale despite machine failure',
        () async {
          await connectionManager.dispose();
          mockDe1Controller = MockDe1Controller(
            controller: DeviceController([dummyDiscoveryService]),
          );
          final scaleController = ScaleController();
          connectionManager = ConnectionManager(
            deviceScanner: mockScanner,
            de1Controller: mockDe1Controller,
            scaleController: scaleController,
            settingsController: settingsController,
          );
          final disconnectOrder = <String>[];
          final machine = _FakeDe1(
            disconnectOrder: disconnectOrder,
            disconnectError: StateError('disconnect failed'),
          );
          final scale = _TrackingScale(disconnectOrder);

          await connectionManager.connectMachine(machine);
          await connectionManager.connectScale(scale);
          await connectionManager.shutdown();

          expect(disconnectOrder, ['machine', 'scale']);
        },
      );
    });

    test('initial powered off then on recovers preferred machine', () async {
      await settingsController.setPreferredMachineId('pref-de1');
      connectionManager.adapterRecoveryDebounce = Duration.zero;

      mockScanner.mockAdapterState(AdapterState.poweredOff);
      mockScanner.mockAdapterState(AdapterState.poweredOn);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(mockScanner.scanCallCount, 1);
      expect(
        connectionManager.currentStatus.intent,
        ConnectionIntent.adapterRecovery,
      );
    });

    test('initial unknown then on recovers preferred machine', () async {
      await settingsController.setPreferredMachineId('pref-de1');
      connectionManager.adapterRecoveryDebounce = Duration.zero;

      mockScanner.mockAdapterState(AdapterState.unknown);
      mockScanner.mockAdapterState(AdapterState.poweredOn);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(mockScanner.scanCallCount, 1);
      expect(
        connectionManager.currentStatus.intent,
        ConnectionIntent.adapterRecovery,
      );
    });

    test('duplicate powered on emissions coalesce recovery', () async {
      await settingsController.setPreferredMachineId('pref-de1');
      connectionManager.adapterRecoveryDebounce = Duration.zero;

      mockScanner.mockAdapterState(AdapterState.poweredOff);
      mockScanner.mockAdapterState(AdapterState.poweredOn);
      mockScanner.mockAdapterState(AdapterState.poweredOn);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(mockScanner.scanCallCount, 1);
    });

    group('connect', () {
      test('emits scanning phase during scan', () async {
        final phases = <ConnectionPhase>[];
        final sub = connectionManager.status.listen((s) {
          phases.add(s.phase);
        });

        await connectionManager.connect();
        await Future.delayed(Duration.zero);

        expect(phases, contains(ConnectionPhase.scanning));

        await sub.cancel();
      });

      test('already-connected machine is not quick-connected again', () async {
        await connectionManager.dispose();
        await settingsController.setPreferredMachineId('pref-de1');
        mockSettingsService.setRememberedDevices(
          RememberedDevice.encodeList([
            const RememberedDevice(
              id: 'pref-de1',
              name: 'DE1',
              type: DeviceType.machine,
            ),
          ]),
        );
        final remembered = RememberedDevicesController(
          machineConnections: const Stream.empty(),
          scaleConnections: const Stream.empty(),
          settings: mockSettingsService,
        );
        await remembered.initialize();

        final connectedMachine = _FakeDe1(deviceId: 'pref-de1');
        mockDe1Controller.de1Subject.add(connectedMachine);
        mockScanner.quickConnectResult = _FakeDe1(deviceId: 'pref-de1');
        connectionManager = ConnectionManager(
          deviceScanner: mockScanner,
          de1Controller: mockDe1Controller,
          scaleController: mockScaleController,
          settingsController: settingsController,
          rememberedDevices: remembered,
        );
        await Future<void>.delayed(Duration.zero);

        await connectionManager.connect();

        expect(mockScanner.quickConnectCallCount, 0);
        remembered.dispose();
      });

      test('explicit scan bypasses machine quick-connect', () async {
        await connectionManager.dispose();
        await settingsController.setPreferredMachineId('pref-de1');
        mockSettingsService.setRememberedDevices(
          RememberedDevice.encodeList([
            const RememberedDevice(
              id: 'pref-de1',
              name: 'DE1',
              type: DeviceType.machine,
            ),
          ]),
        );
        final remembered = RememberedDevicesController(
          machineConnections: const Stream.empty(),
          scaleConnections: const Stream.empty(),
          settings: mockSettingsService,
        );
        await remembered.initialize();
        mockScanner.quickConnectResult = _FakeDe1(deviceId: 'pref-de1');
        connectionManager = ConnectionManager(
          deviceScanner: mockScanner,
          de1Controller: mockDe1Controller,
          scaleController: mockScaleController,
          settingsController: settingsController,
          rememberedDevices: remembered,
        );

        await connectionManager.scanAndConnect();

        expect(mockScanner.quickConnectCallCount, 0);
        expect(mockScanner.scanCallCount, 1);
        remembered.dispose();
      });

      test(
        'explicit scan waits for discovery before connecting preferred',
        () async {
          await settingsController.setPreferredMachineId('pref-de1');
          final preferred = _FakeDe1(deviceId: 'pref-de1');
          mockScanner.addDevice(preferred);
          mockScanner.scanCompleter = Completer<void>();

          final scan = connectionManager.scanAndConnect();
          await Future<void>.delayed(Duration.zero);

          expect(mockDe1Controller.connectCalls, isEmpty);

          mockScanner.scanCompleter!.complete();
          await scan;

          expect(mockDe1Controller.connectCalls, [same(preferred)]);
        },
      );

      test('no preferred, 0 machines → stays idle', () async {
        await connectionManager.connect();
        await Future.delayed(Duration.zero);

        expect(connectionManager.currentStatus.phase, ConnectionPhase.idle);
        expect(connectionManager.currentStatus.pendingAmbiguity, isNull);
        expect(mockDe1Controller.connectCalls, isEmpty);
      });

      test(
        'no preferred, 1 machine → auto-connects and saves preference',
        () async {
          final fakeDe1 = _FakeDe1(deviceId: 'solo-de1');
          mockScanner.addDevice(fakeDe1);
          await Future.delayed(Duration.zero);

          await connectionManager.connect();
          await Future.delayed(Duration.zero);

          expect(mockDe1Controller.connectCalls, hasLength(1));
          expect(mockDe1Controller.connectCalls.first, same(fakeDe1));
          expect(settingsController.preferredMachineId, 'solo-de1');
          expect(connectionManager.currentStatus.phase, ConnectionPhase.ready);
        },
      );

      test(
        'no preferred, many machines → emits machinePicker ambiguity',
        () async {
          final de1a = _FakeDe1(deviceId: 'de1-a');
          final de1b = _FakeDe1(deviceId: 'de1-b');
          mockScanner.addDevice(de1a);
          mockScanner.addDevice(de1b);
          await Future.delayed(Duration.zero);

          await connectionManager.connect();
          await Future.delayed(Duration.zero);

          expect(connectionManager.currentStatus.phase, ConnectionPhase.idle);
          expect(
            connectionManager.currentStatus.pendingAmbiguity,
            AmbiguityReason.machinePicker,
          );
          expect(connectionManager.currentStatus.foundMachines, hasLength(2));
          expect(mockDe1Controller.connectCalls, isEmpty);
        },
      );

      test('preferred machine found → connects directly', () async {
        await settingsController.setPreferredMachineId('pref-de1');

        final prefDe1 = _FakeDe1(deviceId: 'pref-de1');
        mockScanner.addDevice(prefDe1);
        await Future.delayed(Duration.zero);

        await connectionManager.connect();
        await Future.delayed(Duration.zero);

        expect(mockDe1Controller.connectCalls, hasLength(1));
        expect(mockDe1Controller.connectCalls.first.deviceId, 'pref-de1');
        expect(connectionManager.currentStatus.phase, ConnectionPhase.ready);
      });

      test(
        'preferred machine not found, others available → emits machinePicker ambiguity',
        () async {
          await settingsController.setPreferredMachineId('missing-de1');

          final otherDe1 = _FakeDe1(deviceId: 'other-de1');
          mockScanner.addDevice(otherDe1);
          await Future.delayed(Duration.zero);

          await connectionManager.connect();
          await Future.delayed(Duration.zero);

          expect(connectionManager.currentStatus.phase, ConnectionPhase.idle);
          expect(
            connectionManager.currentStatus.pendingAmbiguity,
            AmbiguityReason.machinePicker,
          );
          expect(mockDe1Controller.connectCalls, isEmpty);
        },
      );

      test(
        'failed preferred machine emits ambiguity for alternatives',
        () async {
          await settingsController.setPreferredMachineId('pref-de1');
          mockDe1Controller.shouldFailConnect = true;
          mockScanner.addDevice(_FakeDe1(deviceId: 'pref-de1'));
          mockScanner.addDevice(_FakeDe1(deviceId: 'alternative-de1'));
          await Future.delayed(Duration.zero);

          await connectionManager.scanAndConnect();

          expect(
            connectionManager.currentStatus.pendingAmbiguity,
            AmbiguityReason.machinePicker,
          );
        },
      );

      test('preferred machine not found, no others → stays idle', () async {
        await settingsController.setPreferredMachineId('missing-de1');

        await connectionManager.connect();
        await Future.delayed(Duration.zero);

        expect(connectionManager.currentStatus.phase, ConnectionPhase.idle);
        expect(connectionManager.currentStatus.pendingAmbiguity, isNull);
        expect(mockDe1Controller.connectCalls, isEmpty);
      });

      group('scale phase', () {
        test('occupied machine fills only the missing scale slot', () async {
          final connectedMachine = _FakeDe1(deviceId: 'connected-de1');
          mockDe1Controller.de1Subject.add(connectedMachine);
          final scale = TestScale(deviceId: 'missing-slot-scale');
          mockScanner.addDevice(_FakeDe1(deviceId: 'alternative-de1'));
          mockScanner.addDevice(scale);
          await Future.delayed(Duration.zero);

          await connectionManager.scanAndConnect();

          expect(mockDe1Controller.connectCalls, isEmpty);
          expect(mockScaleController.connectCalls, [same(scale)]);
        });

        test('occupied scale fills only the missing machine slot', () async {
          mockScaleController.mockEmitConnectionState(
            ConnectionState.connected,
          );
          mockScaleController.debugSetLastConnectedId('connected-scale');
          final machine = _FakeDe1(deviceId: 'missing-slot-de1');
          mockScanner.addDevice(machine);
          mockScanner.addDevice(TestScale(deviceId: 'alternative-scale'));
          await Future.delayed(Duration.zero);

          await connectionManager.scanAndConnect();

          expect(mockDe1Controller.connectCalls, [same(machine)]);
          expect(mockScaleController.connectCalls, isEmpty);
        });

        test('occupied machine and scale are both preserved', () async {
          mockDe1Controller.de1Subject.add(_FakeDe1(deviceId: 'connected-de1'));
          mockScaleController.mockEmitConnectionState(
            ConnectionState.connected,
          );
          mockScaleController.debugSetLastConnectedId('connected-scale');
          mockScanner.addDevice(_FakeDe1(deviceId: 'alternative-de1'));
          mockScanner.addDevice(TestScale(deviceId: 'alternative-scale'));
          await Future.delayed(Duration.zero);

          await connectionManager.scanAndConnect();

          expect(mockDe1Controller.connectCalls, isEmpty);
          expect(mockScaleController.connectCalls, isEmpty);
        });

        test('connects a scale when no machine is found', () async {
          final scale = TestScale(deviceId: 'only-scale');
          mockScanner.addDevice(scale);
          await Future.delayed(Duration.zero);

          await connectionManager.scanAndConnect();

          expect(mockScaleController.connectCalls, [same(scale)]);
          expect(connectionManager.currentStatus.phase, ConnectionPhase.idle);
        });

        test('does not replace an already-connected scale', () async {
          final connectedScale = TestScale(deviceId: 'connected-scale');
          mockScaleController.mockEmitConnectionState(
            ConnectionState.connected,
          );
          mockScaleController.debugSetLastConnectedId(connectedScale.deviceId);
          mockScanner.addDevice(TestScale(deviceId: 'alternative-scale'));
          await Future.delayed(Duration.zero);

          await connectionManager.scanAndConnect();

          expect(mockScaleController.connectCalls, isEmpty);
        });

        test(
          'machine ambiguity defers scale until machine selection',
          () async {
            final machineA = _FakeDe1(deviceId: 'de1-a');
            final machineB = _FakeDe1(deviceId: 'de1-b');
            final scale = TestScale(deviceId: 'only-scale');
            mockScanner.addDevice(machineA);
            mockScanner.addDevice(machineB);
            mockScanner.addDevice(scale);
            await Future.delayed(Duration.zero);

            await connectionManager.scanAndConnect();

            expect(
              connectionManager.currentStatus.pendingAmbiguity,
              AmbiguityReason.machinePicker,
            );
            expect(mockScaleController.connectCalls, isEmpty);

            await connectionManager.selectMachine(machineA);

            expect(mockScaleController.connectCalls, [same(scale)]);
            expect(connectionManager.currentStatus.pendingAmbiguity, isNull);
          },
        );

        test('machine ambiguity resolves before scale ambiguity', () async {
          await settingsController.setPreferredMachineId('missing-de1');
          await settingsController.setPreferredScaleId('missing-scale');
          final machine = _FakeDe1(deviceId: 'alternative-de1');
          mockScanner.addDevice(machine);
          mockScanner.addDevice(TestScale(deviceId: 'alternative-scale'));
          await Future.delayed(Duration.zero);

          await connectionManager.scanAndConnect();

          expect(
            connectionManager.currentStatus.pendingAmbiguity,
            AmbiguityReason.machinePicker,
          );

          await connectionManager.selectMachine(machine);

          expect(
            connectionManager.currentStatus.pendingAmbiguity,
            AmbiguityReason.scalePicker,
          );
          expect(mockScaleController.connectCalls, isEmpty);
        });

        test(
          'missing preferred scale emits ambiguity for alternatives',
          () async {
            await settingsController.setPreferredScaleId('missing-scale');
            final alternative = TestScale(deviceId: 'alternative-scale');
            mockScanner.addDevice(alternative);
            await Future.delayed(Duration.zero);

            await connectionManager.scanAndConnect();

            expect(mockScaleController.connectCalls, isEmpty);
            expect(
              connectionManager.currentStatus.pendingAmbiguity,
              AmbiguityReason.scalePicker,
            );
          },
        );

        test('preferred scale found → connects after machine', () async {
          await settingsController.setPreferredScaleId('pref-scale');

          final fakeDe1 = _FakeDe1(deviceId: 'de1');
          final testScale = TestScale(deviceId: 'pref-scale');
          mockScanner.addDevice(fakeDe1);
          mockScanner.addDevice(testScale);
          await Future.delayed(Duration.zero);

          await connectionManager.connect();
          await Future.delayed(Duration.zero);

          expect(mockDe1Controller.connectCalls, hasLength(1));
          expect(mockScaleController.connectCalls, hasLength(1));
          expect(mockScaleController.connectCalls.first.deviceId, 'pref-scale');
          expect(settingsController.preferredScaleId, 'pref-scale');
        });

        test('no preferred, 1 scale → connects silently', () async {
          final fakeDe1 = _FakeDe1(deviceId: 'de1');
          final testScale = TestScale(deviceId: 'only-scale');
          mockScanner.addDevice(fakeDe1);
          mockScanner.addDevice(testScale);
          await Future.delayed(Duration.zero);

          await connectionManager.connect();
          await Future.delayed(Duration.zero);

          expect(mockScaleController.connectCalls, hasLength(1));
          expect(mockScaleController.connectCalls.first.deviceId, 'only-scale');
        });

        test('no preferred, many scales → skips scale', () async {
          final fakeDe1 = _FakeDe1(deviceId: 'de1');
          final scale1 = TestScale(deviceId: 'scale-1');
          final scale2 = TestScale(deviceId: 'scale-2');
          mockScanner.addDevice(fakeDe1);
          mockScanner.addDevice(scale1);
          mockScanner.addDevice(scale2);
          await Future.delayed(Duration.zero);

          await connectionManager.connect();
          await Future.delayed(Duration.zero);

          expect(mockScaleController.connectCalls, isEmpty);
        });

        test(
          'preferred scale not found → does nothing, phase stays ready',
          () async {
            await settingsController.setPreferredScaleId('missing-scale');

            final fakeDe1 = _FakeDe1(deviceId: 'de1');
            mockScanner.addDevice(fakeDe1);
            await Future.delayed(Duration.zero);

            await connectionManager.connect();
            await Future.delayed(Duration.zero);

            expect(mockScaleController.connectCalls, isEmpty);
            expect(
              connectionManager.currentStatus.phase,
              ConnectionPhase.ready,
            );
          },
        );

        test(
          'failed preferred scale emits ambiguity for alternatives',
          () async {
            await settingsController.setPreferredScaleId('pref-scale');
            mockScaleController.shouldFailConnect = true;
            mockScanner.addDevice(TestScale(deviceId: 'pref-scale'));
            mockScanner.addDevice(TestScale(deviceId: 'alternative-scale'));
            await Future.delayed(Duration.zero);

            await connectionManager.scanAndConnect();

            expect(
              connectionManager.currentStatus.pendingAmbiguity,
              AmbiguityReason.scalePicker,
            );
          },
        );

        test(
          'machine failure still fills scale slot and stays visible',
          () async {
            mockDe1Controller.shouldFailConnect = true;
            mockScanner.addDevice(_FakeDe1(deviceId: 'failed-machine'));
            mockScanner.addDevice(TestScale(deviceId: 'available-scale'));
            await Future.delayed(Duration.zero);

            await connectionManager.scanAndConnect();

            expect(mockScaleController.connectCalls, hasLength(1));
            expect(connectionManager.currentStatus.phase, ConnectionPhase.idle);
            expect(
              connectionManager.currentStatus.error?.kind,
              ConnectionErrorKind.machineConnectFailed,
            );
          },
        );

        test('scale failure does not affect machine connection', () async {
          mockScaleController.shouldFailConnect = true;

          final fakeDe1 = _FakeDe1(deviceId: 'de1');
          final testScale = TestScale(deviceId: 'fail-scale');
          mockScanner.addDevice(fakeDe1);
          mockScanner.addDevice(testScale);
          await Future.delayed(Duration.zero);

          await connectionManager.connect();
          await Future.delayed(Duration.zero);

          expect(mockDe1Controller.connectCalls, hasLength(1));
          expect(mockScaleController.connectCalls, hasLength(1));
          expect(connectionManager.currentStatus.phase, ConnectionPhase.ready);
        });
      });

      group('scale failure recovery (comms-harden #4)', () {
        test(
          'after scaleOnly connect fails, next connect retries scale',
          () async {
            mockScaleController.shouldFailConnect = true;

            final scale = TestScale(deviceId: 'scale-1');
            mockScanner.addDevice(scale);
            await Future.delayed(Duration.zero);

            await connectionManager.connect(scaleOnly: true);
            await Future.delayed(Duration.zero);
            expect(
              mockScaleController.connectCalls,
              hasLength(1),
              reason: 'first scaleOnly attempt should call connectToScale',
            );

            mockScaleController.shouldFailConnect = false;
            await connectionManager.connect(scaleOnly: true);
            await Future.delayed(Duration.zero);

            expect(
              mockScaleController.connectCalls,
              hasLength(2),
              reason:
                  'scale must be retried after a prior failed scaleOnly connect',
            );
          },
        );

        test(
          'after full connect fails on scale phase, next scaleOnly retries',
          () async {
            mockScaleController.shouldFailConnect = true;

            final fakeDe1 = _FakeDe1(deviceId: 'de1');
            final scale = TestScale(deviceId: 'scale-1');
            mockScanner.addDevice(fakeDe1);
            mockScanner.addDevice(scale);
            await Future.delayed(Duration.zero);

            await connectionManager.connect();
            await Future.delayed(Duration.zero);
            expect(
              mockScaleController.connectCalls,
              hasLength(1),
              reason: 'full connect reaches scale phase on first attempt',
            );

            mockScaleController.shouldFailConnect = false;
            await connectionManager.connect(scaleOnly: true);
            await Future.delayed(Duration.zero);

            expect(
              mockScaleController.connectCalls,
              hasLength(2),
              reason:
                  'scale phase must retry after a prior full-connect failure',
            );
          },
        );
      });

      group('early-stop', () {
        test(
          'both preferred set and both connected → calls stopScan',
          () async {
            await settingsController.setPreferredMachineId('pref-de1');
            await settingsController.setPreferredScaleId('pref-scale');

            mockScanner.scanCompleter = Completer<void>();

            final fakeDe1 = _FakeDe1(deviceId: 'pref-de1');
            final testScale = TestScale(deviceId: 'pref-scale');

            final connectFuture = connectionManager.connect();

            await mockScanner.scanningStream.firstWhere((s) => s);

            mockScanner.addDevice(fakeDe1);
            await Future.delayed(Duration.zero);
            mockScanner.addDevice(testScale);
            await Future.delayed(Duration.zero);

            await Future.delayed(Duration.zero);
            await Future.delayed(Duration.zero);

            mockScanner.completeScan();
            await connectFuture;

            expect(mockScanner.stopScanCallCount, 1);
          },
        );

        test('simulated preferred devices emitted together early-connect '
            'and stop the scan', () async {
          settingsController.enableSimulatedDevicesForSession({
            SimulatedDevicesTypes.machine,
            SimulatedDevicesTypes.scale,
          });

          mockScanner.scanCompleter = Completer<void>();

          final fakeDe1 = _FakeSimulatedDe1(deviceId: 'MockDe1');
          final fakeScale = _FakeSimulatedScale(deviceId: 'MockScale');
          mockScanner.queuedScanResults.add([fakeDe1, fakeScale]);

          final connectFuture = connectionManager.connect();
          await mockScanner.scanningStream.firstWhere((s) => s);
          await Future.delayed(Duration.zero);
          await Future.delayed(Duration.zero);

          expect(mockDe1Controller.lastConnectedDe1, same(fakeDe1));
          expect(mockScaleController.connectCalls, hasLength(1));
          expect(mockScaleController.connectCalls.first, same(fakeScale));
          expect(
            mockScanner.stopScanCallCount,
            1,
            reason:
                'both simulated preferred devices are connected; '
                'the scan must stop while still pending',
          );

          mockScanner.completeScan();
          await connectFuture;

          expect(mockScaleController.connectCalls, hasLength(1));
          expect(connectionManager.currentStatus.phase, ConnectionPhase.ready);
        });

        test(
          'only preferred machine set → calls stopScan on machine connect',
          () async {
            await settingsController.setPreferredMachineId('pref-de1');

            mockScanner.scanCompleter = Completer<void>();

            final fakeDe1 = _FakeDe1(deviceId: 'pref-de1');

            final connectFuture = connectionManager.connect();
            await mockScanner.scanningStream.firstWhere((s) => s);

            mockScanner.addDevice(fakeDe1);
            await Future.delayed(Duration.zero);
            await Future.delayed(Duration.zero);

            mockScanner.completeScan();
            await connectFuture;

            expect(mockScanner.stopScanCallCount, 1);
          },
        );

        test('only preferred machine, scale advertises after early-stop → '
            'deferred rescan connects it', () async {
          await settingsController.setPreferredMachineId('pref-de1');
          connectionManager.deferredScaleScanDelay = Duration.zero;

          mockScanner.scanCompleter = Completer<void>();

          final fakeDe1 = _FakeDe1(deviceId: 'pref-de1');

          final connectFuture = connectionManager.connect();
          await mockScanner.scanningStream.firstWhere((s) => s);

          mockScanner.addDevice(fakeDe1);
          await Future.delayed(Duration.zero);
          await Future.delayed(Duration.zero);

          mockScanner.completeScan();
          await connectFuture;

          expect(mockScanner.stopScanCallCount, 1);
          expect(mockScaleController.connectCalls, isEmpty);
          expect(connectionManager.currentStatus.phase, ConnectionPhase.ready);

          mockScanner.addDevice(TestScale(deviceId: 'late-scale'));

          await Future.delayed(const Duration(milliseconds: 1));
          await Future.delayed(Duration.zero);
          await Future.delayed(Duration.zero);
          await Future.delayed(Duration.zero);

          expect(
            mockScaleController.connectCalls,
            hasLength(1),
            reason: 'deferred rescan must connect the late scale',
          );
          expect(mockScaleController.connectCalls.first.deviceId, 'late-scale');
          expect(connectionManager.currentStatus.phase, ConnectionPhase.ready);
        });

        test('only preferred machine, no scale ever → deferred rescan is a '
            'no-op, machine stays ready', () async {
          await settingsController.setPreferredMachineId('pref-de1');
          connectionManager.deferredScaleScanDelay = Duration.zero;

          mockScanner.scanCompleter = Completer<void>();

          final fakeDe1 = _FakeDe1(deviceId: 'pref-de1');

          final connectFuture = connectionManager.connect();
          await mockScanner.scanningStream.firstWhere((s) => s);

          mockScanner.addDevice(fakeDe1);
          await Future.delayed(Duration.zero);
          await Future.delayed(Duration.zero);

          mockScanner.completeScan();
          await connectFuture;

          expect(connectionManager.currentStatus.phase, ConnectionPhase.ready);

          await Future.delayed(const Duration(milliseconds: 1));
          await Future.delayed(Duration.zero);
          await Future.delayed(Duration.zero);
          await Future.delayed(Duration.zero);

          expect(mockScaleController.connectCalls, isEmpty);
          expect(connectionManager.currentStatus.phase, ConnectionPhase.ready);
        });

        test('machine disconnect cancels deferred scale rescan', () async {
          await settingsController.setPreferredMachineId('pref-de1');
          connectionManager.deferredScaleScanDelay = const Duration(
            milliseconds: 10,
          );
          mockScanner.scanCompleter = Completer<void>();

          final fakeDe1 = _FakeDe1(deviceId: 'pref-de1');
          final connectFuture = connectionManager.connect();
          await mockScanner.scanningStream.firstWhere((s) => s);

          mockScanner.addDevice(fakeDe1);
          await Future.delayed(Duration.zero);
          await Future.delayed(Duration.zero);
          mockScanner.completeScan();
          await connectFuture;

          final scanningEvents = <bool>[];
          final sub = mockScanner.scanningStream.listen(scanningEvents.add);
          await Future<void>.delayed(Duration.zero);

          mockDe1Controller.de1Subject.add(null);
          await Future<void>.delayed(const Duration(milliseconds: 20));
          await Future<void>.delayed(Duration.zero);

          expect(scanningEvents, isNot(contains(true)));
          expect(mockScaleController.connectCalls, isEmpty);
          await sub.cancel();
        });

        test('only preferred scale set → does not call stopScan', () async {
          await settingsController.setPreferredScaleId('pref-scale');

          mockScanner.scanCompleter = Completer<void>();

          final testScale = TestScale(deviceId: 'pref-scale');

          final connectFuture = connectionManager.connect();
          await mockScanner.scanningStream.firstWhere((s) => s);

          mockScanner.addDevice(testScale);
          await Future.delayed(Duration.zero);
          await Future.delayed(Duration.zero);

          mockScanner.completeScan();
          await connectFuture;

          expect(mockScanner.stopScanCallCount, 0);
        });

        test('no preferences set → does not call stopScan', () async {
          mockScanner.scanCompleter = Completer<void>();

          final fakeDe1 = _FakeDe1(deviceId: 'de1');
          final testScale = TestScale(deviceId: 'scale');

          final connectFuture = connectionManager.connect();
          await mockScanner.scanningStream.firstWhere((s) => s);

          mockScanner.addDevice(fakeDe1);
          mockScanner.addDevice(testScale);
          await Future.delayed(Duration.zero);

          mockScanner.completeScan();
          await connectFuture;

          expect(mockScanner.stopScanCallCount, 0);
        });

        test(
          'full scan completed (no early stop) → no deferred rescan armed',
          () async {
            connectionManager.deferredScaleScanDelay = Duration.zero;

            mockScanner.scanCompleter = Completer<void>();

            final fakeDe1 = _FakeDe1(deviceId: 'de1');

            final connectFuture = connectionManager.connect();
            await mockScanner.scanningStream.firstWhere((s) => s);

            mockScanner.addDevice(fakeDe1);
            await Future.delayed(Duration.zero);

            mockScanner.completeScan();
            await connectFuture;

            expect(mockScanner.stopScanCallCount, 0);
            expect(mockScaleController.connectCalls, isEmpty);

            mockScanner.addDevice(TestScale(deviceId: 'late-scale'));
            await Future.delayed(const Duration(milliseconds: 1));
            await Future.delayed(Duration.zero);
            await Future.delayed(Duration.zero);

            expect(
              mockScaleController.connectCalls,
              isEmpty,
              reason: 'a completed full scan must not arm a deferred rescan',
            );
          },
        );

        test(
          'both preferred set but only machine found → does not call stopScan',
          () async {
            await settingsController.setPreferredMachineId('pref-de1');
            await settingsController.setPreferredScaleId('pref-scale');

            mockScanner.scanCompleter = Completer<void>();

            final fakeDe1 = _FakeDe1(deviceId: 'pref-de1');

            final connectFuture = connectionManager.connect();
            await mockScanner.scanningStream.firstWhere((s) => s);

            mockScanner.addDevice(fakeDe1);
            await Future.delayed(Duration.zero);
            await Future.delayed(Duration.zero);

            mockScanner.completeScan();
            await connectFuture;

            expect(mockScanner.stopScanCallCount, 0);
          },
        );
      });
    });

    group('connect(scaleOnly: true)', () {
      test('skips machine preference policy', () async {
        await settingsController.setPreferredMachineId('pref-de1');

        final fakeDe1 = _FakeDe1(deviceId: 'pref-de1');
        mockScanner.addDevice(fakeDe1);
        await Future.delayed(Duration.zero);

        await connectionManager.connect(scaleOnly: true);
        await Future.delayed(Duration.zero);

        expect(mockDe1Controller.connectCalls, isEmpty);
      });

      test('connects preferred scale', () async {
        await settingsController.setPreferredScaleId('pref-scale');

        final testScale = TestScale(deviceId: 'pref-scale');
        mockScanner.addDevice(testScale);
        await Future.delayed(Duration.zero);

        await connectionManager.connect(scaleOnly: true);
        await Future.delayed(Duration.zero);

        expect(mockScaleController.connectCalls, hasLength(1));
        expect(mockScaleController.connectCalls.first.deviceId, 'pref-scale');
      });

      test('does not call stopScan even with preferred scale set', () async {
        await settingsController.setPreferredScaleId('pref-scale');

        mockScanner.scanCompleter = Completer<void>();

        final testScale = TestScale(deviceId: 'pref-scale');

        final connectFuture = connectionManager.connect(scaleOnly: true);
        await mockScanner.scanningStream.firstWhere((s) => s);

        mockScanner.addDevice(testScale);
        await Future.delayed(Duration.zero);
        await Future.delayed(Duration.zero);

        mockScanner.completeScan();
        await connectFuture;

        expect(mockScanner.stopScanCallCount, 0);
      });

      test(
        'auto-scans for preferred scale when machine is ready and scale is missing',
        () async {
          await settingsController.setPreferredScaleId('pref-scale');
          connectionManager.scaleReconnectBaseDelay = Duration.zero;
          mockScanner.scanCompleter = Completer<void>();

          mockDe1Controller.de1Subject.add(_FakeDe1(deviceId: 'connected-de1'));
          await mockScanner.scanningStream.firstWhere((s) => s);

          final testScale = TestScale(deviceId: 'pref-scale');
          mockScanner.addDevice(testScale);
          await Future.delayed(Duration.zero);
          await Future.delayed(Duration.zero);

          expect(mockScaleController.connectCalls, hasLength(1));
          expect(mockScaleController.connectCalls.first.deviceId, 'pref-scale');
          expect(mockScanner.stopScanCallCount, 0);

          mockScanner.completeScan();
          await Future.delayed(Duration.zero);
        },
      );

      test('concurrent scaleOnly during another connect is queued and '
          'drained after the in-flight call (comms-harden #9)', () async {
        mockScanner.scanCompleter = Completer<void>();
        final future1 = connectionManager.connect(scaleOnly: true);

        final future2 = connectionManager.connect(scaleOnly: true);
        final future3 = connectionManager.connect(scaleOnly: true);

        await Future.delayed(Duration.zero);
        expect(future2, isA<Future<void>>());
        expect(future3, isA<Future<void>>());
        var future2Done = false;
        var future3Done = false;
        future2.then((_) => future2Done = true);
        future3.then((_) => future3Done = true);
        await Future.delayed(Duration.zero);
        expect(future2Done, isFalse);
        expect(future3Done, isFalse);

        mockScanner.completeScan();
        await future1;
        await Future.delayed(Duration.zero);
        await Future.delayed(Duration.zero);

        await future2;
        await future3;
        expect(future2Done, isTrue);
        expect(future3Done, isTrue);
      });

      test(
        'queued scaleOnly retains preferred-scale early connection',
        () async {
          await settingsController.setPreferredScaleId('pref-scale');
          final preferredScale = TestScale(deviceId: 'pref-scale');
          final firstScan = Completer<void>();
          final recoveryScan = Completer<void>();
          mockScanner.queuedScanCompleters.addAll([firstScan, recoveryScan]);
          mockScanner.queuedScanResults.addAll([
            <Device>[],
            <Device>[preferredScale],
          ]);

          final explicitScan = connectionManager.scanAndConnect();
          await Future<void>.delayed(Duration.zero);
          final queuedRecovery = connectionManager.connect(scaleOnly: true);

          firstScan.complete();
          await Future<void>.delayed(Duration.zero);
          await Future<void>.delayed(Duration.zero);

          expect(mockScanner.scanCallCount, 2);
          expect(mockScaleController.connectCalls, [same(preferredScale)]);

          recoveryScan.complete();
          await explicitScan;
          await queuedRecovery;
        },
      );

      test('scale recovery does not supersede a pending selection', () async {
        final machineA = _FakeDe1(deviceId: 'de1-a');
        final machineB = _FakeDe1(deviceId: 'de1-b');
        final scale = TestScale(deviceId: 'scale');
        mockScanner.addDevice(machineA);
        mockScanner.addDevice(machineB);
        mockScanner.addDevice(scale);

        await connectionManager.scanAndConnect();
        final scansBeforeRecovery = mockScanner.scanCallCount;

        await connectionManager.connect(scaleOnly: true);

        expect(mockScanner.scanCallCount, scansBeforeRecovery);
        expect(
          connectionManager.currentStatus.pendingAmbiguity,
          AmbiguityReason.machinePicker,
        );

        await connectionManager.selectMachine(machineA);
        expect(mockScaleController.connectCalls, [same(scale)]);
      });

      test(
        'non-scaleOnly concurrent connect is still dropped (no queue)',
        () async {
          mockScanner.scanCompleter = Completer<void>();
          final future1 = connectionManager.connect();

          final future2 = connectionManager.connect();
          await future2;

          mockScanner.completeScan();
          await future1;
        },
      );
    });

    group('ScanReport', () {
      test('emits ScanReport with scan results after scan completes', () async {
        mockScanner.scanCompleter = Completer();
        final connectFuture = connectionManager.connect();
        await Future.delayed(Duration.zero);

        mockScanner.addDevice(_FakeDe1(deviceId: 'solo-de1'));
        mockScanner.completeScan();
        await connectFuture;

        final report = connectionManager.lastScanReport;
        expect(report, isNotNull);
        expect(report!.matchedDevices, hasLength(1));
        expect(report.matchedDevices.first.deviceId, 'solo-de1');
        expect(report.scanTerminationReason, ScanTerminationReason.completed);
      });

      test(
        'ScanReport waits for picker selection and retained scale phase',
        () async {
          final machineA = _FakeDe1(deviceId: 'de1-a');
          final machineB = _FakeDe1(deviceId: 'de1-b');
          final scale = TestScale(deviceId: 'scale');
          mockScanner.addDevice(machineA);
          mockScanner.addDevice(machineB);
          mockScanner.addDevice(scale);
          final reports = <ScanReport>[];
          final sub = connectionManager.scanReportStream.listen(reports.add);

          await connectionManager.scanAndConnect();

          expect(reports, isEmpty);
          expect(
            connectionManager.currentStatus.pendingAmbiguity,
            AmbiguityReason.machinePicker,
          );

          await connectionManager.selectMachine(machineA);

          expect(mockDe1Controller.connectCalls, [same(machineA)]);
          expect(mockScaleController.connectCalls, [same(scale)]);
          expect(connectionManager.currentStatus.pendingAmbiguity, isNull);
          expect(connectionManager.lastScanReport, isNotNull);
          await Future<void>.delayed(Duration.zero);
          expect(reports, hasLength(1));
          final machineResult = reports.single.matchedDevices.firstWhere(
            (device) => device.deviceId == machineA.deviceId,
          );
          final scaleResult = reports.single.matchedDevices.firstWhere(
            (device) => device.deviceId == scale.deviceId,
          );
          expect(machineResult.connectionAttempted, isTrue);
          expect(machineResult.connectionResult?.success, isTrue);
          expect(scaleResult.connectionAttempted, isTrue);
          expect(scaleResult.connectionResult?.success, isTrue);
          await sub.cancel();
        },
      );

      test(
        'superseding scan cancels report and rejects stale selection',
        () async {
          final staleA = _FakeDe1(deviceId: 'stale-a');
          final staleB = _FakeDe1(deviceId: 'stale-b');
          mockScanner.addDevice(staleA);
          mockScanner.addDevice(staleB);
          final reports = <ScanReport>[];
          final sub = connectionManager.scanReportStream.listen(reports.add);

          await connectionManager.scanAndConnect();
          expect(
            connectionManager.currentStatus.pendingAmbiguity,
            AmbiguityReason.machinePicker,
          );

          mockScanner.removeDevice(staleA.deviceId);
          mockScanner.removeDevice(staleB.deviceId);
          final currentA = _FakeDe1(deviceId: 'current-a');
          final currentB = _FakeDe1(deviceId: 'current-b');
          mockScanner.addDevice(currentA);
          mockScanner.addDevice(currentB);
          await connectionManager.scanAndConnect();

          expect(reports, hasLength(1));
          expect(
            reports.single.scanTerminationReason,
            ScanTerminationReason.cancelledByUser,
          );

          final result = await connectionManager.selectMachine(staleA);

          expect(mockDe1Controller.connectCalls, isEmpty);
          expect(result.outcome, ConnectionOutcome.conflict);
          expect(
            connectionManager.currentStatus.pendingAmbiguity,
            AmbiguityReason.machinePicker,
          );
          await sub.cancel();
        },
      );

      test('ScanReport includes preferred device IDs from settings', () async {
        await settingsController.setPreferredMachineId('preferred-123');
        final connectFuture = connectionManager.connect();
        await connectFuture;

        final report = connectionManager.lastScanReport;
        expect(report!.preferredMachineId, 'preferred-123');
      });

      test('ScanReport tracks failed connection attempt', () async {
        mockDe1Controller.shouldFailConnect = true;
        mockScanner.scanCompleter = Completer();
        final connectFuture = connectionManager.connect();
        await Future.delayed(Duration.zero);

        mockScanner.addDevice(_FakeDe1(deviceId: 'fail-de1'));
        mockScanner.completeScan();
        await connectFuture;

        final report = connectionManager.lastScanReport;
        final matched = report!.matchedDevices.first;
        expect(matched.connectionAttempted, isTrue);
        expect(matched.connectionResult!.success, isFalse);
      });

      test('ScanReport records scan duration', () async {
        await connectionManager.connect();

        final report = connectionManager.lastScanReport;
        expect(report, isNotNull);
        expect(report!.scanDuration, isA<Duration>());
      });

      test('ScanReport stream emits on each scan', () async {
        final reports = <ScanReport>[];
        final sub = connectionManager.scanReportStream.listen(reports.add);

        await connectionManager.connect();
        await Future.delayed(Duration.zero);

        expect(reports, hasLength(1));

        await sub.cancel();
      });
    });

    group('connectMachine', () {
      test(
        'delegates to De1Controller and saves preference on success',
        () async {
          final fakeDe1 = _FakeDe1(deviceId: 'my-de1');
          await connectionManager.connectMachine(fakeDe1);

          expect(mockDe1Controller.connectCalls, hasLength(1));
          expect(mockDe1Controller.connectCalls.first, same(fakeDe1));
          expect(settingsController.preferredMachineId, 'my-de1');
        },
      );

      test('does not save preference on failure', () async {
        mockDe1Controller.shouldFailConnect = true;
        final fakeDe1 = _FakeDe1(deviceId: 'fail-de1');

        final result = await connectionManager.connectMachine(fakeDe1);

        await Future.delayed(Duration.zero);

        expect(result.outcome, ConnectionOutcome.failed);
        expect(settingsController.preferredMachineId, isNull);
      });

      test('connect timeout: machine that never responds uses platform budget '
          '(comms-harden #31)', () {
        fakeAsync((async) {
          final timeoutSeconds = Platform.isLinux ? 60 : 30;
          final completer = Completer<void>();
          final slowDe1Controller = _SlowMockDe1Controller(
            controller: DeviceController([dummyDiscoveryService]),
          );
          slowDe1Controller.connectCompleter = completer;

          final manager = ConnectionManager(
            deviceScanner: mockScanner,
            de1Controller: slowDe1Controller,
            scaleController: mockScaleController,
            settingsController: settingsController,
          );

          final fakeDe1 = _FakeDe1(deviceId: 'timeout-de1');
          ConnectionResult? result;
          manager.connectMachine(fakeDe1).then((value) => result = value);

          async.elapse(Duration(seconds: timeoutSeconds + 5));
          async.flushMicrotasks();

          expect(result?.outcome, ConnectionOutcome.timedOut);
          final status = manager.currentStatus;
          expect(status.phase, ConnectionPhase.idle);
          expect(status.error?.kind, ConnectionErrorKind.machineConnectFailed);
          expect(
            status.error?.message,
            contains('did not respond within ${timeoutSeconds}s'),
            reason: 'timeout-specific error message should surface',
          );

          manager.dispose();
        });
      });

      test('rejects concurrent connection attempts', () async {
        final completer = Completer<void>();
        final slowDe1Controller = _SlowMockDe1Controller(
          controller: DeviceController([dummyDiscoveryService]),
        );
        slowDe1Controller.connectCompleter = completer;

        final manager = ConnectionManager(
          deviceScanner: mockScanner,
          de1Controller: slowDe1Controller,
          scaleController: mockScaleController,
          settingsController: settingsController,
        );

        final fakeDe1 = _FakeDe1(deviceId: 'de1-1');

        final future1 = manager.connectMachine(fakeDe1);
        final future2 = manager.connectMachine(_FakeDe1(deviceId: 'de1-2'));
        final secondResult = await future2;

        expect(slowDe1Controller.connectCalls, hasLength(1));
        expect(secondResult.outcome, ConnectionOutcome.conflict);

        completer.complete();
        await future1;

        expect(slowDe1Controller.connectCalls, hasLength(1));

        manager.dispose();
      });

      test('emits target transport while connecting then clears it', () async {
        final statuses = <ConnectionStatus>[];
        final sub = connectionManager.status.listen(statuses.add);

        final fakeDe1 = _FakeDe1(deviceId: 'phase-de1');
        await connectionManager.connectMachine(fakeDe1);
        await Future.delayed(Duration.zero);

        expect(statuses.map((status) => status.phase), [
          ConnectionPhase.idle,
          ConnectionPhase.connectingMachine,
          ConnectionPhase.ready,
        ]);
        expect(statuses[1].activeTargetTransport, TransportType.unknown);
        expect(statuses.last.activeTargetTransport, isNull);

        await sub.cancel();
      });

      test('reverts to idle on failure', () async {
        mockDe1Controller.shouldFailConnect = true;
        final fakeDe1 = _FakeDe1(deviceId: 'err-de1');

        final phases = <ConnectionPhase>[];
        final errors = <ConnectionError?>[];
        final sub = connectionManager.status.listen((s) {
          phases.add(s.phase);
          errors.add(s.error);
        });

        await connectionManager.connectMachine(fakeDe1);
        await Future.delayed(Duration.zero);

        expect(phases, [
          ConnectionPhase.idle,
          ConnectionPhase.connectingMachine,
          ConnectionPhase.idle,
          ConnectionPhase.idle,
        ]);
        final err = errors.last;
        expect(err, isNotNull);
        expect(err!.kind, ConnectionErrorKind.machineConnectFailed);
        expect(err.deviceId, 'err-de1');

        await sub.cancel();
      });

      test(
        'emits machineConnectFailed on De1Controller.connectToDe1 throw',
        () async {
          mockDe1Controller.shouldFailConnect = true;
          final fakeDe1 = _FailingFakeDe1(deviceId: 'D9:11:0B:E6:9F:86');

          await connectionManager.connectMachine(fakeDe1);
          await Future<void>.delayed(Duration.zero);

          final err = connectionManager.currentStatus.error!;
          expect(err.kind, ConnectionErrorKind.machineConnectFailed);
          expect(err.deviceId, 'D9:11:0B:E6:9F:86');
          expect(err.deviceName, 'DE1-D9:11:0B:E6:9F:86');
          expect(err.severity, ConnectionErrorSeverity.error);
        },
      );

      test('emits machineConnectFailed with ble_code in details when '
          'BleConnectException thrown', () async {
        mockDe1Controller.failNextConnectWith = BleConnectException(
          code: '133',
          description: 'GATT Error 133',
          function: 'connect',
        );
        final fakeDe1 = _FailingFakeDe1(deviceId: 'D9:11:0B:E6:9F:86');

        await connectionManager.connectMachine(fakeDe1);
        await Future<void>.delayed(Duration.zero);

        final err = connectionManager.currentStatus.error!;
        expect(err.details, containsPair('ble_code', '133'));
      });
    });

    group('error surfacing', () {
      test('emitting an error publishes it on the status stream', () async {
        final future = connectionManager.status.firstWhere(
          (s) => s.error != null,
        );
        connectionManager.debugEmitError(
          kind: ConnectionErrorKind.scaleConnectFailed,
          severity: ConnectionErrorSeverity.error,
          message: 'test',
        );
        final status = await future;
        expect(status.error!.kind, ConnectionErrorKind.scaleConnectFailed);
        expect(status.error!.timestamp.isUtc, isTrue);
      });

      test(
        'transient error cleared by _publishStatus on scanning transition',
        () async {
          connectionManager.debugEmitError(
            kind: ConnectionErrorKind.scaleConnectFailed,
            severity: ConnectionErrorSeverity.error,
            message: 'test',
          );
          expect(connectionManager.currentStatus.error, isNotNull);

          await connectionManager.connect(scaleOnly: true);
          expect(connectionManager.currentStatus.error, isNull);
        },
      );

      test(
        'sticky error survives phase transition through _publishStatus',
        () async {
          connectionManager.debugEmitError(
            kind: ConnectionErrorKind.adapterOff,
            severity: ConnectionErrorSeverity.error,
            message: 'off',
          );
          expect(connectionManager.currentStatus.error, isNotNull);

          await connectionManager.connect(scaleOnly: true);
          expect(connectionManager.currentStatus.error, isNotNull);
          expect(
            connectionManager.currentStatus.error!.kind,
            ConnectionErrorKind.adapterOff,
          );
        },
      );
    });

    group('connectScale', () {
      test(
        'delegates to ScaleController and saves preference on success',
        () async {
          final testScale = TestScale(deviceId: 'my-scale');
          await connectionManager.connectScale(testScale);

          expect(mockScaleController.connectCalls, hasLength(1));
          expect(mockScaleController.connectCalls.first, same(testScale));
          expect(settingsController.preferredScaleId, 'my-scale');
        },
      );

      test('does not save preference on failure', () async {
        mockScaleController.shouldFailConnect = true;
        final testScale = TestScale(deviceId: 'fail-scale');

        await connectionManager.connectScale(testScale);

        expect(settingsController.preferredScaleId, isNull);
        expect(connectionManager.currentStatus.error, isNotNull);
      });

      test(
        'reports the real outcome so scan reports cannot claim success',
        () async {
          final okResult = await connectionManager.connectScale(
            TestScale(deviceId: 'ok'),
          );
          expect(okResult.success, isTrue);

          mockScaleController.shouldFailConnect = true;
          final failResult = await connectionManager.connectScale(
            TestScale(deviceId: 'fail-scale'),
          );
          expect(failResult.success, isFalse);
          expect(failResult.error, isNotNull);
        },
      );

      test(
        'emits scaleConnectFailed when the scale controller throws',
        () async {
          mockScaleController.shouldFailConnect = true;
          final fakeScale = TestScale(
            deviceId: '50:78:7D:1F:AE:E1',
            name: 'Decent Scale',
          );

          await connectionManager.connectScale(fakeScale);

          final err = connectionManager.currentStatus.error;
          expect(err, isNotNull);
          expect(err!.kind, ConnectionErrorKind.scaleConnectFailed);
          expect(err.deviceId, '50:78:7D:1F:AE:E1');
          expect(err.deviceName, 'Decent Scale');
          expect(err.severity, ConnectionErrorSeverity.error);
        },
      );

      test('emits scaleConnectFailed with ble_code in details when '
          'BleConnectException thrown', () async {
        mockScaleController.failNextConnectWith = BleConnectException(
          code: 'connectionFailed',
          description: 'Timed out',
          function: 'connect',
        );
        final fakeScale = TestScale(
          deviceId: '50:78:7D:1F:AE:E1',
          name: 'Decent Scale',
        );

        await connectionManager.connectScale(fakeScale);

        final err = connectionManager.currentStatus.error!;
        expect(err.details, containsPair('ble_code', 'connectionFailed'));
      });

      test('rejects concurrent scale connection attempts', () async {
        final completer = Completer<void>();
        final slowScaleController = _SlowMockScaleController();
        slowScaleController.connectCompleter = completer;

        final manager = ConnectionManager(
          deviceScanner: mockScanner,
          de1Controller: mockDe1Controller,
          scaleController: slowScaleController,
          settingsController: settingsController,
        );

        final testScale = TestScale(deviceId: 'scale-1');

        final future1 = manager.connectScale(testScale);
        final future2 = manager.connectScale(TestScale(deviceId: 'scale-2'));
        final secondResult = await future2;

        expect(slowScaleController.connectCalls, hasLength(1));
        expect(secondResult.outcome, ConnectionOutcome.conflict);

        completer.complete();
        await future1;

        expect(slowScaleController.connectCalls, hasLength(1));

        manager.dispose();
      });

      test('clearErrorOfKind clears only matching kind', () {
        connectionManager.debugEmitError(
          kind: ConnectionErrorKind.profileUploadFailed,
          severity: 'warning',
          message: 'upload failed',
        );
        expect(
          connectionManager.currentStatus.error?.kind,
          ConnectionErrorKind.profileUploadFailed,
        );

        connectionManager.clearErrorOfKind(
          ConnectionErrorKind.profileUploadFailed,
        );
        expect(connectionManager.currentStatus.error, isNull);

        connectionManager.debugEmitError(
          kind: ConnectionErrorKind.profileUploadFailed,
          severity: 'warning',
          message: 'upload failed',
        );
        connectionManager.debugEmitError(
          kind: ConnectionErrorKind.machineConnectFailed,
          severity: 'error',
          message: 'machine failed',
        );
        connectionManager.clearErrorOfKind(
          ConnectionErrorKind.profileUploadFailed,
        );
        expect(
          connectionManager.currentStatus.error?.kind,
          ConnectionErrorKind.machineConnectFailed,
          reason:
              'clearErrorOfKind for profileUploadFailed must not clear '
              'the current machineConnectFailed',
        );

        connectionManager.clearErrorOfKind(
          ConnectionErrorKind.machineConnectFailed,
        );
        expect(connectionManager.currentStatus.error, isNull);
      });

      test('returns to idle after scale connects without a machine', () async {
        final phases = <ConnectionPhase>[];
        final sub = connectionManager.status.listen((s) {
          phases.add(s.phase);
        });

        final testScale = TestScale(deviceId: 'phase-scale');
        await connectionManager.connectScale(testScale);
        await Future.delayed(Duration.zero);

        expect(phases, [
          ConnectionPhase.idle,
          ConnectionPhase.connectingScale,
          ConnectionPhase.idle,
        ]);

        await sub.cancel();
      });

      test(
        'emits scaleConnectFailed even when fallback phase is ready (machine connected)',
        () async {
          final fakeMachine = _FakeDe1(deviceId: 'D9:11:0B:E6:9F:86');
          await connectionManager.connectMachine(fakeMachine);
          expect(connectionManager.currentStatus.phase, ConnectionPhase.ready);

          mockScaleController.shouldFailConnect = true;
          final fakeScale = TestScale(
            deviceId: '50:78:7D:1F:AE:E1',
            name: 'Decent Scale',
          );
          await connectionManager.connectScale(fakeScale);

          expect(connectionManager.currentStatus.phase, ConnectionPhase.ready);
          expect(connectionManager.currentStatus.error, isNotNull);
          expect(
            connectionManager.currentStatus.error!.kind,
            ConnectionErrorKind.scaleConnectFailed,
          );
        },
      );

      test('sleep during scale connect reports conflict', () async {
        await connectionManager.dispose();
        final slowScaleController = _SlowMockScaleController();
        connectionManager = ConnectionManager(
          deviceScanner: mockScanner,
          de1Controller: mockDe1Controller,
          scaleController: slowScaleController,
          settingsController: settingsController,
        );
        await settingsController.setScalePowerMode(ScalePowerMode.disconnect);

        final fakeMachine = _FakeDe1(deviceId: 'D9:11:0B:E6:9F:86');
        mockDe1Controller.de1Subject.add(fakeMachine);
        await Future<void>.delayed(Duration.zero);
        fakeMachine.emitState(MachineState.idle);
        await Future<void>.delayed(Duration.zero);

        final connectCompleter = Completer<void>();
        slowScaleController.connectCompleter = connectCompleter;
        final future = connectionManager.connectScale(
          TestScale(deviceId: 'pref-scale'),
        );
        await Future<void>.delayed(Duration.zero);
        expect(
          connectionManager.currentStatus.phase,
          ConnectionPhase.connectingScale,
        );

        fakeMachine.emitState(MachineState.sleeping);
        await Future<void>.delayed(Duration.zero);
        connectCompleter.complete();
        final result = await future;
        await Future<void>.delayed(Duration.zero);

        expect(result.outcome, ConnectionOutcome.conflict);
        expect(connectionManager.currentStatus.phase, ConnectionPhase.ready);
        expect(connectionManager.currentStatus.error, isNull);
        expect(settingsController.preferredScaleId, isNull);

        slowScaleController.mockEmitConnectionState(
          ConnectionState.disconnected,
        );
        await Future<void>.delayed(Duration.zero);
        expect(connectionManager.currentStatus.error, isNull);
      });

      test('stays at idle on failure when no machine connected', () async {
        mockScaleController.shouldFailConnect = true;

        final phases = <ConnectionPhase>[];
        final sub = connectionManager.status.listen((s) {
          phases.add(s.phase);
        });

        final testScale = TestScale(deviceId: 'fail-scale');
        await connectionManager.connectScale(testScale);
        await Future.delayed(Duration.zero);

        expect(phases, [
          ConnectionPhase.idle,
          ConnectionPhase.connectingScale,
          ConnectionPhase.idle,
          ConnectionPhase.idle,
        ]);

        final err = connectionManager.currentStatus.error;
        expect(err, isNotNull);
        expect(err!.kind, ConnectionErrorKind.scaleConnectFailed);

        await sub.cancel();
      });
    });

    group('deliberate disconnect tracking', () {
      test('markExpectingDisconnect suppresses next disconnect error', () {
        connectionManager.markExpectingDisconnect('50:78:7D:1F:AE:E1');
        connectionManager.debugNotifyScaleDisconnected('50:78:7D:1F:AE:E1');
        expect(connectionManager.currentStatus.error, isNull);
      });

      test('unexpected disconnect emits scaleDisconnected', () {
        connectionManager.debugNotifyScaleDisconnected('50:78:7D:1F:AE:E1');
        expect(
          connectionManager.currentStatus.error?.kind,
          ConnectionErrorKind.scaleDisconnected,
        );
        expect(
          connectionManager.currentStatus.error?.deviceId,
          '50:78:7D:1F:AE:E1',
        );
      });

      test('TTL clears expectation after 10 seconds', () {
        fakeAsync((async) {
          connectionManager.markExpectingDisconnect('50:78:7D:1F:AE:E1');
          async.elapse(const Duration(seconds: 11));
          connectionManager.debugNotifyScaleDisconnected('50:78:7D:1F:AE:E1');
          expect(
            connectionManager.currentStatus.error?.kind,
            ConnectionErrorKind.scaleDisconnected,
          );
        });
      });

      test('only one matching disconnect is consumed per mark', () {
        connectionManager.markExpectingDisconnect('50:78:7D:1F:AE:E1');
        connectionManager.debugNotifyScaleDisconnected('50:78:7D:1F:AE:E1');
        expect(connectionManager.currentStatus.error, isNull);

        connectionManager.debugNotifyScaleDisconnected('50:78:7D:1F:AE:E1');
        expect(
          connectionManager.currentStatus.error?.kind,
          ConnectionErrorKind.scaleDisconnected,
        );
      });

      test('marks for different devices are independent', () {
        connectionManager.markExpectingDisconnect('50:78:7D:1F:AE:E1');
        connectionManager.debugNotifyMachineDisconnected('D9:11:0B:E6:9F:86');
        expect(
          connectionManager.currentStatus.error?.kind,
          ConnectionErrorKind.machineDisconnected,
        );
      });
    });

    group('disconnect subscribers', () {
      test('scale disconnect during expected flow suppresses error', () async {
        mockScaleController.mockEmitConnectionState(ConnectionState.connected);
        mockScaleController.debugSetLastConnectedId('50:78:7D:1F:AE:E1');
        await Future<void>.delayed(Duration.zero);

        connectionManager.markExpectingDisconnect('50:78:7D:1F:AE:E1');
        mockScaleController.mockEmitConnectionState(
          ConnectionState.disconnected,
        );
        await Future<void>.delayed(Duration.zero);

        expect(connectionManager.currentStatus.error, isNull);
      });

      test(
        'expected scale disconnect does not trigger preferred-scale scan',
        () async {
          await settingsController.setScalePowerMode(ScalePowerMode.disconnect);
          final fakeDe1 = _FakeDe1(deviceId: 'connected-de1');
          mockScaleController.mockEmitConnectionState(
            ConnectionState.connected,
          );
          mockScaleController.debugSetLastConnectedId('pref-scale');
          await settingsController.setPreferredScaleId('pref-scale');
          mockDe1Controller.de1Subject.add(fakeDe1);
          await Future<void>.delayed(Duration.zero);
          fakeDe1.emitState(MachineState.sleeping);
          final scanningEvents = <bool>[];
          final sub = mockScanner.scanningStream.listen(scanningEvents.add);
          await Future<void>.delayed(Duration.zero);

          connectionManager.markExpectingDisconnect('pref-scale');
          mockScaleController.mockEmitConnectionState(
            ConnectionState.disconnected,
          );
          await Future<void>.delayed(Duration.zero);
          await Future<void>.delayed(Duration.zero);

          expect(connectionManager.currentStatus.error, isNull);
          expect(
            scanningEvents,
            isNot(contains(true)),
            reason:
                'power-mode disconnects are deliberate and must not start BLE',
          );
          expect(mockScaleController.connectCalls, isEmpty);
          await sub.cancel();
        },
      );

      test(
        'unexpected preferred scale disconnect keeps scanning and reconnects',
        () async {
          await settingsController.setPreferredScaleId('pref-scale');
          connectionManager.scaleReconnectBaseDelay = Duration.zero;
          final fakeDe1 = _FakeDe1(deviceId: 'connected-de1');
          mockScaleController.mockEmitConnectionState(
            ConnectionState.connected,
          );
          mockScaleController.debugSetLastConnectedId('pref-scale');
          mockDe1Controller.de1Subject.add(fakeDe1);
          await Future<void>.delayed(Duration.zero);
          fakeDe1.emitState(MachineState.idle);
          await Future<void>.delayed(Duration.zero);

          mockScanner.scanCompleter = Completer<void>();
          mockScaleController.mockEmitConnectionState(
            ConnectionState.disconnected,
          );
          await mockScanner.scanningStream.firstWhere((s) => s);

          mockScanner.addDevice(TestScale(deviceId: 'pref-scale'));
          await Future<void>.delayed(Duration.zero);
          await Future<void>.delayed(Duration.zero);
          mockScanner.completeScan();
          await Future<void>.delayed(Duration.zero);

          expect(mockScaleController.connectCalls, hasLength(1));
          expect(mockScaleController.connectCalls.first.deviceId, 'pref-scale');
        },
      );

      test(
        'scale power disconnect pauses while sleeping and resumes when awake',
        () async {
          await settingsController.setPreferredScaleId('pref-scale');
          await settingsController.setScalePowerMode(ScalePowerMode.disconnect);
          connectionManager.scaleReconnectBaseDelay = Duration.zero;

          final fakeDe1 = _FakeDe1(deviceId: 'connected-de1');
          mockScaleController.mockEmitConnectionState(
            ConnectionState.connected,
          );
          mockScaleController.debugSetLastConnectedId('pref-scale');
          mockDe1Controller.de1Subject.add(fakeDe1);
          await Future<void>.delayed(Duration.zero);
          fakeDe1.emitState(MachineState.idle);
          await Future<void>.delayed(Duration.zero);

          final scanningEvents = <bool>[];
          final sub = mockScanner.scanningStream.listen(scanningEvents.add);

          fakeDe1.emitState(MachineState.sleeping);
          connectionManager.markExpectingDisconnect('pref-scale');
          mockScaleController.mockEmitConnectionState(
            ConnectionState.disconnected,
          );
          await Future<void>.delayed(Duration.zero);
          await Future<void>.delayed(Duration.zero);

          expect(
            scanningEvents,
            isNot(contains(true)),
            reason: 'sleeping + ScalePowerMode.disconnect must not scan',
          );

          mockScanner.scanCompleter = Completer<void>();
          fakeDe1.emitState(MachineState.idle);
          await mockScanner.scanningStream.firstWhere((s) => s);

          mockScanner.addDevice(TestScale(deviceId: 'pref-scale'));
          await Future<void>.delayed(Duration.zero);
          await Future<void>.delayed(Duration.zero);
          mockScanner.completeScan();
          await Future<void>.delayed(Duration.zero);

          expect(mockScaleController.connectCalls, hasLength(1));
          expect(mockScaleController.connectCalls.first.deviceId, 'pref-scale');
          await sub.cancel();
        },
      );

      test(
        'sleeping during an active scale scan stops it and blocks reconnect',
        () async {
          await settingsController.setPreferredScaleId('pref-scale');
          await settingsController.setScalePowerMode(ScalePowerMode.disconnect);
          connectionManager.scaleReconnectBaseDelay = Duration.zero;

          final fakeDe1 = _FakeDe1(deviceId: 'connected-de1');
          mockScaleController.mockEmitConnectionState(
            ConnectionState.connected,
          );
          mockScaleController.debugSetLastConnectedId('pref-scale');
          mockDe1Controller.de1Subject.add(fakeDe1);
          await Future<void>.delayed(Duration.zero);
          fakeDe1.emitState(MachineState.idle);
          await Future<void>.delayed(Duration.zero);

          mockScanner.scanCompleter = Completer<void>();
          mockScaleController.mockEmitConnectionState(
            ConnectionState.disconnected,
          );
          await mockScanner.scanningStream.firstWhere((s) => s);

          fakeDe1.emitState(MachineState.sleeping);
          connectionManager.markExpectingDisconnect('pref-scale');
          mockScanner.addDevice(TestScale(deviceId: 'pref-scale'));
          await Future<void>.delayed(Duration.zero);
          await Future<void>.delayed(Duration.zero);
          mockScanner.completeScan();
          await Future<void>.delayed(Duration.zero);

          expect(mockScanner.stopScanCallCount, 1);
          expect(mockScaleController.connectCalls, isEmpty);
        },
      );

      test('unexpected scale disconnect emits scaleDisconnected', () async {
        mockScaleController.mockEmitConnectionState(ConnectionState.connected);
        mockScaleController.debugSetLastConnectedId('50:78:7D:1F:AE:E1');
        await Future<void>.delayed(Duration.zero);

        mockScaleController.mockEmitConnectionState(
          ConnectionState.disconnected,
        );
        await Future<void>.delayed(Duration.zero);

        expect(
          connectionManager.currentStatus.error?.kind,
          ConnectionErrorKind.scaleDisconnected,
        );
        expect(
          connectionManager.currentStatus.error?.deviceId,
          '50:78:7D:1F:AE:E1',
        );
      });
    });

    group('adapter state', () {
      test('adapter off emits a BLE-scoped condition', () async {
        mockScanner.mockAdapterState(AdapterState.poweredOff);
        await Future<void>.delayed(Duration.zero);

        expect(
          connectionManager.currentStatus.error?.kind,
          ConnectionErrorKind.adapterOff,
        );
        expect(
          connectionManager.currentStatus.conditions.single.transportType,
          TransportType.ble,
        );
        expect(
          connectionManager.currentStatus.conditions.single.affectedDeviceTypes,
          {DeviceType.machine, DeviceType.scale, DeviceType.grinder},
        );
      });

      test('adapter on clears the BLE-scoped condition', () async {
        mockScanner.mockAdapterState(AdapterState.poweredOff);
        await Future<void>.delayed(Duration.zero);
        expect(
          connectionManager.currentStatus.error?.kind,
          ConnectionErrorKind.adapterOff,
        );

        mockScanner.mockAdapterState(AdapterState.poweredOn);
        await Future<void>.delayed(Duration.zero);
        expect(connectionManager.currentStatus.error, isNull);
        expect(connectionManager.currentStatus.conditions, isEmpty);
      });

      test('adapter on does NOT clear an unrelated transient error', () async {
        connectionManager.debugEmitError(
          kind: ConnectionErrorKind.scaleConnectFailed,
          severity: ConnectionErrorSeverity.error,
          message: 'x',
        );
        mockScanner.mockAdapterState(AdapterState.poweredOn);
        await Future<void>.delayed(Duration.zero);
        expect(
          connectionManager.currentStatus.error?.kind,
          ConnectionErrorKind.scaleConnectFailed,
        );
      });

      test(
        'adapter recovery clears stale BLE condition without clearing replacement error',
        () async {
          mockScanner.mockAdapterState(AdapterState.poweredOff);
          await Future<void>.delayed(Duration.zero);
          expect(
            connectionManager.currentStatus.conditions.any(
              (condition) => condition.transportType == TransportType.ble,
            ),
            isTrue,
          );

          connectionManager.debugEmitError(
            kind: ConnectionErrorKind.scaleConnectFailed,
            severity: ConnectionErrorSeverity.error,
            message: 'scale failed',
          );
          mockScanner.mockAdapterState(AdapterState.poweredOn);
          await Future<void>.delayed(Duration.zero);

          expect(
            connectionManager.currentStatus.conditions.any(
              (condition) => condition.transportType == TransportType.ble,
            ),
            isFalse,
          );
          expect(
            connectionManager.currentStatus.error?.kind,
            ConnectionErrorKind.scaleConnectFailed,
          );
        },
      );
    });

    group('scan failures', () {
      test(
        'scan throwing permission error emits bluetoothPermissionDenied',
        () async {
          mockScanner.failNextScanWith = const PermissionDeniedException(
            'denied',
          );
          await connectionManager.connect(scaleOnly: true);
          expect(
            connectionManager.currentStatus.error?.kind,
            ConnectionErrorKind.bluetoothPermissionDenied,
          );
        },
      );

      test('scan throwing generic error emits scanFailed', () async {
        mockScanner.failNextScanWith = Exception('adapter busy');
        await connectionManager.connect(scaleOnly: true);
        expect(
          connectionManager.currentStatus.error?.kind,
          ConnectionErrorKind.scanFailed,
        );
      });

      test(
        'exception containing "permission" classified as permissionDenied',
        () async {
          mockScanner.failNextScanWith = Exception(
            'Missing bluetooth permission',
          );
          await connectionManager.connect(scaleOnly: true);
          expect(
            connectionManager.currentStatus.error?.kind,
            ConnectionErrorKind.bluetoothPermissionDenied,
          );
        },
      );

      test('successful scan-start clears prior scanFailed', () async {
        connectionManager.debugEmitError(
          kind: ConnectionErrorKind.scanFailed,
          severity: ConnectionErrorSeverity.error,
          message: 'prior fail',
        );
        expect(connectionManager.currentStatus.error, isNotNull);
        await connectionManager.connect(scaleOnly: true);
        expect(connectionManager.currentStatus.error, isNull);
      });
    });

    group('machine auto-reconnect', () {
      Future<void> pumpCycles([int n = 8]) async {
        for (var i = 0; i < n; i++) {
          await Future<void>.delayed(Duration.zero);
        }
      }

      test('unexpected machine disconnect starts recovery scans and '
          'reconnects the preferred machine', () async {
        connectionManager.machineReconnectBaseDelay = Duration.zero;
        await settingsController.setPreferredMachineId('pref-de1');
        final fakeDe1 = _FakeDe1(deviceId: 'pref-de1');
        mockScanner.addDevice(fakeDe1);
        mockDe1Controller.de1Subject.add(fakeDe1);
        await Future<void>.delayed(Duration.zero);

        mockDe1Controller.de1Subject.add(null);
        await pumpCycles();

        expect(
          mockDe1Controller.connectCalls.map((d) => d.deviceId),
          contains('pref-de1'),
          reason: 'recovery loop must rescan and reconnect the machine',
        );
      });

      test(
        'recovery keeps retrying until the machine reappears, then stops',
        () async {
          connectionManager.machineReconnectBaseDelay = Duration.zero;
          await settingsController.setPreferredMachineId('pref-de1');
          final fakeDe1 = _FakeDe1(deviceId: 'pref-de1');
          mockDe1Controller.de1Subject.add(fakeDe1);
          await Future<void>.delayed(Duration.zero);

          var scanStarts = 0;
          final sub = mockScanner.scanningStream.listen((s) {
            if (s) scanStarts++;
          });

          mockDe1Controller.de1Subject.add(null);
          await pumpCycles();
          expect(
            scanStarts,
            greaterThan(0),
            reason: 'loop must scan even while the machine is absent',
          );
          expect(mockDe1Controller.connectCalls, isEmpty);

          mockScanner.addDevice(fakeDe1);
          await pumpCycles();
          expect(
            mockDe1Controller.connectCalls.map((d) => d.deviceId),
            contains('pref-de1'),
          );

          final scansAfterReconnect = scanStarts;
          await pumpCycles();
          expect(
            scanStarts,
            scansAfterReconnect,
            reason: 'loop must stop once the machine is connected',
          );
          await sub.cancel();
        },
      );

      test('expected machine disconnect does not start recovery', () async {
        connectionManager.machineReconnectBaseDelay = Duration.zero;
        await settingsController.setPreferredMachineId('pref-de1');
        final fakeDe1 = _FakeDe1(deviceId: 'pref-de1');
        mockScanner.addDevice(fakeDe1);
        mockDe1Controller.de1Subject.add(fakeDe1);
        await Future<void>.delayed(Duration.zero);

        var scanStarts = 0;
        final sub = mockScanner.scanningStream.listen((s) {
          if (s) scanStarts++;
        });

        connectionManager.markExpectingDisconnect('pref-de1');
        mockDe1Controller.de1Subject.add(null);
        await pumpCycles();

        expect(
          scanStarts,
          0,
          reason: 'expected disconnects must not trigger background scans',
        );
        expect(mockDe1Controller.connectCalls, isEmpty);
        await sub.cancel();
      });

      test('deliberate disconnectMachine does not start recovery', () async {
        connectionManager.machineReconnectBaseDelay = Duration.zero;
        await settingsController.setPreferredMachineId('pref-de1');
        final fakeDe1 = _FakeDe1(deviceId: 'pref-de1');
        mockScanner.addDevice(fakeDe1);
        mockDe1Controller.de1Subject.add(fakeDe1);
        await Future<void>.delayed(Duration.zero);

        var scanStarts = 0;
        final sub = mockScanner.scanningStream.listen((s) {
          if (s) scanStarts++;
        });

        await connectionManager.disconnectMachine();
        await pumpCycles();

        expect(scanStarts, 0);
        expect(mockDe1Controller.connectCalls, isEmpty);
        await sub.cancel();
      });

      test('no preferred machine → no recovery scans', () async {
        connectionManager.machineReconnectBaseDelay = Duration.zero;
        final fakeDe1 = _FakeDe1(deviceId: 'some-de1');
        mockScanner.addDevice(fakeDe1);
        mockDe1Controller.de1Subject.add(fakeDe1);
        await Future<void>.delayed(Duration.zero);

        var scanStarts = 0;
        final sub = mockScanner.scanningStream.listen((s) {
          if (s) scanStarts++;
        });

        mockDe1Controller.de1Subject.add(null);
        await pumpCycles();

        expect(
          scanStarts,
          0,
          reason:
              'without a preferred machine a background retry could '
              'pop a picker — must stay off',
        );
        await sub.cancel();
      });

      test('recovery retries use exponential backoff', () {
        fakeAsync((async) {
          final manager = ConnectionManager(
            deviceScanner: mockScanner,
            de1Controller: mockDe1Controller,
            scaleController: mockScaleController,
            settingsController: settingsController,
          );
          settingsController.setPreferredMachineId('pref-de1');
          async.flushMicrotasks();
          mockDe1Controller.de1Subject.add(_FakeDe1(deviceId: 'pref-de1'));
          async.flushMicrotasks();

          var scanStarts = 0;
          mockScanner.scanningStream.listen((s) {
            if (s) scanStarts++;
          });

          mockDe1Controller.de1Subject.add(null);
          async.flushMicrotasks();

          async.elapse(const Duration(seconds: 4));
          expect(scanStarts, 0, reason: 'no retry before the base delay');
          async.elapse(const Duration(seconds: 2));
          expect(scanStarts, 1, reason: 'first retry fires at 5s');

          async.elapse(const Duration(seconds: 8));
          expect(scanStarts, 1, reason: 'second retry must back off to 10s');
          async.elapse(const Duration(seconds: 2));
          expect(scanStarts, 2);

          manager.dispose();
          async.flushMicrotasks();
        });
      });
    });

    group('snapshot staleness watchdog', () {
      ConnectionManager newManager() => ConnectionManager(
        deviceScanner: mockScanner,
        de1Controller: mockDe1Controller,
        scaleController: mockScaleController,
        settingsController: settingsController,
      );

      test('fires after 10s with no snapshots and forces a reconnect', () {
        fakeAsync((async) {
          final manager = newManager();
          final fakeDe1 = _FakeDe1(deviceId: 'stale-de1');
          mockDe1Controller.de1Subject.add(fakeDe1);
          async.flushMicrotasks();
          fakeDe1.emitState(MachineState.idle);
          async.flushMicrotasks();

          expect(manager.snapshotStalenessReconnects, 0);
          async.elapse(const Duration(seconds: 9));
          expect(
            manager.snapshotStalenessReconnects,
            0,
            reason: 'must not fire before the staleness timeout',
          );
          async.elapse(const Duration(seconds: 2));
          expect(
            manager.snapshotStalenessReconnects,
            1,
            reason: 'a silent push channel must trigger a forced reconnect',
          );

          manager.dispose();
          async.flushMicrotasks();
        });
      });

      test('a deduped snapshot within the window re-arms the watchdog', () {
        fakeAsync((async) {
          final manager = newManager();
          final fakeDe1 = _FakeDe1(deviceId: 'stale-de1');
          mockDe1Controller.de1Subject.add(fakeDe1);
          async.flushMicrotasks();
          fakeDe1.emitState(MachineState.idle);
          async.flushMicrotasks();

          async.elapse(const Duration(seconds: 9));
          fakeDe1.emitState(MachineState.idle);
          async.flushMicrotasks();

          async.elapse(const Duration(seconds: 9));
          expect(
            manager.snapshotStalenessReconnects,
            0,
            reason: 'a deduped frame must re-arm the watchdog',
          );

          manager.dispose();
          async.flushMicrotasks();
        });
      });

      test(
        'deliberate disconnectMachine cancels the watchdog (no fire, no error)',
        () {
          fakeAsync((async) {
            final manager = newManager();
            final fakeDe1 = _FakeDe1(deviceId: 'stale-de1');
            mockDe1Controller.de1Subject.add(fakeDe1);
            async.flushMicrotasks();
            fakeDe1.emitState(MachineState.idle);
            async.flushMicrotasks();

            manager.disconnectMachine();
            async.flushMicrotasks();

            async.elapse(const Duration(seconds: 15));
            expect(
              manager.snapshotStalenessReconnects,
              0,
              reason: 'deliberate disconnect must cancel the watchdog',
            );
            expect(
              manager.currentStatus.error,
              isNull,
              reason: 'deliberate disconnect must not surface an error banner',
            );

            manager.dispose();
            async.flushMicrotasks();
          });
        },
      );

      test(
        'initial grace: no fire before the first snapshot at 9s, fire at 11s',
        () {
          fakeAsync((async) {
            final manager = newManager();
            final fakeDe1 = _FakeDe1(deviceId: 'stale-de1');
            mockDe1Controller.de1Subject.add(fakeDe1);
            async.flushMicrotasks();

            async.elapse(const Duration(seconds: 9));
            expect(
              manager.snapshotStalenessReconnects,
              0,
              reason: 'must not fire within the initial grace window',
            );

            async.elapse(const Duration(seconds: 2));
            expect(
              manager.snapshotStalenessReconnects,
              1,
              reason:
                  'watchdog armed at watch setup must fire if no frame '
                  'ever lands',
            );

            manager.dispose();
            async.flushMicrotasks();
          });
        },
      );

      test(
        'stale generation after a forced reconnect bails (no double-reconnect)',
        () {
          fakeAsync((async) {
            final manager = newManager();
            final fakeDe1 = _FakeDe1(deviceId: 'stale-de1');
            mockDe1Controller.de1Subject.add(fakeDe1);
            async.flushMicrotasks();
            fakeDe1.emitState(MachineState.idle);
            async.flushMicrotasks();

            async.elapse(const Duration(seconds: 11));
            expect(manager.snapshotStalenessReconnects, 1);
            async.flushMicrotasks();

            async.elapse(const Duration(seconds: 30));
            expect(
              manager.snapshotStalenessReconnects,
              1,
              reason: 'a stale-generation Timer must bail, not re-fire',
            );

            manager.dispose();
            async.flushMicrotasks();
          });
        },
      );

      test('a forced reconnect that cannot recover the machine hands off to '
          'the recovery loop (no strand)', () async {
        await settingsController.setPreferredMachineId('stale-de1');
        connectionManager.machineReconnectBaseDelay = const Duration(
          milliseconds: 50,
        );
        connectionManager.snapshotStalenessTimeout = const Duration(
          milliseconds: 20,
        );
        final fakeDe1 = _FakeDe1(deviceId: 'stale-de1');
        mockDe1Controller.de1Subject.add(fakeDe1);
        await Future<void>.delayed(Duration.zero);
        fakeDe1.emitState(MachineState.idle);
        await Future<void>.delayed(Duration.zero);

        await Future<void>.delayed(const Duration(milliseconds: 60));

        expect(
          connectionManager.snapshotStalenessReconnects,
          greaterThan(0),
          reason: 'the watchdog must have forced a reconnect',
        );
        expect(
          connectionManager.machineRecoveryActive,
          isTrue,
          reason:
              'a stranded forced reconnect must hand off to the '
              'machine-recovery loop, not leave the machine disconnected',
        );
      });
    });

    group('preferred scale fallback reconnect', () {
      ConnectionManager buildFallbackManager() => ConnectionManager(
        deviceScanner: mockScanner,
        de1Controller: mockDe1Controller,
        scaleController: mockScaleController,
        settingsController: settingsController,
      )..snapshotStalenessTimeout = const Duration(hours: 1);

      List<Completer<void>> startFallbackRecovery(
        FakeAsync async,
        int expectedScans,
      ) {
        connectionManager = buildFallbackManager();
        final scanCompleters = List.generate(
          expectedScans,
          (_) => Completer<void>(),
        );
        mockScanner.queuedScanCompleters.addAll(scanCompleters);
        settingsController.setPreferredScaleId('missing-scale');
        async.flushMicrotasks();
        mockDe1Controller.de1Subject.add(_FakeDe1(deviceId: 'connected-de1'));
        async.flushMicrotasks();
        return scanCompleters;
      }

      void expectScanAfter(FakeAsync async, Duration delay, int expectedCalls) {
        async.elapse(delay - const Duration(milliseconds: 1));
        async.flushMicrotasks();
        expect(mockScanner.scanCallCount, expectedCalls - 1);
        async.elapse(const Duration(milliseconds: 1));
        async.flushMicrotasks();
        expect(mockScanner.scanCallCount, expectedCalls);
      }

      void completeScan(FakeAsync async, Completer<void> scan) {
        scan.complete();
        async.flushMicrotasks();
      }

      setUp(() async {
        await connectionManager.dispose();
      });

      test('backs off consecutive failed scans and caps at 60 seconds', () {
        fakeAsync((async) {
          final scans = startFallbackRecovery(async, 6);
          const retryDelays = [
            Duration(seconds: 5),
            Duration(seconds: 10),
            Duration(seconds: 20),
            Duration(seconds: 40),
            Duration(seconds: 60),
            Duration(seconds: 60),
          ];

          for (var index = 0; index < retryDelays.length; index++) {
            expectScanAfter(async, retryDelays[index], index + 1);
            completeScan(async, scans[index]);
          }

          connectionManager.dispose();
          async.flushMicrotasks();
        });
      });

      test('successful scale connection resets the backoff', () {
        fakeAsync((async) {
          final scans = startFallbackRecovery(async, 3);
          expectScanAfter(async, const Duration(seconds: 5), 1);
          completeScan(async, scans[0]);
          expectScanAfter(async, const Duration(seconds: 10), 2);
          completeScan(async, scans[1]);

          mockScaleController.debugSetLastConnectedId('missing-scale');
          mockScaleController.mockEmitConnectionState(
            ConnectionState.connected,
          );
          mockScaleController.mockEmitConnectionState(
            ConnectionState.disconnected,
          );
          async.flushMicrotasks();

          expectScanAfter(async, const Duration(seconds: 5), 3);
          completeScan(async, scans[2]);

          connectionManager.dispose();
          async.flushMicrotasks();
        });
      });

      test('machine disconnect cancels and resets the backoff', () {
        fakeAsync((async) {
          final scans = startFallbackRecovery(async, 2);
          expectScanAfter(async, const Duration(seconds: 5), 1);
          completeScan(async, scans[0]);

          mockDe1Controller.de1Subject.add(null);
          async.flushMicrotasks();
          async.elapse(const Duration(seconds: 10));
          expect(mockScanner.scanCallCount, 1);

          mockDe1Controller.de1Subject.add(
            _FakeDe1(deviceId: 'reconnected-de1'),
          );
          async.flushMicrotasks();
          expectScanAfter(async, const Duration(seconds: 5), 2);
          completeScan(async, scans[1]);

          connectionManager.dispose();
          async.flushMicrotasks();
        });
      });
    });

    group('background scale watch', () {
      const scaleId = 'pref-scale';

      ConnectionManager buildWatchManager() => ConnectionManager(
        deviceScanner: mockScanner,
        de1Controller: mockDe1Controller,
        scaleController: mockScaleController,
        settingsController: settingsController,
      );

      setUp(() async {
        await connectionManager.dispose();
        mockScanner.supportsWatch = true;
      });

      test('machine connect with preferred scale missing arms the watch '
          'and never runs backoff bursts', () {
        fakeAsync((async) {
          final manager = buildWatchManager();
          settingsController.setPreferredScaleId(scaleId);
          async.flushMicrotasks();
          mockDe1Controller.de1Subject.add(_FakeDe1(deviceId: 'connected-de1'));
          async.flushMicrotasks();

          expect(
            mockScanner.startWatchCallCount,
            1,
            reason: 'watch must arm on machine connect with scale missing',
          );
          expect(
            mockScanner.lastWatchFilter?.namePrefix,
            isNull,
            reason:
                'no OS name filter — remembered friendly names do not '
                'match advertised names; Dart-side matching owns this',
          );

          async.elapse(const Duration(seconds: 70));
          async.flushMicrotasks();
          expect(
            mockScanner.scanCallCount,
            0,
            reason: 'watch replaces the backoff-burst reconnect loop',
          );

          manager.dispose();
          async.flushMicrotasks();
        });
      });

      test('watch sighting connects the scale and stops the watch', () async {
        connectionManager = buildWatchManager();
        await settingsController.setPreferredScaleId(scaleId);
        mockDe1Controller.de1Subject.add(_FakeDe1(deviceId: 'connected-de1'));
        await Future<void>.delayed(Duration.zero);
        expect(mockScanner.watchActive, isTrue);

        mockScanner.addDevice(TestScale(deviceId: scaleId));
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);

        expect(
          mockScaleController.connectCalls.map((s) => s.deviceId),
          contains(scaleId),
        );
        expect(
          mockScanner.watchActive,
          isFalse,
          reason: 'watch stops once the scale is connected',
        );
        expect(connectionManager.currentStatus.phase, ConnectionPhase.ready);
        expect(
          mockScanner.scanCallCount,
          0,
          reason: 'the connect must not go through a burst scan',
        );
      });

      test(
        'scale ambiguity pauses watch and selection updates its target',
        () async {
          connectionManager = buildWatchManager();
          await settingsController.setPreferredScaleId('missing-scale');
          mockDe1Controller.de1Subject.add(_FakeDe1(deviceId: 'connected-de1'));
          await Future<void>.delayed(Duration.zero);
          expect(mockScanner.watchActive, isTrue);

          final alternative = TestScale(deviceId: 'alternative-scale');
          mockScanner.addDevice(alternative);
          await connectionManager.scanAndConnect();

          expect(
            connectionManager.currentStatus.pendingAmbiguity,
            AmbiguityReason.scalePicker,
          );
          expect(mockScanner.watchActive, isFalse);

          await connectionManager.connectScale(alternative);
          expect(settingsController.preferredScaleId, alternative.deviceId);

          final callsBeforeDisconnect = mockScaleController.connectCalls.length;
          mockScaleController.mockEmitConnectionState(
            ConnectionState.disconnected,
          );
          await Future<void>.delayed(Duration.zero);
          await Future<void>.delayed(Duration.zero);

          expect(
            mockScaleController.connectCalls.length,
            callsBeforeDisconnect + 1,
          );
          expect(
            mockScaleController.connectCalls.last.deviceId,
            alternative.deviceId,
          );
        },
      );

      test('failed watch connect re-arms the watch', () async {
        connectionManager = buildWatchManager();
        await settingsController.setPreferredScaleId(scaleId);
        mockScaleController.shouldFailConnect = true;
        mockDe1Controller.de1Subject.add(_FakeDe1(deviceId: 'connected-de1'));
        await Future<void>.delayed(Duration.zero);
        expect(mockScanner.startWatchCallCount, 1);

        mockScanner.addDevice(TestScale(deviceId: scaleId));
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);

        expect(mockScaleController.connectCalls, isNotEmpty);
        expect(
          mockScanner.startWatchCallCount,
          2,
          reason: 'a failed connect must restart the watch',
        );
        expect(mockScanner.watchActive, isTrue);
      });

      test('unexpected preferred scale disconnect arms the watch', () async {
        connectionManager = buildWatchManager();
        await settingsController.setPreferredScaleId(scaleId);
        mockScaleController.mockEmitConnectionState(ConnectionState.connected);
        mockScaleController.debugSetLastConnectedId(scaleId);
        mockDe1Controller.de1Subject.add(_FakeDe1(deviceId: 'connected-de1'));
        await Future<void>.delayed(Duration.zero);
        expect(
          mockScanner.startWatchCallCount,
          0,
          reason: 'scale is connected — nothing to watch for',
        );

        mockScaleController.mockEmitConnectionState(
          ConnectionState.disconnected,
        );
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);

        expect(mockScanner.startWatchCallCount, 1);
        expect(
          mockScanner.scanCallCount,
          0,
          reason: 'no burst scan on unexpected disconnect either',
        );
      });

      test('power-mode sleep stops the watch and wake re-arms it '
          'without a burst', () async {
        await settingsController.setScalePowerMode(ScalePowerMode.disconnect);
        connectionManager = buildWatchManager();
        await settingsController.setPreferredScaleId(scaleId);
        final fakeDe1 = _FakeDe1(deviceId: 'connected-de1');
        mockDe1Controller.de1Subject.add(fakeDe1);
        await Future<void>.delayed(Duration.zero);
        fakeDe1.emitState(MachineState.idle);
        await Future<void>.delayed(Duration.zero);
        expect(
          mockScanner.watchActive,
          isTrue,
          reason: 'machine awake + scale missing → watch armed',
        );

        fakeDe1.emitState(MachineState.sleeping);
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);
        expect(
          mockScanner.watchActive,
          isFalse,
          reason: 'sleeping + ScalePowerMode.disconnect must stop the watch',
        );

        final startsBeforeWake = mockScanner.startWatchCallCount;
        fakeDe1.emitState(MachineState.idle);
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);
        expect(
          mockScanner.startWatchCallCount,
          startsBeforeWake + 1,
          reason: 'wake must re-arm the watch',
        );
        expect(mockScanner.scanCallCount, 0);
      });

      test('machine disconnect stops the watch', () async {
        connectionManager = buildWatchManager();
        await settingsController.setPreferredScaleId(scaleId);
        mockDe1Controller.de1Subject.add(_FakeDe1(deviceId: 'connected-de1'));
        await Future<void>.delayed(Duration.zero);
        expect(mockScanner.watchActive, isTrue);

        mockDe1Controller.de1Subject.add(null);
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);

        expect(
          mockScanner.watchActive,
          isFalse,
          reason: 'no machine → nothing to reacquire a scale for',
        );
      });

      test(
        'machine quick-connect arms the watch, not the legacy backoff loop',
        () {
          fakeAsync((async) {
            mockSettingsService.setRememberedDevices(
              RememberedDevice.encodeList([
                const RememberedDevice(
                  id: 'pref-de1',
                  name: 'DE1',
                  type: DeviceType.machine,
                ),
              ]),
            );
            final remembered = RememberedDevicesController(
              machineConnections: const Stream.empty(),
              scaleConnections: const Stream.empty(),
              settings: mockSettingsService,
            );
            remembered.initialize();
            async.flushMicrotasks();

            final fakeDe1 = _FakeDe1(deviceId: 'pref-de1');
            mockScanner.quickConnectResult = fakeDe1;
            final qcDe1Controller = MockDe1Controller(
              controller: DeviceController([dummyDiscoveryService]),
            );
            final manager = ConnectionManager(
              deviceScanner: mockScanner,
              de1Controller: qcDe1Controller,
              scaleController: mockScaleController,
              settingsController: settingsController,
              rememberedDevices: remembered,
            );
            settingsController.setPreferredMachineId('pref-de1');
            settingsController.setPreferredScaleId(scaleId);
            async.flushMicrotasks();

            manager.connect();
            async.flushMicrotasks();
            expect(
              mockScanner.quickConnectCallCount,
              1,
              reason: 'the quick-connect path must be the one exercised',
            );

            qcDe1Controller.de1Subject.add(fakeDe1);
            async.flushMicrotasks();

            expect(
              mockScanner.startWatchCallCount,
              1,
              reason: 'watch must arm after a quick-connected machine',
            );
            async.elapse(const Duration(seconds: 70));
            async.flushMicrotasks();
            expect(
              mockScanner.scanCallCount,
              0,
              reason:
                  'quick-connect success must not schedule legacy '
                  'backoff bursts alongside the watch',
            );

            manager.dispose();
            remembered.dispose();
            async.flushMicrotasks();
          });
        },
      );

      test('watch start failure falls back to the legacy backoff loop', () {
        fakeAsync((async) {
          final manager = buildWatchManager();
          settingsController.setPreferredScaleId(scaleId);
          async.flushMicrotasks();
          mockScanner.failNextWatchWith = Exception('watch unavailable');
          mockDe1Controller.de1Subject.add(_FakeDe1(deviceId: 'connected-de1'));
          async.flushMicrotasks();

          expect(
            mockScanner.startWatchCallCount,
            0,
            reason: 'the start attempt threw before recording',
          );
          async.elapse(const Duration(seconds: 6));
          async.flushMicrotasks();
          expect(
            mockScanner.scanCallCount,
            1,
            reason: 'watch failure must fall back to backoff bursts',
          );

          manager.dispose();
          async.flushMicrotasks();
        });
      });

      test('a watch that dies mid-flight falls back to legacy backoff', () {
        fakeAsync((async) {
          final manager = buildWatchManager();
          settingsController.setPreferredScaleId(scaleId);
          async.flushMicrotasks();
          mockDe1Controller.de1Subject.add(_FakeDe1(deviceId: 'connected-de1'));
          async.flushMicrotasks();
          expect(mockScanner.startWatchCallCount, 1);

          mockScanner.emitWatchFailure();
          async.flushMicrotasks();

          async.elapse(const Duration(seconds: 6));
          async.flushMicrotasks();
          expect(
            mockScanner.scanCallCount,
            1,
            reason:
                'the legacy backoff loop must take over when the '
                'watch dies — scale reacquisition must never be '
                'silently off',
          );

          manager.dispose();
          async.flushMicrotasks();
        });
      });

      test('dispose stops the watch', () async {
        connectionManager = buildWatchManager();
        await settingsController.setPreferredScaleId(scaleId);
        mockDe1Controller.de1Subject.add(_FakeDe1(deviceId: 'connected-de1'));
        await Future<void>.delayed(Duration.zero);
        expect(mockScanner.watchActive, isTrue);

        await connectionManager.dispose();
        expect(mockScanner.watchActive, isFalse);
      });
    });

    group('cancelSelectionSession', () {
      test('clears pendingAmbiguity', () async {
        final scale1 = TestScale(deviceId: 's1');
        final scale2 = TestScale(deviceId: 's2');
        mockScanner.addDevice(_FakeDe1(deviceId: 'm1'));
        mockScanner.addDevice(scale1);
        mockScanner.addDevice(scale2);
        await connectionManager.connect();
        await Future<void>.delayed(Duration.zero);

        expect(
          connectionManager.currentStatus.pendingAmbiguity,
          AmbiguityReason.scalePicker,
        );

        connectionManager.cancelSelectionSession();
        await Future<void>.delayed(Duration.zero);

        expect(connectionManager.currentStatus.pendingAmbiguity, isNull);
      });

      test('emits report as cancelled exactly once', () async {
        final reports = <ScanReport>[];
        final sub = connectionManager.scanReportStream.listen(reports.add);

        mockScanner.addDevice(_FakeDe1(deviceId: 'm1'));
        mockScanner.addDevice(TestScale(deviceId: 's1'));
        mockScanner.addDevice(TestScale(deviceId: 's2'));
        await connectionManager.connect();
        await Future<void>.delayed(Duration.zero);
        expect(
          connectionManager.currentStatus.pendingAmbiguity,
          AmbiguityReason.scalePicker,
        );

        connectionManager.cancelSelectionSession();
        await Future<void>.delayed(Duration.zero);

        final cancelled = reports.where(
          (r) =>
              r.scanTerminationReason == ScanTerminationReason.cancelledByUser,
        );
        expect(cancelled.length, 1);
        await sub.cancel();
      });

      test('subsequent scaleOnly connect is no longer blocked', () async {
        mockScanner.addDevice(_FakeDe1(deviceId: 'm1'));
        mockScanner.addDevice(TestScale(deviceId: 's1'));
        mockScanner.addDevice(TestScale(deviceId: 's2'));
        await connectionManager.connect();
        await Future<void>.delayed(Duration.zero);
        expect(
          connectionManager.currentStatus.pendingAmbiguity,
          AmbiguityReason.scalePicker,
        );

        connectionManager.cancelSelectionSession();
        await Future<void>.delayed(Duration.zero);

        await connectionManager.connect(scaleOnly: true);
        await Future<void>.delayed(Duration.zero);
      });

      test('selection submitted after cancellation is ignored', () async {
        final scale = TestScale(deviceId: 's-cancelled');
        mockScanner.addDevice(_FakeDe1(deviceId: 'm1'));
        mockScanner.addDevice(scale);
        mockScanner.addDevice(TestScale(deviceId: 's-other'));
        await connectionManager.connect();
        await Future<void>.delayed(Duration.zero);
        expect(
          connectionManager.currentStatus.pendingAmbiguity,
          AmbiguityReason.scalePicker,
        );

        connectionManager.cancelSelectionSession();
        await Future<void>.delayed(Duration.zero);

        final result = await connectionManager.selectScale(scale);
        expect(result.success, isFalse);
      });
    });

    group('machine failure preserved through scale-picker', () {
      test(
        'machineConnectFailed remains visible after scale selection',
        () async {
          mockDe1Controller.shouldFailConnect = true;

          final scale1 = TestScale(deviceId: 's1');
          final scale2 = TestScale(deviceId: 's2');
          mockScanner.addDevice(_FakeDe1(deviceId: 'fail-m1'));
          mockScanner.addDevice(scale1);
          mockScanner.addDevice(scale2);

          await connectionManager.connect();
          await Future<void>.delayed(Duration.zero);

          final status = connectionManager.currentStatus;
          expect(status.pendingAmbiguity, AmbiguityReason.scalePicker);
          expect(status.error?.kind, ConnectionErrorKind.machineConnectFailed);
          expect(status.phase, ConnectionPhase.idle);

          mockDe1Controller.shouldFailConnect = false;
          final result = await connectionManager.selectScale(scale1);
          await Future<void>.delayed(Duration.zero);

          expect(result.success, isTrue);
          final after = connectionManager.currentStatus;
          expect(after.phase, ConnectionPhase.idle);
          expect(
            after.error?.kind,
            ConnectionErrorKind.machineConnectFailed,
            reason: 'machine error must remain visible after scale connects',
          );
        },
      );
    });

    group('stale caller-supplied object', () {
      test('stale machine object is not connected', () async {
        final staleMachine = _FakeDe1(deviceId: 'same-id', name: 'stale-copy');
        final sessionMachine = _FakeDe1(deviceId: 'same-id', name: 'session');

        mockScanner.addDevice(sessionMachine);
        mockScanner.addDevice(_FakeDe1(deviceId: 'm-other'));
        mockScanner.addDevice(TestScale(deviceId: 's1'));
        mockScanner.addDevice(TestScale(deviceId: 's2'));

        await connectionManager.connect();
        await Future<void>.delayed(Duration.zero);

        expect(
          connectionManager.currentStatus.pendingAmbiguity,
          AmbiguityReason.machinePicker,
        );

        await connectionManager.selectMachine(staleMachine);

        final connected = mockDe1Controller.connectCalls.lastOrNull;
        expect(
          identical(connected, staleMachine),
          isFalse,
          reason: 'stale caller-supplied object must not be connected',
        );
        expect(
          connected?.deviceId,
          'same-id',
          reason: 'resolution must find the canonical candidate by id',
        );
        expect(
          connected?.name,
          'session',
          reason: 'must be the session\'s object, not the stale copy',
        );
      });

      test('stale scale object is not connected', () async {
        final staleScale = TestScale(
          deviceId: 'same-scale-id',
          name: 'stale-scale',
        );
        final sessionScale = TestScale(
          deviceId: 'same-scale-id',
          name: 'session-scale',
        );

        mockScanner.addDevice(_FakeDe1(deviceId: 'm1'));
        mockScanner.addDevice(sessionScale);
        mockScanner.addDevice(TestScale(deviceId: 's-other'));

        await connectionManager.connect();
        await Future<void>.delayed(Duration.zero);

        expect(
          connectionManager.currentStatus.pendingAmbiguity,
          AmbiguityReason.scalePicker,
        );

        final result = await connectionManager.selectScale(staleScale);
        expect(result.success, isTrue);

        final connected = mockScaleController.connectCalls.lastOrNull;
        expect(
          identical(connected, staleScale),
          isFalse,
          reason: 'stale caller-supplied scale object must not be connected',
        );
        expect(
          connected?.deviceId,
          'same-scale-id',
          reason: 'resolution must find the canonical candidate by id',
        );
      });
    });
  });

  group('cancelActiveScan', () {
    late ConnectionManager connectionManager;
    late MockDeviceScanner mockScanner;
    late MockDe1Controller mockDe1Controller;
    late MockScaleController mockScaleController;

    setUp(() async {
      mockScanner = MockDeviceScanner();
      mockDe1Controller = MockDe1Controller(controller: DeviceController([]));
      mockScaleController = MockScaleController();
      final localSettings = SettingsController(MockSettingsService());
      await localSettings.loadSettings();
      connectionManager = ConnectionManager(
        deviceScanner: mockScanner,
        de1Controller: mockDe1Controller,
        scaleController: mockScaleController,
        settingsController: localSettings,
      );
    });

    test('stops the scanner', () {
      connectionManager.cancelActiveScan();
      expect(mockScanner.stopScanCallCount, 1);
    });

    test('clears pending ambiguity when a session is active', () async {
      mockScanner.addDevice(_FakeDe1(deviceId: 'm1'));
      mockScanner.addDevice(_FakeDe1(deviceId: 'm2'));
      mockScanner.addDevice(TestScale(deviceId: 's1'));

      await connectionManager.connect();
      await Future<void>.delayed(Duration.zero);

      expect(
        connectionManager.currentStatus.pendingAmbiguity,
        AmbiguityReason.machinePicker,
      );

      connectionManager.cancelActiveScan();

      expect(connectionManager.currentStatus.pendingAmbiguity, isNull);
      expect(connectionManager.currentStatus.phase, ConnectionPhase.idle);
    });

    test('emits exactly one cancelled report', () async {
      mockScanner.addDevice(_FakeDe1(deviceId: 'm1'));
      mockScanner.addDevice(_FakeDe1(deviceId: 'm2'));
      mockScanner.addDevice(TestScale(deviceId: 's1'));

      await connectionManager.connect();
      await Future<void>.delayed(Duration.zero);

      final reports = <ScanReport>[];
      final sub = connectionManager.scanReportStream.listen(reports.add);

      connectionManager.cancelActiveScan();

      await Future<void>.delayed(Duration.zero);
      await sub.cancel();

      expect(reports.length, 1);
      expect(
        reports.first.scanTerminationReason,
        ScanTerminationReason.cancelledByUser,
      );
    });

    test('holds scanner open → cancel → no machine connected', () async {
      final scanCompleter = Completer<void>();
      mockScanner.queuedScanCompleters.add(scanCompleter);
      mockScanner.addDevice(_FakeDe1(deviceId: 'm1'));
      mockScanner.addDevice(TestScale(deviceId: 's1'));

      final connectFuture = connectionManager.scanAndConnect();
      await Future<void>.delayed(Duration.zero);

      connectionManager.cancelActiveScan();
      expect(mockScanner.stopScanCallCount, greaterThan(0));

      scanCompleter.complete();
      await connectFuture;

      expect(mockDe1Controller.connectMachineCallCount, 0);
    });

    test('holds scanner open → cancel → no picker appears afterward', () async {
      final scanCompleter = Completer<void>();
      mockScanner.queuedScanCompleters.add(scanCompleter);
      mockScanner.addDevice(_FakeDe1(deviceId: 'm1'));
      mockScanner.addDevice(_FakeDe1(deviceId: 'm2'));
      mockScanner.addDevice(TestScale(deviceId: 's1'));

      final connectFuture = connectionManager.scanAndConnect();
      await Future<void>.delayed(Duration.zero);

      connectionManager.cancelActiveScan();
      scanCompleter.complete();
      await connectFuture;

      expect(connectionManager.currentStatus.pendingAmbiguity, isNull);
    });

    test('holds scanner open → cancel → phase is settled', () async {
      final scanCompleter = Completer<void>();
      mockScanner.queuedScanCompleters.add(scanCompleter);
      mockScanner.addDevice(_FakeDe1(deviceId: 'm1'));
      mockScanner.addDevice(TestScale(deviceId: 's1'));

      final connectFuture = connectionManager.scanAndConnect();
      await Future<void>.delayed(Duration.zero);

      connectionManager.cancelActiveScan();
      scanCompleter.complete();
      await connectFuture;

      expect(connectionManager.currentStatus.phase, ConnectionPhase.idle);
    });

    test('subsequent connect is not blocked after cancellation', () async {
      final scanCompleter = Completer<void>();
      mockScanner.queuedScanCompleters.add(scanCompleter);
      mockScanner.addDevice(_FakeDe1(deviceId: 'm1'));
      mockScanner.addDevice(TestScale(deviceId: 's1'));

      final connectFuture = connectionManager.scanAndConnect();
      await Future<void>.delayed(Duration.zero);

      connectionManager.cancelActiveScan();
      scanCompleter.complete();
      await connectFuture;

      mockScanner.addDevice(_FakeDe1(deviceId: 'm2'));
      await connectionManager.scanAndConnect();
      await Future<void>.delayed(Duration.zero);

      expect(
        connectionManager.currentStatus.pendingAmbiguity,
        AmbiguityReason.machinePicker,
      );
    });
  });

  group('explicit scan concurrency', () {
    late ConnectionManager connectionManager;
    late MockDeviceScanner mockScanner;
    late MockDe1Controller mockDe1Controller;
    late MockScaleController mockScaleController;

    setUp(() async {
      mockScanner = MockDeviceScanner();
      mockDe1Controller = MockDe1Controller(controller: DeviceController([]));
      mockScaleController = MockScaleController();
      final localSettings = SettingsController(MockSettingsService());
      await localSettings.loadSettings();
      connectionManager = ConnectionManager(
        deviceScanner: mockScanner,
        de1Controller: mockDe1Controller,
        scaleController: mockScaleController,
        settingsController: localSettings,
      );
    });

    test('explicit restart supersedes active scan', () async {
      final scan1Completer = Completer<void>();
      mockScanner.queuedScanCompleters.add(scan1Completer);
      mockScanner.addDevice(_FakeDe1(deviceId: 'm1'));
      mockScanner.addDevice(TestScale(deviceId: 's1'));

      final reports = <ScanReport>[];
      final sub = connectionManager.scanReportStream.listen(reports.add);

      final future1 = connectionManager.scanAndConnect();
      await Future<void>.delayed(Duration.zero);

      final future2 = connectionManager.scanAndConnect();
      await Future<void>.delayed(Duration.zero);

      expect(mockScanner.stopScanCallCount, greaterThan(0));

      scan1Completer.complete();
      await future1;
      await future2;

      await Future<void>.delayed(Duration.zero);
      await sub.cancel();

      final cancelled = reports.where(
        (r) => r.scanTerminationReason == ScanTerminationReason.cancelledByUser,
      );
      expect(cancelled.length, 1);

      final completed = reports.where(
        (r) => r.scanTerminationReason != ScanTerminationReason.cancelledByUser,
      );
      expect(completed.length, greaterThan(0));
    });

    test('multiple restart requests coalesce into one replacement', () async {
      final scan1Completer = Completer<void>();
      mockScanner.queuedScanCompleters.add(scan1Completer);
      mockScanner.addDevice(_FakeDe1(deviceId: 'm1'));
      mockScanner.addDevice(TestScale(deviceId: 's1'));

      connectionManager.scanAndConnect();
      await Future<void>.delayed(Duration.zero);

      final f1 = connectionManager.scanAndConnect();
      final f2 = connectionManager.scanAndConnect();
      final f3 = connectionManager.scanAndConnect();

      scan1Completer.complete();
      await Future.wait([f1, f2, f3]);
      await Future<void>.delayed(Duration.zero);
    });

    test('cancelActiveScan discards queued explicit replacement', () async {
      final scanCompleter = Completer<void>();
      mockScanner.queuedScanCompleters.add(scanCompleter);
      mockScanner.addDevice(_FakeDe1(deviceId: 'm1'));

      final reports = <ScanReport>[];
      final sub = connectionManager.scanReportStream.listen(reports.add);

      final scanFuture = connectionManager.scanAndConnect();
      await Future<void>.delayed(Duration.zero);

      final restartFuture = connectionManager.scanAndConnect();
      await Future<void>.delayed(Duration.zero);

      connectionManager.cancelActiveScan();

      scanCompleter.complete();
      await scanFuture;
      await restartFuture;
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();

      expect(mockDe1Controller.connectMachineCallCount, 0);

      expect(connectionManager.currentStatus.phase, ConnectionPhase.idle);
      expect(connectionManager.currentStatus.pendingAmbiguity, isNull);

      final cancelled = reports.where(
        (r) => r.scanTerminationReason == ScanTerminationReason.cancelledByUser,
      );
      expect(cancelled.length, 1);
    });

    test('automatic scan superseded by explicit intent', () async {
      final scanCompleter = Completer<void>();
      mockScanner.queuedScanCompleters.add(scanCompleter);
      mockScanner.addDevice(_FakeDe1(deviceId: 'm1'));
      mockScanner.addDevice(TestScale(deviceId: 's1'));

      final reports = <ScanReport>[];
      final sub = connectionManager.scanReportStream.listen(reports.add);

      final connectFuture = connectionManager.connect();
      await Future<void>.delayed(Duration.zero);

      final scanFuture = connectionManager.scanAndConnect();
      await Future<void>.delayed(Duration.zero);

      expect(mockScanner.stopScanCallCount, greaterThan(0));

      scanCompleter.complete();
      await connectFuture;
      await scanFuture;
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();

      final cancelled = reports.where(
        (r) => r.scanTerminationReason == ScanTerminationReason.cancelledByUser,
      );
      expect(cancelled.length, 1);

      final completed = reports.where(
        (r) => r.scanTerminationReason != ScanTerminationReason.cancelledByUser,
      );
      expect(completed.length, greaterThan(0));
    });

    test('queue priority: explicit arrives during scale-only drain', () async {
      mockScanner.addDevice(_FakeDe1(deviceId: 'm1'));
      mockScanner.addDevice(TestScale(deviceId: 's1'));

      final scanA = Completer<void>();
      mockScanner.queuedScanCompleters.add(scanA);
      connectionManager.connect();
      await Future<void>.delayed(Duration.zero);

      connectionManager.connect(scaleOnly: true);
      await Future<void>.delayed(Duration.zero);

      final scanB = Completer<void>();
      mockScanner.queuedScanCompleters.add(scanB);

      scanA.complete();
      await Future<void>.delayed(Duration.zero);

      final explicitFuture = connectionManager.scanAndConnect();
      await Future<void>.delayed(Duration.zero);

      expect(mockScanner.stopScanCallCount, greaterThan(0));

      scanB.complete();
      await Future<void>.delayed(Duration.zero);

      final scanC = Completer<void>();
      mockScanner.queuedScanCompleters.add(scanC);
      mockScanner.addDevice(_FakeDe1(deviceId: 'm1'));
      mockScanner.addDevice(TestScale(deviceId: 's1'));

      scanC.complete();
      await explicitFuture;
      await Future<void>.delayed(Duration.zero);

      final newFuture = connectionManager.scanAndConnect();
      final scanD = Completer<void>();
      mockScanner.queuedScanCompleters.add(scanD);
      scanD.complete();
      await newFuture;
    });
  });
}

class _SlowMockDe1Controller extends MockDe1Controller {
  Completer<void>? connectCompleter;

  _SlowMockDe1Controller({required super.controller});

  @override
  Future<void> connectToDe1(De1Interface de1Interface) async {
    connectCalls.add(de1Interface);
    if (connectCompleter != null) {
      await connectCompleter!.future;
    }
    de1Subject.add(de1Interface);
  }
}

class _SlowMockScaleController extends MockScaleController {
  Completer<void>? connectCompleter;

  _SlowMockScaleController();

  @override
  Future<void> connectToScale(scale) async {
    connectCalls.add(scale);
    if (connectCompleter != null) {
      await connectCompleter!.future;
    }
    connectionStateSubject.add(ConnectionState.connected);
  }
}
