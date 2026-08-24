import 'package:flutter/foundation.dart';
import 'package:reaprime/src/models/data/profile.dart';
import 'package:reaprime/src/models/device/firmware_update_state.dart';
import 'package:reaprime/src/models/device/machine.dart';
import 'package:reaprime/src/models/device/de1_rawmessage.dart';
import 'package:reaprime/src/models/data/utils.dart';

abstract class De1Interface extends Machine {
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

  Future<void> setFanThreshhold(int temp);
  Future<int> getFanThreshhold();
  Future<int> getTankTempThreshold();
  Future<void> setTankTempThreshold(int temp);
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

  double? get cachedFlowEstimation;

  Future<De1Calibration> readCalibration(
    De1CalibrationTarget target, {
    De1CalibrationSource source = De1CalibrationSource.current,
  });
  Future<void> writeCalibration(De1Calibration calibration);

  Future<De1HeaterVoltage> getHeaterVoltage();
  Future<void> setHeaterVoltage(De1HeaterVoltage voltage);

  Future<bool> getUsbChargerMode();
  Future<void> setUsbChargerMode(bool t);

  Future<void> setSteamPurgeMode(int mode);
  Future<int> getSteamPurgeMode();

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

  FirmwareUpdateState get firmwareUpdateState => FirmwareUpdateState.idle;

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

enum De1CalibrationTarget {
  flow(0),
  pressure(1),
  temperature(2);

  final int wireValue;
  const De1CalibrationTarget(this.wireValue);

  static De1CalibrationTarget? fromWireValue(int value) => De1CalibrationTarget
      .values
      .where((target) => target.wireValue == value)
      .firstOrNull;
}

enum De1CalibrationSource { current, factory }

final class De1Calibration {
  static const fixedPointScale = 65536.0;
  static const minValue = -32768.0;
  static const maxValueExclusive = 32768.0;

  final De1CalibrationTarget target;
  final double de1ReportedValue;
  final double measuredValue;

  const De1Calibration({
    required this.target,
    required this.de1ReportedValue,
    required this.measuredValue,
  });

  void validateForWrite() {
    _validateValue(de1ReportedValue, 'de1ReportedValue');
    _validateValue(measuredValue, 'measuredValue');
    if (target != De1CalibrationTarget.temperature &&
        (de1ReportedValue * fixedPointScale).round() == 0) {
      throw ArgumentError.value(
        de1ReportedValue,
        'de1ReportedValue',
        'must not encode as zero for flow or pressure',
      );
    }
  }

  static void _validateValue(double value, String name) {
    if (!value.isFinite) {
      throw ArgumentError.value(value, name, 'must be finite');
    }
    if (value < minValue || value >= maxValueExclusive) {
      throw ArgumentError.value(
        value,
        name,
        'outside the signed Q16.16 range -32768..32767.9999',
      );
    }
  }

  @override
  bool operator ==(Object other) =>
      other is De1Calibration &&
      other.target == target &&
      other.de1ReportedValue == de1ReportedValue &&
      other.measuredValue == measuredValue;

  @override
  int get hashCode => Object.hash(target, de1ReportedValue, measuredValue);
}
