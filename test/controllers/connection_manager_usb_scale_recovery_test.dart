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

class _DiscoveryService implements DeviceDiscoveryService {
  final _devices = BehaviorSubject<List<Device>>.seeded(const []);
  List<Device> _available = const [];
  int scanCalls = 0;

  @override
  Stream<List<Device>> get devices => _devices.stream;

  void publish(List<Device> devices) {
    _available = List.unmodifiable(devices);
    _devices.add(List.of(_available));
  }

  @override
  Future<void> initialize() async {}

  @override
  Future<void> scanForDevices({ScanFilter? filter}) async {
    scanCalls++;
    _devices.add(List.of(_available));
  }

  @override
  void stopScan() {}

  @override
  Future<Device?> tryQuickConnect(RememberedDevice remembered) async => null;

  Future<void> dispose() => _devices.close();
}

class _SerialTransport extends MockSerialTransport {
  final double weight;
  Timer? _streamTimer;
  int connectCalls = 0;
  int enableCalls = 0;

  _SerialTransport(this.weight);

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
    emitRawData(weightFrame(weight));
    _streamTimer ??= Timer.periodic(const Duration(milliseconds: 20), (_) {
      emitRawData(weightFrame(weight));
    });
  }

  @override
  Future<void> disconnect() async {
    _streamTimer?.cancel();
    _streamTimer = null;
    await super.disconnect();
  }

  @override
  Future<void> dispose() async {
    _streamTimer?.cancel();
    _streamTimer = null;
    await super.dispose();
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
  final initialTransport = _SerialTransport(22.2);
  final returnedTransport = _SerialTransport(79.4);
  final alternative = _AlternativeScale();
  final machine = TestDe1();
  final scales = ScaleController();
  final settings = SettingsController(MockSettingsService());
  late final devices = DeviceController([discovery]);
  late final de1 = MockDe1Controller(controller: devices);
  late final initialScale = HDSSerial(transport: initialTransport);
  late final returnedScale = HDSSerial(transport: returnedTransport);
  late final manager = ConnectionManager(
    deviceScanner: devices,
    de1Controller: de1,
    scaleController: scales,
    settingsController: settings,
  );

  Future<void> settle() async {
    for (var index = 0; index < 3; index++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  Future<WeightSnapshot> start(ScalePowerMode mode) async {
    await devices.initialize();
    await settings.loadSettings();
    await settings.setScalePowerMode(mode);
    await settings.setPreferredMachineId(machine.deviceId);
    manager.scaleReconnectBaseDelay = const Duration(milliseconds: 20);
    manager.deferredScaleScanDelay = const Duration(milliseconds: 20);
    manager.snapshotStalenessTimeout = const Duration(minutes: 10);
    discovery.publish([machine, initialScale, alternative]);
    await settle();
    final result = await manager.connectScale(initialScale);
    expect(result.success, isTrue);
    await de1.connectToDe1(machine);
    await settle();
    return scales.weightSnapshot
        .firstWhere((snapshot) => snapshot.weight == 22.2)
        .timeout(const Duration(seconds: 3));
  }

  Future<void> sleep() async {
    machine.emitStateAndSubstate(MachineState.sleeping, MachineSubstate.idle);
    await settle();
  }

  Future<void> wake(bool throughHeating) async {
    if (throughHeating) {
      machine.emitStateAndSubstate(MachineState.heating, MachineSubstate.idle);
      await settle();
    }
    machine.emitStateAndSubstate(MachineState.idle, MachineSubstate.idle);
    await settle();
  }

  Future<void> loseUsb() async {
    discovery.publish([machine, alternative]);
    final disconnected = scales.connectionState.firstWhere(
      (state) => state == ConnectionState.disconnected,
    );
    initialTransport.emitRawError(StateError('USB stream lost'));
    await disconnected.timeout(const Duration(seconds: 3));
    await settle();
  }

  Future<void> nextScanCompletes() async {
    await devices.scanningStream
        .firstWhere((scanning) => scanning)
        .timeout(const Duration(seconds: 3));
    await devices.scanningStream
        .firstWhere((scanning) => !scanning)
        .timeout(const Duration(seconds: 3));
    await settle();
  }

  void returnUsb() {
    discovery.publish([machine, returnedScale, alternative]);
  }

  Future<void> dispose() async {
    await manager.dispose();
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
          final scansBeforeLoss = harness.discovery.scanCalls;
          final missingScan = harness.nextScanCompletes();
          await harness.loseUsb();
          if (mode == ScalePowerMode.disconnect) {
            await harness.wake(throughHeating);
          }
          await missingScan;

          expect(harness.manager.currentStatus.pendingAmbiguity, isNull);
          expect(
            harness.manager.scaleReconnectScheduled ||
                harness.manager.connectionWorkActive,
            isTrue,
          );
          expect(harness.settings.preferredScaleId, preferredId);
          expect(harness.alternative.connectCalls, 0);
          final retryStarted = harness.devices.scanningStream
              .firstWhere((scanning) => scanning)
              .timeout(const Duration(seconds: 3));
          if (mode == ScalePowerMode.displayOff) {
            await harness.wake(throughHeating);
          }
          await retryStarted;
          await harness.settle();
          expect(harness.discovery.scanCalls, greaterThan(scansBeforeLoss + 1));

          final recoveredWeight = harness.scales.weightSnapshot
              .firstWhere((snapshot) => snapshot.weight == 79.4)
              .timeout(const Duration(seconds: 3));
          harness.returnUsb();
          final recovered = await recoveredWeight;
          if (harness.devices.isScanning) {
            await harness.devices.scanningStream
                .firstWhere((scanning) => !scanning)
                .timeout(const Duration(seconds: 3));
          }
          await harness.settle();

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

      await harness.manager.scanAndConnect();

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
