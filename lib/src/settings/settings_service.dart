import 'package:flutter/material.dart';
import 'package:flutter_js/quickjs/ffi.dart';
import 'package:reaprime/src/services/android_updater.dart';
import 'package:reaprime/src/settings/charging_mode.dart';
import 'package:reaprime/src/settings/feature_flags.dart';
import 'package:reaprime/src/settings/gateway_mode.dart';
import 'package:reaprime/src/settings/scale_power_mode.dart';
import 'package:shared_preferences/shared_preferences.dart';

abstract class SettingsService {
  Future<ThemeMode> themeMode();
  Future<void> updateThemeMode(ThemeMode theme);
  Future<GatewayMode> gatewayMode();
  Future<void> updateGatewayMode(GatewayMode mode);
  Future<String> logLevel();
  Future<void> updateLogLevel(String newLogLevel);
  Future<Set<SimulatedDevicesTypes>> simulateDevices();
  Future<void> setSimulatedDevices(Set<SimulatedDevicesTypes> value);
  Future<double> weightFlowMultiplier();
  Future<void> setWeightFlowMultiplier(double value);
  Future<double> volumeFlowMultiplier();
  Future<void> setVolumeFlowMultiplier(double value);
  Future<double> hotWaterFlowMultiplier();
  Future<void> setHotWaterFlowMultiplier(double value);
  Future<ScalePowerMode> scalePowerMode();
  Future<void> setScalePowerMode(ScalePowerMode mode);
  Future<bool> blockOnNoScale();
  Future<void> setBlockOnNoScale(bool value);
  Future<bool> blockTareDuringShot();
  Future<void> setBlockTareDuringShot(bool value);
  Future<bool> stopHotWaterAtWeight();
  Future<void> setStopHotWaterAtWeight(bool value);
  Future<String?> preferredMachineId();
  Future<void> setPreferredMachineId(String? machineId);
  Future<String?> preferredScaleId();
  Future<void> setPreferredScaleId(String? scaleId);
  Future<String?> preferredGrinderId();
  Future<void> setPreferredGrinderId(String? grinderId);
  Future<String> defaultSkinId();
  Future<void> setDefaultSkinId(String skinId);
  Future<bool> automaticUpdateCheck();
  Future<void> setAutomaticUpdateCheck(bool value);
  Future<UpdateChannel> updateChannel();
  Future<void> setUpdateChannel(UpdateChannel channel);
  Future<DateTime?> lastUpdateCheckTime();
  Future<void> setLastUpdateCheckTime(DateTime time);
  Future<bool> telemetryConsent();
  Future<void> setTelemetryConsent(bool value);
  Future<bool> telemetryPromptShown();
  Future<void> setTelemetryPromptShown(bool value);
  Future<bool> telemetryConsentDialogShown();
  Future<void> setTelemetryConsentDialogShown(bool value);
  Future<String?> skippedVersion();
  Future<void> setSkippedVersion(String? version);
  Future<ChargingMode> chargingMode();
  Future<void> setChargingMode(ChargingMode mode);
  Future<bool> nightModeEnabled();
  Future<void> setNightModeEnabled(bool value);
  Future<int> nightModeSleepTime();
  Future<void> setNightModeSleepTime(int minutes);
  Future<int> nightModeMorningTime();
  Future<void> setNightModeMorningTime(int minutes);
  Future<bool> userPresenceEnabled();
  Future<void> setUserPresenceEnabled(bool value);
  Future<int> sleepTimeoutMinutes();
  Future<void> setSleepTimeoutMinutes(int value);
  Future<String> wakeSchedules();
  Future<void> setWakeSchedules(String json);
  Future<String> rememberedDevices();
  Future<void> setRememberedDevices(String json);
  Future<bool> lowBatteryBrightnessLimit();
  Future<void> setLowBatteryBrightnessLimit(bool value);
  Future<bool> keepAwake();
  Future<void> setKeepAwake(bool value);
  Future<bool> onboardingCompleted();
  Future<void> setOnboardingCompleted(bool value);
  Future<bool> accountStepSeen();
  Future<void> setAccountStepSeen(bool value);
  Future<bool> androidWarningDismissed();
  Future<void> setAndroidWarningDismissed(bool value);
  Future<bool> showSkinExitInstructions();
  Future<void> setShowSkinExitInstructions(bool value);
  Future<bool> enableSimulatedWebViews();
  Future<void> setEnableSimulatedWebViews(bool value);

