import 'package:flutter/foundation.dart';
import 'package:reaprime/src/models/data/profile.dart';
import 'package:reaprime/src/models/device/firmware_update_state.dart';
import 'package:reaprime/src/models/device/machine.dart';
import 'package:reaprime/src/models/device/de1_rawmessage.dart';
import 'package:reaprime/src/models/data/utils.dart';

abstract class De1Interface extends Machine {
  /// End-of-life cleanup. Release resources held by this machine
  /// implementation. Default is a no-op.
  Future<void> dispose() async {}

  Stream<bool> get ready;

  Stream<De1RawMessage> get rawOutStream;
  void sendRawMessage(De1RawMessage message);

  Stream<De1ShotSettings> get shotSettings;
  Future<void> updateShotSettings(De1ShotSettings newSettings);

  Stream<De1WaterLevels> get waterLevels;
  Future<void> setRefillLevel(int newRefillLevel);

  Future<De1RefillKitSettings> getRefillKitSettings();
  Future<void> setRefillKitSettings(De1RefillKitSettings settings);

  Future<void> setProfile(Profile profile);

  //// Timeouts and Thresholds
  Future<void> setFanThreshhold(int temp);
  Future<int> getFanThreshhold();
  Future<int> getTankTempThreshold();
  Future<void> setTankTempThreshold(int temp);
  //// Flow Control
  Future<void> setSteamFlow(double newFlow);
  Future<double> getSteamFlow();
  Future<void> setHotWaterFlow(double newFlow);
  Future<double> getHotWaterFlow();

  Future<void> setFlushFlow(double newFlow);
  Future<double> getFlushFlow();
  Future<void> setFlushTimeout(double newTimeout);
  Future<double> getFlushTimeout();
  Future<double> getFlushTemperature();
  Future<void> setFlushTemperature(double newTemp);

  Future<double> getFlowEstimation();
  Future<void> setFlowEstimation(double multiplier);

  /// The flow-estimation calibration as last read/written this session, without
  /// a BLE round-trip. Warmed on connect and updated on [setFlowEstimation];
  /// null until first read. (The DE1 doesn't advertise to other apps while we're
  /// connected, so nothing changes it behind our back.)
  double? get cachedFlowEstimation;

  Future<De1HeaterVoltage> getHeaterVoltage();
  Future<void> setHeaterVoltage(De1HeaterVoltage voltage);

  //// USB and Charger Settings
  Future<bool> getUsbChargerMode();
  Future<void> setUsbChargerMode(bool t);

  //// Steam Purge
  Future<void> setSteamPurgeMode(int mode);
  Future<int> getSteamPurgeMode();

  //// User Presence
  Future<void> enableUserPresenceFeature();
  Future<void> sendUserPresent();

  Future<double> getHeaterPhase1Flow();
  Future<void> setHeaterPhase1Flow(double val);
  Future<double> getHeaterPhase2Flow();
  Future<void> setHeaterPhase2Flow(double val);
  Future<double> getHeaterPhase2Timeout();
  Future<void> setHeaterPhase2Timeout(double val);
  Future<double> getHeaterIdleTemp();
  Future<void> setHeaterIdleTemp(double val);

  Future<void> updateFirmware(
    Uint8List fwImage, {
    required void Function(double progress) onProgress,
  });

  /// Read-only observable state of the firmware update operation.
  /// [FirmwareUpdateState.idle] when no operation is active.
  FirmwareUpdateState get firmwareUpdateState => FirmwareUpdateState.idle;

  /// Cancel an in-progress firmware upload. Sets the machine to sleeping.
  /// No-op if no upload is in progress.
  Future<void> cancelFirmwareUpload() async {}
}

enum De1SteamSettingsValues {
  none(0),
  fastStart(0x80),
  slowStart(0x00),
  highPower(0x40),
  lowPower(0x00);

  final int hex;
  const De1SteamSettingsValues(this.hex);
}

enum De1RefillKitSettings {
  auto(2),
  forceOn(1),
  forceOff(0);

  final int hex;
  const De1RefillKitSettings(this.hex);
  factory De1RefillKitSettings.fromInt(int setting) {
    return De1RefillKitSettings.values.firstWhere((e) => e.hex == setting);
  }
}

enum De1HeaterVoltage {
  v110(120),
  v220(230),
  unset(-1);

