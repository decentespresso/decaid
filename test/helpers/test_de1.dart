import 'dart:typed_data';

import 'package:reaprime/src/models/data/profile.dart';
import 'package:reaprime/src/models/device/de1_interface.dart';
import 'package:reaprime/src/models/device/firmware_update_state.dart';
import 'package:reaprime/src/models/device/de1_rawmessage.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/machine.dart';
import 'package:reaprime/src/models/device/device_implementation.dart';
import 'package:reaprime/src/models/device/transport/data_transport.dart';
import 'package:rxdart/rxdart.dart';

class TestDe1 implements De1Interface {
  final String _deviceId;
  final String _name;

  TestDe1({String deviceId = 'test-de1', String name = 'TestDe1'})
    : _deviceId = deviceId,
      _name = name;
  final BehaviorSubject<MachineSnapshot> snapshotSubject =
      BehaviorSubject.seeded(
        MachineSnapshot(
          timestamp: DateTime(2026, 1, 15, 8, 0),
          state: const MachineStateSnapshot(
            state: MachineState.idle,
            substate: MachineSubstate.idle,
          ),
          flow: 0,
          pressure: 0,
          targetFlow: 0,
          targetPressure: 0,
          mixTemperature: 90,
          groupTemperature: 90,
          targetMixTemperature: 93,
          targetGroupTemperature: 93,
          profileFrame: 0,
          steamTemperature: 0,
        ),
      );

  final BehaviorSubject<ConnectionState> _connectionState =
      BehaviorSubject.seeded(ConnectionState.connected);

  final BehaviorSubject<De1RawMessage> rawOutSubject =
      BehaviorSubject<De1RawMessage>();

  final List<De1RawMessage> sentRawMessages = [];

  void emitRawMessage(De1RawMessage message) {
    rawOutSubject.add(message);
  }

  final BehaviorSubject<De1ShotSettings> _shotSettingsSubject =
      BehaviorSubject<De1ShotSettings>();

  void emitShotSettings(De1ShotSettings settings) {
    _shotSettingsSubject.add(settings);
  }

  final BehaviorSubject<De1WaterLevels> _waterLevelsSubject =
      BehaviorSubject<De1WaterLevels>();

  void emitWaterLevels(De1WaterLevels levels) {
    _waterLevelsSubject.add(levels);
  }

  final List<MachineState> requestedStates = [];

  void emitSnapshot(MachineSnapshot snapshot) {
    snapshotSubject.add(snapshot);
  }

  void emitStateAndSubstate(MachineState state, MachineSubstate substate) {
    final current = snapshotSubject.value;
    snapshotSubject.add(
      current.copyWith(
        state: MachineStateSnapshot(state: state, substate: substate),
      ),
    );
  }

  void setConnectionState(ConnectionState state) {
    _connectionState.add(state);
  }

  @override
  Future<void> dispose() async {
    snapshotSubject.close();
    _connectionState.close();
    _shotSettingsSubject.close();
    _waterLevelsSubject.close();
    rawOutSubject.close();
    sentRawMessages.clear();
  }

  @override
  Stream<MachineSnapshot> get currentSnapshot => snapshotSubject.stream;

  @override
  MachineInfo get machineInfo => MachineInfo(
    version: '1',
    model: '1',
    serialNumber: '1',
    groupHeadControllerPresent: false,
    extra: {},
  );

  @override
  Future<void> requestState(MachineState newState) async {
    requestedStates.add(newState);
  }

  @override
  String get deviceId => _deviceId;
  @override
  String get name => _name;
  @override
  DeviceType get type => DeviceType.machine;

  @override
  DeviceImplementation get implementation => DeviceImplementation.unifiedDe1;

  @override
  TransportType get transportType => TransportType.unknown;
  @override
  Future<void> onConnect() async {}
  @override
  Future<void> disconnect() async {}
  @override
  Stream<ConnectionState> get connectionState => _connectionState.stream;