  Future<bool?> featureFlag(FeatureFlag flag);
  Future<void> setFeatureFlag(FeatureFlag flag, bool value);
}

class SharedPreferencesSettingsService extends SettingsService {
  final prefs = SharedPreferencesAsync();

  @override
  Future<ThemeMode> themeMode() async {
    final stored =
        await prefs.getString(SettingsKeys.themeMode.name) ??
        ThemeMode.system.name;
    return ThemeMode.values.firstWhere((e) => e.name == stored);
  }

  @override
  Future<void> updateThemeMode(ThemeMode theme) async {
    await prefs.setString(SettingsKeys.themeMode.name, theme.name);
  }

  @override
  Future<GatewayMode> gatewayMode() async {
    return GatewayModeFromString.fromString(
          await prefs.getString(SettingsKeys.gatewayMode.name) ??
              GatewayMode.disabled.name,
        ) ??
        GatewayMode.disabled;
  }

  @override
  Future<void> updateGatewayMode(GatewayMode mode) async {
    await prefs.setString(SettingsKeys.gatewayMode.name, mode.name);
  }

  @override
  Future<String> logLevel() async {
    return await prefs.getString(SettingsKeys.logLevel.name) ?? "INFO";
  }

  @override
  Future<void> updateLogLevel(String newLogLevel) async {
    await prefs.setString(SettingsKeys.logLevel.name, newLogLevel);
  }

  @override
  Future<Set<SimulatedDevicesTypes>> simulateDevices() async {
    try {
      final list = await prefs.getStringList(SettingsKeys.simulateDevices.name);
      if (list == null) {
        return Set.identity();
      }
      return Set.from(
        list.map((e) => SimulatedDevicesTypesFromString.fromString(e)),
      );
    } catch (_) {
      return Set.identity();
    }
  }

  @override
  Future<void> setSimulatedDevices(Set<SimulatedDevicesTypes> value) async {
    await prefs.setStringList(
      SettingsKeys.simulateDevices.name,
      value.map((e) => e.name).toList(),
    );
  }

  @override
  Future<double> weightFlowMultiplier() async {
    return await prefs.getDouble(SettingsKeys.weightFlowMultiplier.name) ?? 1.0;
  }

  @override
  Future<void> setWeightFlowMultiplier(double value) async {
    await prefs.setDouble(SettingsKeys.weightFlowMultiplier.name, value);
  }

  @override
  Future<double> volumeFlowMultiplier() async {
    return await prefs.getDouble(SettingsKeys.volumeFlowMultiplier.name) ?? 0.3;
  }

  @override
  Future<void> setVolumeFlowMultiplier(double value) async {
    await prefs.setDouble(SettingsKeys.volumeFlowMultiplier.name, value);
  }

  @override
  Future<double> hotWaterFlowMultiplier() async {
    return await prefs.getDouble(SettingsKeys.hotWaterFlowMultiplier.name) ??
        0.3;
  }

  @override
  Future<void> setHotWaterFlowMultiplier(double value) async {
    await prefs.setDouble(SettingsKeys.hotWaterFlowMultiplier.name, value);
  }

  @override
  Future<ScalePowerMode> scalePowerMode() async {
    return ScalePowerModeFromString.fromString(
          await prefs.getString(SettingsKeys.scalePowerMode.name) ??
              ScalePowerMode.disconnect.name,
        ) ??
        ScalePowerMode.disconnect;
  }

  @override
  Future<bool> blockOnNoScale() async {
    return await prefs.getBool(SettingsKeys.blockOnNoScale.name) ?? false;
  }

  @override
  Future<void> setBlockOnNoScale(bool value) async {
    return await prefs.setBool(SettingsKeys.blockOnNoScale.name, value);
  }