  final int voltage;
  const De1HeaterVoltage(this.voltage);
  factory De1HeaterVoltage.fromInt(int voltage) {
    voltage = voltage > 1000 ? voltage - 1000 : voltage;
    if (voltage >= 90 && voltage <= 150) return .v110;
    if (voltage >= 180 && voltage <= 260) return .v220;
    return .unset;
  }
}

final class De1ShotSettings {
  final int steamSetting;
  final int targetSteamTemp;
  final int targetSteamDuration;
  final int targetHotWaterTemp;
  final int targetHotWaterVolume;
  final int targetHotWaterDuration;
  final int targetShotVolume;
  final double groupTemp;

  De1ShotSettings({
    required this.steamSetting,
    required this.targetSteamTemp,
    required this.targetSteamDuration,
    required this.targetHotWaterTemp,
    required this.targetHotWaterVolume,
    required this.targetHotWaterDuration,
    required this.targetShotVolume,
    required this.groupTemp,
  });

  Map<String, dynamic> toJson() {
    return {
      'steamSetting': steamSetting,
      'targetSteamTemp': targetSteamTemp,
      'targetSteamDuration': targetSteamDuration,
      'targetHotWaterTemp': targetHotWaterTemp,
      'targetHotWaterVolume': targetHotWaterVolume,
      'targetHotWaterDuration': targetHotWaterDuration,
      'targetShotVolume': targetShotVolume,
      'groupTemp': groupTemp,
    };
  }

  factory De1ShotSettings.fromJson(Map<String, dynamic> json) {
    return De1ShotSettings(
      steamSetting: parseInt(json['steamSetting']),
      targetSteamTemp: parseInt(json['targetSteamTemp']),
      targetSteamDuration: parseInt(json['targetSteamDuration']),
      targetHotWaterTemp: parseInt(json['targetHotWaterTemp']),
      targetHotWaterVolume: parseInt(json['targetHotWaterVolume']),
      targetHotWaterDuration: parseInt(json['targetHotWaterDuration']),
      targetShotVolume: parseInt(json['targetShotVolume']),
      groupTemp: parseDouble(json['groupTemp']),
    );
  }

  De1ShotSettings copyWith({
    int? steamSetting,
    int? targetSteamTemp,
    int? targetSteamDuration,
    int? targetHotWaterTemp,
    int? targetHotWaterVolume,
    int? targetHotWaterDuration,
    int? targetShotVolume,
    double? groupTemp,
  }) {
    return De1ShotSettings(
      steamSetting: steamSetting ?? this.steamSetting,
      targetSteamTemp: targetSteamTemp ?? this.targetSteamTemp,
      targetSteamDuration: targetSteamDuration ?? this.targetSteamDuration,
      targetHotWaterTemp: targetHotWaterTemp ?? this.targetHotWaterTemp,
      targetHotWaterVolume: targetHotWaterVolume ?? this.targetHotWaterVolume,
      targetHotWaterDuration:
          targetHotWaterDuration ?? this.targetHotWaterDuration,
      targetShotVolume: targetShotVolume ?? this.targetShotVolume,
      groupTemp: groupTemp ?? this.groupTemp,
    );
  }

  @override
  bool operator ==(Object other) {
    if (other is! De1ShotSettings) return false;
    return other.steamSetting == steamSetting &&
        other.targetSteamTemp == targetSteamTemp &&
        other.targetSteamDuration == targetSteamDuration &&
        other.targetHotWaterTemp == targetHotWaterTemp &&
        other.targetHotWaterVolume == targetHotWaterVolume &&
        other.targetHotWaterDuration == targetHotWaterDuration &&
        other.targetShotVolume == targetShotVolume &&
        other.groupTemp == groupTemp;
  }

  @override
  int get hashCode => Object.hash(
    steamSetting,
    targetSteamTemp,
    targetSteamDuration,
    targetHotWaterTemp,
    targetHotWaterVolume,
    targetHotWaterDuration,
    targetShotVolume,
    groupTemp,
  );
}

final class De1WaterLevels {
  final double currentLevel;
  final double refillLevel;

  De1WaterLevels({required this.currentLevel, required this.refillLevel});

  Map<String, dynamic> toJson() {
    return {'currentLevel': currentLevel, 'refillLevel': refillLevel};
  }
}
