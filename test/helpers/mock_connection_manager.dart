import 'dart:async';

import 'package:reaprime/src/controllers/connection_error.dart';
import 'package:reaprime/src/controllers/connection_manager.dart';
import 'package:reaprime/src/models/device/de1_interface.dart';
import 'package:reaprime/src/models/device/device.dart' as dev;
import 'package:reaprime/src/models/device/machine.dart';
import 'package:reaprime/src/models/device/device_implementation.dart';
import 'package:reaprime/src/models/device/transport/data_transport.dart';
import 'package:reaprime/src/models/device/scale.dart' as device_scale;
import 'package:reaprime/src/models/scan_report.dart';
import 'package:rxdart/rxdart.dart';

class FakeDe1 implements De1Interface {
  @override
  final String deviceId;

  @override
  final String name;

  @override
  dev.DeviceType get type => dev.DeviceType.machine;

  @override
  DeviceImplementation get implementation => DeviceImplementation.unifiedDe1;

  @override
  final TransportType transportType;

  @override
  Stream<dev.ConnectionState> get connectionState =>
      Stream.value(dev.ConnectionState.connected);

  FakeDe1({
    this.deviceId = 'fake-de1',
    String? name,
    this.transportType = TransportType.unknown,
  }) : name = name ?? 'DE1-$deviceId';

  @override
  Stream<MachineSnapshot> get currentSnapshot => const Stream.empty();

  @override
  Stream<De1WaterLevels> get waterLevels => const Stream.empty();

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class MockConnectionManager extends ConnectionManager {
  final _statusOverride = BehaviorSubject<ConnectionStatus>.seeded(
    const ConnectionStatus(phase: ConnectionPhase.scanning),
  );

  int connectCallCount = 0;
  int scanAndConnectCallCount = 0;
  int selectMachineCallCount = 0;
  int selectScaleCallCount = 0;
  int cancelSelectionSessionCallCount = 0;
  int cancelActiveScanCallCount = 0;
  bool shouldFailMachineConnect = false;
  ScanReport? _lastScanReport;

  MockConnectionManager({
    required super.deviceScanner,
    required super.de1Controller,
    required super.scaleController,
    required super.settingsController,
  });

  @override
  Stream<ConnectionStatus> get status => _statusOverride.stream;

  @override
  ConnectionStatus get currentStatus => _statusOverride.value;

  @override
  ScanReport? get lastScanReport => _lastScanReport;

  void setLastScanReport(ScanReport? report) => _lastScanReport = report;

  void emitStatus(ConnectionStatus status) => _statusOverride.add(status);

  @override
  Future<void> connect({bool scaleOnly = false}) async {
    connectCallCount++;
  }

  @override
  Future<void> scanAndConnect() async {
    connectCallCount++;
    scanAndConnectCallCount++;
  }

  @override
  Future<ConnectionResult> selectMachine(De1Interface machine) async {
    selectMachineCallCount++;
    return connectMachine(machine);
  }

  @override
  Future<ConnectionResult> connectMachine(
    De1Interface machine, {
    bool automatic = false,
  }) async {
    if (shouldFailMachineConnect) {
      final error = ConnectionError(
        kind: ConnectionErrorKind.machineConnectFailed,
        severity: ConnectionErrorSeverity.error,
        timestamp: DateTime.now().toUtc(),
        message: 'Machine ${machine.name} failed to connect.',
        suggestion: 'Try again.',
      );
      final currentMachines = _statusOverride.value.foundMachines;
      final alternatives = currentMachines
          .where((m) => m.deviceId != machine.deviceId)
          .toList();
      if (alternatives.isNotEmpty) {
        _statusOverride.add(
          _statusOverride.value.copyWith(
            phase: ConnectionPhase.idle,
            pendingAmbiguity: () => AmbiguityReason.machinePicker,
            error: () => error,
          ),
        );
      } else {
        _statusOverride.add(
          _statusOverride.value.copyWith(
            phase: ConnectionPhase.idle,
            pendingAmbiguity: () => null,
            error: () => error,
          ),
        );
      }
      return const ConnectionResult.failed('connectMachine failed');
    }
    return const ConnectionResult.succeeded();
  }

  @override
  Future<ConnectionResult> connectScale(device_scale.Scale scale) async =>
      const ConnectionResult.succeeded();

  @override
  Future<ConnectionResult> selectScale(device_scale.Scale scale) async {
    selectScaleCallCount++;
    return connectScale(scale);
  }

  @override
  void cancelActiveScan() {
    cancelActiveScanCallCount++;
  }

  @override
  void cancelSelectionSession() {
    cancelSelectionSessionCallCount++;
  }

  @override
  Future<void> dispose() async {
    _statusOverride.close();
    await super.dispose();
  }
}