  @override
  Future<bool> blockTareDuringShot() async {
    return await prefs.getBool(SettingsKeys.blockTareDuringShot.name) ?? false;
  }

  @override
  Future<void> setBlockTareDuringShot(bool value) async {
    return await prefs.setBool(SettingsKeys.blockTareDuringShot.name, value);
  }

  @override
  Future<bool> stopHotWaterAtWeight() async {
    return await prefs.getBool(SettingsKeys.stopHotWaterAtWeight.name) ?? true;
  }

  @override
  Future<void> setStopHotWaterAtWeight(bool value) async {
    return await prefs.setBool(SettingsKeys.stopHotWaterAtWeight.name, value);
  }

  @override
  Future<void> setScalePowerMode(ScalePowerMode mode) async {
    await prefs.setString(SettingsKeys.scalePowerMode.name, mode.name);
  }

  @override
  Future<String?> preferredMachineId() async {
    return await prefs.getString(SettingsKeys.preferredMachineId.name);
  }

  @override
  Future<void> setPreferredMachineId(String? machineId) async {
    if (machineId == null) {
      await prefs.remove(SettingsKeys.preferredMachineId.name);
    } else {
      await prefs.setString(SettingsKeys.preferredMachineId.name, machineId);
    }
  }

  @override
  Future<String?> preferredScaleId() async {
    return await prefs.getString(SettingsKeys.preferredScaleId.name);
  }

  @override
  Future<void> setPreferredScaleId(String? scaleId) async {
    if (scaleId == null) {
      await prefs.remove(SettingsKeys.preferredScaleId.name);
    } else {
      await prefs.setString(SettingsKeys.preferredScaleId.name, scaleId);
    }
  }

  @override
  Future<String?> preferredGrinderId() async {
    return await prefs.getString(SettingsKeys.preferredGrinderId.name);
  }

  @override
  Future<void> setPreferredGrinderId(String? grinderId) async {
    if (grinderId == null) {
      await prefs.remove(SettingsKeys.preferredGrinderId.name);
    } else {
      await prefs.setString(SettingsKeys.preferredGrinderId.name, grinderId);
    }
  }

  @override
  Future<String> defaultSkinId() async {
    final stored = await prefs.getString(SettingsKeys.defaultSkinId.name);
    if (stored == 'streamline_project-main') {
      await prefs.setString(SettingsKeys.defaultSkinId.name, 'streamline.js');
      return 'streamline.js';
    }
    return stored ?? 'streamline.js';
  }

  @override
  Future<void> setDefaultSkinId(String skinId) async {
    await prefs.setString(SettingsKeys.defaultSkinId.name, skinId);
  }

  @override
  Future<bool> automaticUpdateCheck() async {
    return await prefs.getBool(SettingsKeys.automaticUpdateCheck.name) ?? true;
  }

  @override
  Future<void> setAutomaticUpdateCheck(bool value) async {
    await prefs.setBool(SettingsKeys.automaticUpdateCheck.name, value);
  }

  @override
  Future<UpdateChannel> updateChannel() async {
    final stored = await prefs.getString(SettingsKeys.updateChannel.name);
    return UpdateChannel.values.firstWhere(
      (channel) => channel.name == stored,
      orElse: () => UpdateChannel.stable,
    );
  }

  @override
  Future<void> setUpdateChannel(UpdateChannel channel) async {
    await prefs.setString(SettingsKeys.updateChannel.name, channel.name);
  }

  @override
  Future<DateTime?> lastUpdateCheckTime() async {
    final timestamp = await prefs.getInt(SettingsKeys.lastUpdateCheckTime.name);
    return timestamp != null
        ? DateTime.fromMillisecondsSinceEpoch(timestamp)
        : null;
  }

  @override
  Future<void> setLastUpdateCheckTime(DateTime time) async {
    await prefs.setInt(
      SettingsKeys.lastUpdateCheckTime.name,
      time.millisecondsSinceEpoch,
    );
  }

