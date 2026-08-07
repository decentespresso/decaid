import 'dart:async';

import 'package:logging/logging.dart';
import 'package:reaprime/src/controllers/de1_controller.dart';
import 'package:reaprime/src/controllers/persistence_controller.dart';
import 'package:reaprime/src/controllers/sensor_controller.dart';
import 'package:reaprime/src/controllers/workflow_controller.dart';
import 'package:reaprime/src/models/data/steam_record.dart';
import 'package:reaprime/src/models/data/steam_snapshot.dart';
import 'package:reaprime/src/models/data/workflow.dart';
import 'package:reaprime/src/models/device/bengle_interface.dart';
import 'package:reaprime/src/models/device/de1_interface.dart';
import 'package:reaprime/src/models/device/impl/bengle/bengle_mmr.dart';
import 'package:reaprime/src/models/device/machine.dart';
import 'package:reaprime/src/models/device/sensor.dart';
import 'package:uuid/uuid.dart';

class SteamSequencer {
  SteamSequencer({
    required De1Controller de1Controller,
    required SensorController sensorController,
    required WorkflowController workflowController,
    required PersistenceController persistenceController,
  }) : _de1 = de1Controller,
       _sensors = sensorController,
       _workflow = workflowController,
       _persistence = persistenceController {
    _de1Sub = _de1.de1.listen(_onMachineChange);
  }

  final De1Controller _de1;
  final SensorController _sensors;
  final WorkflowController _workflow;
  final PersistenceController _persistence;
  final Logger _log = Logger('SteamSequencer');

  StreamSubscription<De1Interface?>? _de1Sub;
  StreamSubscription<MachineSnapshot>? _snapshotSub;
  StreamSubscription<Map<String, dynamic>>? _sensorSub;
  De1Interface? _machine;
  Sensor? _trackedSensor;
  double? _latestSensorTemperature;

  String? _openId;
  DateTime? _openTimestamp;
  Workflow? _openWorkflow;
  final List<SteamSnapshot> _measurements = [];
  bool _appSideStopRequested = false;

  bool get isRecording => _openId != null;

  bool useFwAutonomousStop({
    required De1Interface? machine,
    required bool probeAttached,
    required double stopAtTemperature,
  }) {
    if (machine is! BengleInterface) return false;
    if (stopAtTemperature <= 0) return false;
    if (!probeAttached) return false;
    if (BengleSteamMmr.stopAtTemperatureTarget.address == 0x00000000) {
      return false;
    }
    return true;
  }

  Future<void> _onMachineChange(De1Interface? machine) async {
    if (identical(_machine, machine)) return;
    if (_machine != null && isRecording) {
      _log.warning('Machine changed mid-steam; discarding incomplete record');
      _discard();
    }
    await _snapshotSub?.cancel();
    _snapshotSub = null;
    _machine = machine;
    if (machine != null) {
      _snapshotSub = machine.currentSnapshot.listen(_onSnapshot);
    }
  }

  void _onSnapshot(MachineSnapshot s) {
    final inSteam = s.state.state == MachineState.steam;
    final inPouring = s.state.substate == MachineSubstate.pouring;

    if (inSteam && !isRecording) {
      _openRecord();
    }

    if (isRecording) {
      _measurements.add(
        SteamSnapshot(machine: s, milkTemperature: _latestSensorTemperature),
      );
      _maybeAppSideStop(s);
    }

    if (!inSteam && !inPouring && isRecording) {
      _finalize();
    }
  }

  void _openRecord() {
    _openId = const Uuid().v4();
    _openTimestamp = DateTime.now();
    _openWorkflow = _workflow.currentWorkflow;
    _measurements.clear();
    _appSideStopRequested = false;
    _trackFirstSensor();
    _log.info('Steam record opened: $_openId');
  }

  void _trackFirstSensor() {
    _sensorSub?.cancel();
    _sensorSub = null;
    _trackedSensor = null;
    _latestSensorTemperature = null;
    final entries = _sensors.sensors.entries;
    if (entries.isEmpty) return;
    final sensor = entries.first.value;
    _trackedSensor = sensor;
    _sensorSub = sensor.data.listen((payload) {
      final raw = payload['temperature'];
      if (raw is num) _latestSensorTemperature = raw.toDouble();
    });
  }

  void _maybeAppSideStop(MachineSnapshot s) {
    if (_appSideStopRequested) return;
    final wf = _openWorkflow ?? _workflow.currentWorkflow;
    final target = wf.steamSettings.stopAtTemperature;
    if (target <= 0) return;
    final attached = _trackedSensor != null;
    if (useFwAutonomousStop(
      machine: _machine,
      probeAttached: attached,
      stopAtTemperature: target,
    )) {
      return;
    }
    final temp = _latestSensorTemperature;
    if (temp == null) return;
    if (temp < target) return;
    _appSideStopRequested = true;
    _log.info('App-side stop: probe $temp°C ≥ target $target°C');
    final machine = _machine;
    if (machine != null) {
      // ignore: discarded_futures
      machine.requestState(MachineState.idle);
    }
  }

  Future<void> _finalize() async {
    final id = _openId;
    final ts = _openTimestamp;
    final wf = _openWorkflow;
    if (id == null || ts == null || wf == null) {
      _resetOpenState();
      return;
    }
    final record = SteamRecord(
      id: id,
      timestamp: ts,
      measurements: List.unmodifiable(_measurements),
      workflow: wf,
    );
    _resetOpenState();
    _log.info(
      'Steam record finalized: ${record.id} '
      '(${record.measurements.length} frames)',
    );
    await _persistence.persistSteam(record);
  }

  void _discard() {
    _resetOpenState();
  }

  void _resetOpenState() {
    _openId = null;
    _openTimestamp = null;
    _openWorkflow = null;
    _measurements.clear();
    _appSideStopRequested = false;
    _sensorSub?.cancel();
    _sensorSub = null;
    _trackedSensor = null;
    _latestSensorTemperature = null;
  }

  Future<void> dispose() async {
    await _de1Sub?.cancel();
    _de1Sub = null;
    await _snapshotSub?.cancel();
    _snapshotSub = null;
    await _sensorSub?.cancel();
    _sensorSub = null;
  }
}