  @override
  Stream<bool> get ready => Stream.value(true);
  @override
  Stream<De1ShotSettings> get shotSettings => _shotSettingsSubject.stream;
  @override
  Future<void> updateShotSettings(De1ShotSettings newSettings) async {}
  @override
  Stream<De1WaterLevels> get waterLevels => _waterLevelsSubject.stream;
  @override
  Future<void> setRefillLevel(int newRefillLevel) async {}
  @override
  Future<void> setProfile(Profile profile) async {}
  @override
  Future<void> setFanThreshhold(int temp) async {}
  @override
  Future<int> getFanThreshhold() async => 0;
  @override
  Future<int> getTankTempThreshold() async => 0;
  @override
  Future<void> setTankTempThreshold(int temp) async {}
  @override
  Future<void> setSteamFlow(double newFlow) async {}
  @override
  Future<double> getSteamFlow() async => 0;
  @override
  Future<void> setHotWaterFlow(double newFlow) async {}
  @override
  Future<double> getHotWaterFlow() async => 0;
  @override
  Future<void> setFlushFlow(double newFlow) async {}
  @override
  Future<double> getFlushFlow() async => 0;
  @override
  Future<void> setFlushTimeout(double newTimeout) async {}
  @override
  Future<double> getFlushTimeout() async => 0;
  @override
  Future<double> getFlushTemperature() async => 0;
  @override
  Future<void> setFlushTemperature(double newTemp) async {}
  @override
  Future<double> getFlowEstimation() async => 1.0;
  @override
  double? get cachedFlowEstimation => 1.0;
  @override
  Future<void> setFlowEstimation(double multiplier) async {}
  @override
  Future<De1Calibration> readCalibration(
    De1CalibrationTarget target, {
    De1CalibrationSource source = De1CalibrationSource.current,
  }) async =>
      De1Calibration(target: target, de1ReportedValue: 1.0, measuredValue: 1.0);
  @override
  Future<void> writeCalibration(De1Calibration calibration) async {}
  @override
  Future<bool> getUsbChargerMode() async => false;
  @override
  Future<void> setUsbChargerMode(bool t) async {}
  @override
  Future<void> setSteamPurgeMode(int mode) async {}
  @override
  Future<int> getSteamPurgeMode() async => 0;
  @override
  Future<void> enableUserPresenceFeature() async {}
  @override
  Future<void> sendUserPresent() async {}
  @override
  Stream<De1RawMessage> get rawOutStream => rawOutSubject.stream;
  @override
  void sendRawMessage(De1RawMessage message) {
    sentRawMessages.add(message);
  }

  @override
  Future<double> getHeaterPhase1Flow() async => 0;
  @override
  Future<void> setHeaterPhase1Flow(double val) async {}
  @override
  Future<double> getHeaterPhase2Flow() async => 0;
  @override
  Future<void> setHeaterPhase2Flow(double val) async {}
  @override
  Future<double> getHeaterPhase2Timeout() async => 0;
  @override
  Future<void> setHeaterPhase2Timeout(double val) async {}
  @override
  Future<double> getHeaterIdleTemp() async => 0;
  @override
  Future<void> setHeaterIdleTemp(double val) async {}
  @override
  FirmwareUpdateState get firmwareUpdateState => FirmwareUpdateState.idle;
  @override
  Future<void> updateFirmware(
    Uint8List fwImage, {
    required void Function(double progress) onProgress,
  }) async {}
  @override
  Future<void> cancelFirmwareUpload() async {}
  @override
  Future<De1HeaterVoltage> getHeaterVoltage() async => .v110;
  @override
  Future<De1RefillKitSettings> getRefillKitSettings() async => .auto;
  @override
  Future<void> setHeaterVoltage(De1HeaterVoltage voltage) async {}
  @override
  Future<void> setRefillKitSettings(De1RefillKitSettings settings) async {}
}