  @override
  Future<bool> telemetryConsent() async {
    return await prefs.getBool(SettingsKeys.telemetryConsent.name) ?? false;
  }

  @override
  Future<void> setTelemetryConsent(bool value) async {
    await prefs.setBool(SettingsKeys.telemetryConsent.name, value);
  }

  @override
  Future<bool> telemetryPromptShown() async {
    return await prefs.getBool(SettingsKeys.telemetryPromptShown.name) ?? false;
  }

  @override
  Future<void> setTelemetryPromptShown(bool value) async {
    await prefs.setBool(SettingsKeys.telemetryPromptShown.name, value);
  }

  @override
  Future<bool> telemetryConsentDialogShown() async {
    return await prefs.getBool(SettingsKeys.telemetryConsentDialogShown.name) ??
        false;
  }

  @override
  Future<void> setTelemetryConsentDialogShown(bool value) async {
    await prefs.setBool(SettingsKeys.telemetryConsentDialogShown.name, value);
  }

  @override
  Future<String?> skippedVersion() async {
    return await prefs.getString(SettingsKeys.skippedVersion.name);
  }

  @override
  Future<void> setSkippedVersion(String? version) async {
    if (version == null) {
      await prefs.remove(SettingsKeys.skippedVersion.name);
    } else {
      await prefs.setString(SettingsKeys.skippedVersion.name, version);
    }
  }

  @override
  Future<ChargingMode> chargingMode() async {
    return ChargingModeFromString.fromString(
          await prefs.getString(SettingsKeys.chargingMode.name) ??
              ChargingMode.disabled.name,
        ) ??
        ChargingMode.disabled;
  }

  @override
  Future<void> setChargingMode(ChargingMode mode) async {
    await prefs.setString(SettingsKeys.chargingMode.name, mode.name);
  }

  @override
  Future<bool> nightModeEnabled() async {
    return await prefs.getBool(SettingsKeys.nightModeEnabled.name) ?? false;
  }

  @override
  Future<void> setNightModeEnabled(bool value) async {
    await prefs.setBool(SettingsKeys.nightModeEnabled.name, value);
  }

  @override
  Future<int> nightModeSleepTime() async {
    return await prefs.getInt(SettingsKeys.nightModeSleepTime.name) ?? 1320;
  }

  @override
  Future<void> setNightModeSleepTime(int minutes) async {
    await prefs.setInt(SettingsKeys.nightModeSleepTime.name, minutes);
  }

  @override
  Future<int> nightModeMorningTime() async {
    return await prefs.getInt(SettingsKeys.nightModeMorningTime.name) ?? 420;
  }

  @override
  Future<void> setNightModeMorningTime(int minutes) async {
    await prefs.setInt(SettingsKeys.nightModeMorningTime.name, minutes);
  }

  @override
  Future<bool> userPresenceEnabled() async {
    return await prefs.getBool(SettingsKeys.userPresenceEnabled.name) ?? true;
  }

  @override
  Future<void> setUserPresenceEnabled(bool value) async {
    await prefs.setBool(SettingsKeys.userPresenceEnabled.name, value);
  }

  @override
  Future<int> sleepTimeoutMinutes() async {
    return await prefs.getInt(SettingsKeys.sleepTimeoutMinutes.name) ?? 30;
  }

  @override
  Future<void> setSleepTimeoutMinutes(int value) async {
    await prefs.setInt(SettingsKeys.sleepTimeoutMinutes.name, value);
  }

  @override
  Future<String> wakeSchedules() async {
    return await prefs.getString(SettingsKeys.wakeSchedules.name) ?? '[]';
  }

  @override
  Future<String> rememberedDevices() async {
    return await prefs.getString(SettingsKeys.rememberedDevices.name) ?? '[]';
  }

  @override
  Future<void> setRememberedDevices(String json) async {
    await prefs.setString(SettingsKeys.rememberedDevices.name, json);
  }

  @override
  Future<void> setWakeSchedules(String json) async {
    await prefs.setString(SettingsKeys.wakeSchedules.name, json);
  }

