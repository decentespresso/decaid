import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/connection_manager.dart';
import 'package:reaprime/src/controllers/device_controller.dart';
import 'package:reaprime/src/controllers/scale_controller.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/impl/decent_scale/scale_serial.dart';
import 'package:reaprime/src/models/device/machine.dart';
import 'package:reaprime/src/models/device/remembered_device.dart';
import 'package:reaprime/src/models/device/scan_filter.dart';
import 'package:reaprime/src/models/device/transport/data_transport.dart';
import 'package:reaprime/src/settings/scale_power_mode.dart';
import 'package:reaprime/src/settings/settings_controller.dart';
import 'package:rxdart/rxdart.dart';

import '../helpers/mock_de1_controller.dart';
import '../helpers/mock_settings_service.dart';
import '../helpers/test_de1.dart';
import '../helpers/test_scale.dart';
import '../unit/devices/hds_serial_disconnect_test.dart';
import '../unit/devices/hds_serial_watchdog_test.dart' show weightFrame;

class _ScanAttempt {
  final started = Completer<void>();
  final results = Completer<List<Device>>();
}

class _DiscoveryService implements DeviceDiscoveryService {
  final _devices = BehaviorSubject<List<Device>>.seeded(const []);
  final _attempts = <int, _ScanAttempt>{};
  int scanCalls = 0;

  @override
  Stream<List<Device>> get devices => _devices.stream;

  _ScanAttempt attempt(int number) =>
      _attempts.putIfAbsent(number, _ScanAttempt.new);

  void publish(List<Device> devices) {
    _devices.add(List.of(devices));
  }

  @override
  Future<void> initialize() async {}

  @override
  Future<void> scanForDevices({ScanFilter? filter}) async {
    final scan = attempt(++scanCalls);
    scan.started.complete();
    publish(await scan.results.future);
  }

  @override
  void stopScan() {}

  @override
  Future<Device?> tryQuickConnect(RememberedDevice remembered) async => null;

  void releaseScans() {
    for (final attempt in _attempts.values) {
      if (!attempt.results.isCompleted) attempt.results.complete(const []);
    }
  }

  Future<void> dispose() => _devices.close();
}

class _RecoveryManager extends ConnectionManager {
  final recoveries = <Future<void>>[];

  _RecoveryManager({
    required super.deviceScanner,
    required super.de1Controller,
    required super.scaleController,
    required super.settingsController,
  });

  @override
  Future<void> connect({bool scaleOnly = false}) {
    final recovery = super.connect(scaleOnly: scaleOnly);
    if (scaleOnly) recoveries.add(recovery);
    return recovery;
  }
}

class _Machine extends TestDe1 {
  final observed = Completer<void>();
  final _receipts = <MachineSnapshot, Completer<void>>{};

  @override
  Stream<MachineSnapshot> get currentSnapshot =>
      super.currentSnapshot.map((snapshot) {
        if (!observed.isCompleted) observed.complete();
        _receipts.remove(snapshot)?.complete();
        return snapshot;
      });

  Future<void> changeState(MachineState state) {
    final snapshot = snapshotSubject.value.copyWith(
      state: MachineStateSnapshot(state: state, substate: MachineSubstate.idle),
    );
    final receipt = Completer<void>();
    _receipts[snapshot] = receipt;
    emitSnapshot(snapshot);
    return receipt.future;
  }
}

class _SerialTransport extends MockSerialTransport {
  int connectCalls = 0;
  int enableCalls = 0;

  @override
  Future<void> connect() async {
    connectCalls++;
    await super.connect();
  }

  @override
  Future<void> writeHexCommand(Uint8List command) async {
    await super.writeHexCommand(command);
    if (!listEquals(command, const [0x03, 0x20, 0x01, 0x01])) return;
    enableCalls++;
    emitRawData(weightFrame(0));
  }
}

class _AlternativeScale extends TestScale {
  int connectCalls = 0;

  _AlternativeScale()
    : super(
        deviceId: 'ble-alternative',
        initialState: ConnectionState.discovered,
      );

  @override
  TransportType get transportType => TransportType.ble;

  @override
  Future<void> onConnect() async {
    connectCalls++;
    await super.onConnect();
  }
}

class _Harness {
  final discovery = _DiscoveryService();
  final initialTransport = _SerialTransport();
  final returnedTransport = _SerialTransport();
  final alternative = _AlternativeScale();
  final machine = _Machine();
  final scales = ScaleController();
  final settings = SettingsController(MockSettingsService());
  late final devices = DeviceController([discovery]);
  late final de1 = MockDe1Controller(controller: devices);
  late final initialScale = HDSSerial(transport: initialTransport);
  late final returnedScale = HDSSerial(transport: returnedTransport);
  late final manager = _RecoveryManager(
    deviceScanner: devices,
    de1Controller: de1,
    scaleController: scales,
    settingsController: settings,
  );

  List<Device> get withoutUsb => [machine, alternative];
  List<Device> get withReturnedUsb => [machine, returnedScale, alternative];

  Future<void> publish(List<Device> inventory) async {
    final received = devices.deviceStream.firstWhere(
      (devices) => listEquals(devices, inventory),
    );
    discovery.publish(inventory);
    await received.timeout(const Duration(seconds: 5));
  }

  Future<WeightSnapshot> measure(_SerialTransport transport, double weight) {
    final received = scales.weightSnapshot.firstWhere(
      (snapshot) => snapshot.weight == weight,
    );
    transport.emitRawData(weightFrame(weight));
    return received.timeout(const Duration(seconds: 5));
  }