  @override
  Future<bool> lowBatteryBrightnessLimit() async {
    return await prefs.getBool(SettingsKeys.lowBatteryBrightnessLimit.name) ??
        true;
  }

  @override
  Future<void> setLowBatteryBrightnessLimit(bool value) async {
    await prefs.setBool(SettingsKeys.lowBatteryBrightnessLimit.name, value);
  }

  @override
  Future<bool> keepAwake() async {
    return await prefs.getBool(SettingsKeys.keepAwake.name) ?? true;
  }

  @override
  Future<void> setKeepAwake(bool value) async {
    await prefs.setBool(SettingsKeys.keepAwake.name, value);
  }

  @override
  Future<bool> onboardingCompleted() async {
    return await prefs.getBool(SettingsKeys.onboardingCompleted.name) ?? false;
  }

  @override
  Future<void> setOnboardingCompleted(bool value) async {
    await prefs.setBool(SettingsKeys.onboardingCompleted.name, value);
  }

  @override
  Future<bool> accountStepSeen() async {
    return await prefs.getBool(SettingsKeys.accountStepSeen.name) ?? false;
  }

  @override
  Future<void> setAccountStepSeen(bool value) async {
    await prefs.setBool(SettingsKeys.accountStepSeen.name, value);
  }

  @override
  Future<bool> androidWarningDismissed() async {
    return await prefs.getBool(SettingsKeys.androidWarningDismissed.name) ??
        false;
  }

  @override
  Future<void> setAndroidWarningDismissed(bool value) async {
    await prefs.setBool(SettingsKeys.androidWarningDismissed.name, value);
  }

  @override
  Future<bool> showSkinExitInstructions() async {
    return await prefs.getBool(SettingsKeys.showSkinExitInstructions.name) ??
        true;
  }

  @override
  Future<void> setShowSkinExitInstructions(bool value) async {
    await prefs.setBool(SettingsKeys.showSkinExitInstructions.name, value);
  }

  @override
  Future<bool> enableSimulatedWebViews() async {
    return await prefs.getBool(SettingsKeys.enableSimulatedWebViews.name) ??
        false;
  }

  @override
  Future<void> setEnableSimulatedWebViews(bool value) async {
    await prefs.setBool(SettingsKeys.enableSimulatedWebViews.name, value);
  }

  static const _featureFlagPrefix = 'featureFlag';

  @override
  Future<bool?> featureFlag(FeatureFlag flag) async {
    return await prefs.getBool('$_featureFlagPrefix.${flag.name}');
  }

  @override
  Future<void> setFeatureFlag(FeatureFlag flag, bool value) async {
    await prefs.setBool('$_featureFlagPrefix.${flag.name}', value);
  }
}

enum SettingsKeys {
  themeMode,
  gatewayMode,
  logLevel,
  simulateDevices,
  weightFlowMultiplier,
  volumeFlowMultiplier,
  hotWaterFlowMultiplier,
  scalePowerMode,
  blockOnNoScale,
  blockTareDuringShot,
  stopHotWaterAtWeight,
  preferredMachineId,
  preferredScaleId,
  preferredGrinderId,
  defaultSkinId,
  automaticUpdateCheck,
  updateChannel,
  lastUpdateCheckTime,
  telemetryConsent,
  telemetryPromptShown,
  telemetryConsentDialogShown,
  skippedVersion,
  chargingMode,
  nightModeEnabled,
  nightModeSleepTime,
  nightModeMorningTime,
  userPresenceEnabled,
  sleepTimeoutMinutes,
  wakeSchedules,
  rememberedDevices,
  lowBatteryBrightnessLimit,
  keepAwake,
  onboardingCompleted,
  accountStepSeen,
  androidWarningDismissed,
  showSkinExitInstructions,
  enableSimulatedWebViews,
}

enum SimulatedDevicesTypes { machine, scale, sensor, bengle, replay, grinder }

extension SimulatedDevicesTypesFromString on SimulatedDevicesTypes {
  static SimulatedDevicesTypes? fromString(String value) {
    return SimulatedDevicesTypes.values.firstWhereOrNull(
      (e) => e.name == value,
    );
  }
}