  Future<WeightSnapshot> start(ScalePowerMode mode) async {
    await devices.initialize();
    await settings.loadSettings();
    await settings.setScalePowerMode(mode);
    await settings.setPreferredMachineId(machine.deviceId);
    manager.scaleReconnectBaseDelay = Duration.zero;
    manager.deferredScaleScanDelay = const Duration(hours: 1);
    manager.snapshotStalenessTimeout = const Duration(minutes: 10);
    await publish([machine, initialScale, alternative]);
    final result = await manager.connectScale(initialScale);
    expect(result.success, isTrue);
    await de1.connectToDe1(machine);
    await machine.observed.future.timeout(const Duration(seconds: 5));
    return measure(initialTransport, 22.2);
  }

  Future<void> sleep() => machine
      .changeState(MachineState.sleeping)
      .timeout(const Duration(seconds: 5));

  Future<void> wake(bool throughHeating) async {
    if (throughHeating) {
      await machine
          .changeState(MachineState.heating)
          .timeout(const Duration(seconds: 5));
    }
    await machine
        .changeState(MachineState.idle)
        .timeout(const Duration(seconds: 5));
  }

  Future<void> loseUsb() async {
    await publish(withoutUsb);
    final disconnected = scales.connectionState.firstWhere(
      (state) => state == ConnectionState.disconnected,
    );
    initialTransport.emitRawError(StateError('USB stream lost'));
    await disconnected.timeout(const Duration(seconds: 5));
  }

  Future<void> dispose() async {
    final disposed = manager.dispose();
    discovery.releaseScans();
    await disposed;
    await initialScale.disconnect();
    await returnedScale.disconnect();
    devices.dispose();
    await discovery.dispose();
    alternative.dispose();
    await machine.dispose();
    await de1.de1Subject.close();
    await initialTransport.dispose();
    await returnedTransport.dispose();
    settings.dispose();
  }
}

void main() {
  for (final mode in [ScalePowerMode.disconnect, ScalePowerMode.displayOff]) {
    for (final throughHeating in [false, true]) {
      test(
        '${mode.name} USB recovery through '
        '${throughHeating ? 'heating' : 'idle'} ignores an unrelated BLE scale',
        () async {
          final harness = _Harness();
          addTearDown(harness.dispose);
          final initialWeight = await harness.start(mode);
          final preferredId = harness.initialScale.deviceId;
          await harness.sleep();
          final missingScan = harness.discovery.attempt(1);
          final retryScan = harness.discovery.attempt(2);
          await harness.loseUsb();
          if (mode == ScalePowerMode.disconnect) {
            await harness.wake(throughHeating);
          }
          await missingScan.started.future.timeout(const Duration(seconds: 5));
          final missingRecovery = harness.manager.recoveries.single;
          missingScan.results.complete(harness.withoutUsb);
          await missingRecovery.timeout(const Duration(seconds: 5));

          expect(harness.manager.currentStatus.pendingAmbiguity, isNull);
          expect(
            harness.manager.scaleReconnectScheduled ||
                harness.manager.connectionWorkActive,
            isTrue,
          );
          expect(harness.settings.preferredScaleId, preferredId);
          expect(harness.alternative.connectCalls, 0);
          await retryScan.started.future.timeout(const Duration(seconds: 5));
          expect(harness.manager.recoveries, hasLength(2));
          final retryRecovery = harness.manager.recoveries.last;
          harness.manager.scaleReconnectBaseDelay = const Duration(hours: 1);
          if (mode == ScalePowerMode.displayOff) {
            await harness.wake(throughHeating);
          }
          retryScan.results.complete(harness.withReturnedUsb);
          await retryRecovery.timeout(const Duration(seconds: 5));
          await Future.wait(harness.manager.recoveries)
              .timeout(const Duration(seconds: 5));
          expect(harness.manager.connectionWorkActive, isFalse);
          expect(harness.discovery.scanCalls, 2);
          final recovered = await harness.measure(
            harness.returnedTransport,
            79.4,
          );

          expect(recovered.timestamp.isAfter(initialWeight.timestamp), isTrue);
          expect(
            recovered.connectionGeneration,
            greaterThan(initialWeight.connectionGeneration),
          );
          expect(harness.scales.connectedScale(), same(harness.returnedScale));
          expect(harness.settings.preferredScaleId, preferredId);
          expect(harness.manager.scaleReconnectScheduled, isFalse);
          expect(harness.manager.scaleReconnectFailures, 0);
          expect(harness.manager.currentStatus.pendingAmbiguity, isNull);
          expect(
            harness.manager.auxiliaryScaleRegistry.isReserved(preferredId),
            isFalse,
          );
          expect(harness.returnedTransport.connectCalls, 1);
          expect(harness.returnedTransport.enableCalls, 1);
          expect(harness.alternative.connectCalls, 0);
          expect(harness.de1.connectMachineCallCount, 1);
        },
      );
    }
  }

  test(
    'explicit scan still offers alternatives for a missing USB preference',
    () async {
      final harness = _Harness();
      addTearDown(harness.dispose);
      await harness.start(ScalePowerMode.displayOff);
      harness.manager.scaleReconnectBaseDelay = const Duration(hours: 1);
      await harness.loseUsb();

      final scan = harness.discovery.attempt(1);
      final completed = harness.manager.scanAndConnect();
      await scan.started.future.timeout(const Duration(seconds: 5));
      scan.results.complete(harness.withoutUsb);
      await completed.timeout(const Duration(seconds: 5));

      expect(harness.manager.connectionWorkActive, isFalse);
      expect(harness.manager.recoveries, isEmpty);
      expect(
        harness.manager.currentStatus.pendingAmbiguity,
        AmbiguityReason.scalePicker,
      );
      expect(harness.settings.preferredScaleId, harness.initialScale.deviceId);
      expect(harness.alternative.connectCalls, 0);
      expect(harness.manager.scaleReconnectScheduled, isFalse);
    },
  );
}
