import 'package:flutter/material.dart';
import 'package:reaprime/src/services/android_updater.dart';
import 'package:reaprime/src/settings/charging_mode.dart';
import 'package:reaprime/src/settings/feature_flags.dart';
import 'package:reaprime/src/settings/gateway_mode.dart';
import 'package:reaprime/src/settings/scale_power_mode.dart';
import 'package:reaprime/src/settings/settings_service.dart';

class MockSettingsService extends SettingsService {
  ThemeMode _themeMode = ThemeMode.system;
  GatewayMode _gatewayMode = GatewayMode.disabled;
  String _logLevel = 'INFO';
  Set<SimulatedDevicesTypes> _simulateDevices = {};
  double _weightFlowMultiplier = 1.0;
  double _volumeFlowMultiplier = 0.3;
  double _hotWaterFlowMultiplier = 0.3;
  ScalePowerMode _scalePowerMode = ScalePowerMode.disabled;
  bool _blockOnNoScale = false;
  bool _blockTareDuringShot = false;
  bool _stopHotWaterAtWeight = true;
  String? _preferredMachineId;
  String? _preferredScaleId;
  String _defaultSkinId = 'streamline.js';
  bool _automaticUpdateCheck = true;
  UpdateChannel _updateChannel = UpdateChannel.stable;
  DateTime? _lastUpdateCheckTime;
  bool _telemetryConsent = false;
  bool _telemetryPromptShown = true;
  bool _telemetryConsentDialogShown = true;
  String? _skippedVersion;
  ChargingMode _chargingMode = ChargingMode.disabled;
  bool _nightModeEnabled = false;
  int _nightModeSleepTime = 1320;
  int _nightModeMorningTime = 420;
  bool _userPresenceEnabled = true;
  int _sleepTimeoutMinutes = 30;
  String _wakeSchedules = '[]';
  String _rememberedDevices = '[]';
  bool _lowBatteryBrightnessLimit = false;
  bool _keepAwake = true;
  bool _onboardingCompleted = true;
  bool _accountStepSeen = true;
  bool _androidWarningDismissed = true;
  bool _showSkinExitInstructions = false;
  bool _enableSimulatedWebViews = false;

  final Map<String, bool> _featureFlags = {};

  @override
  Future<ThemeMode> themeMode() async => _themeMode;
  @override
  Future<void> updateThemeMode(ThemeMode theme) async => _themeMode = theme;
  @override
  Future<GatewayMode> gatewayMode() async => _gatewayMode;
  @override
  Future<void> updateGatewayMode(GatewayMode mode) async => _gatewayMode = mode;
  @override
  Future<String> logLevel() async => _logLevel;
  @override
  Future<void> updateLogLevel(String newLogLevel) async =>
      _logLevel = newLogLevel;
  @override
  Future<Set<SimulatedDevicesTypes>> simulateDevices() async =>
      _simulateDevices;
  @override
  Future<void> setSimulatedDevices(Set<SimulatedDevicesTypes> value) async =>
      _simulateDevices = value;
  @override
  Future<double> weightFlowMultiplier() async => _weightFlowMultiplier;
  @override
  Future<void> setWeightFlowMultiplier(double value) async =>
      _weightFlowMultiplier = value;
  @override
  Future<double> volumeFlowMultiplier() async => _volumeFlowMultiplier;
  @override
  Future<void> setVolumeFlowMultiplier(double value) async =>
      _volumeFlowMultiplier = value;
  @override
  Future<double> hotWaterFlowMultiplier() async => _hotWaterFlowMultiplier;
  @override
  Future<void> setHotWaterFlowMultiplier(double value) async =>
      _hotWaterFlowMultiplier = value;
  @override
  Future<ScalePowerMode> scalePowerMode() async => _scalePowerMode;
  @override
  Future<void> setScalePowerMode(ScalePowerMode mode) async =>
      _scalePowerMode = mode;
  @override
  Future<bool> blockOnNoScale() async => _blockOnNoScale;
  @override
  Future<void> setBlockOnNoScale(bool value) async => _blockOnNoScale = value;
  @override
  Future<bool> blockTareDuringShot() async => _blockTareDuringShot;
  @override
  Future<void> setBlockTareDuringShot(bool value) async =>
      _blockTareDuringShot = value;
  @override
  Future<bool> stopHotWaterAtWeight() async => _stopHotWaterAtWeight;
  @override
  Future<void> setStopHotWaterAtWeight(bool value) async =>
      _stopHotWaterAtWeight = value;
  final List<String?> preferredMachineIdWrites = [];
  bool failSetPreferredMachineId = false;

  @override
  Future<String?> preferredMachineId() async => _preferredMachineId;
  @override
  Future<void> setPreferredMachineId(String? machineId) async {
    preferredMachineIdWrites.add(machineId);
    if (failSetPreferredMachineId) {
      throw Exception('simulated preference persist failure');
    }
    _preferredMachineId = machineId;
  }

  @override
  Future<String?> preferredScaleId() async => _preferredScaleId;
  @override
  Future<void> setPreferredScaleId(String? scaleId) async =>
      _preferredScaleId = scaleId;
  @override
  Future<String> defaultSkinId() async => _defaultSkinId;
  @override
  Future<void> setDefaultSkinId(String skinId) async => _defaultSkinId = skinId;
  @override
  Future<bool> automaticUpdateCheck() async => _automaticUpdateCheck;
  @override
  Future<void> setAutomaticUpdateCheck(bool value) async =>
      _automaticUpdateCheck = value;
  @override
  Future<UpdateChannel> updateChannel() async => _updateChannel;
  @override
  Future<void> setUpdateChannel(UpdateChannel channel) async =>
      _updateChannel = channel;
  @override
  Future<DateTime?> lastUpdateCheckTime() async => _lastUpdateCheckTime;
  @override
  Future<void> setLastUpdateCheckTime(DateTime time) async =>
      _lastUpdateCheckTime = time;
  @override
  Future<bool> telemetryConsent() async => _telemetryConsent;
  @override
  Future<void> setTelemetryConsent(bool value) async =>
      _telemetryConsent = value;
  @override
  Future<bool> telemetryPromptShown() async => _telemetryPromptShown;
  @override
  Future<void> setTelemetryPromptShown(bool value) async =>
      _telemetryPromptShown = value;
  @override
  Future<bool> telemetryConsentDialogShown() async =>
      _telemetryConsentDialogShown;
  @override
  Future<void> setTelemetryConsentDialogShown(bool value) async =>
      _telemetryConsentDialogShown = value;
  @override
  Future<String?> skippedVersion() async => _skippedVersion;
  @override
  Future<void> setSkippedVersion(String? version) async =>
      _skippedVersion = version;
  @override
  Future<ChargingMode> chargingMode() async => _chargingMode;
  @override
  Future<void> setChargingMode(ChargingMode mode) async => _chargingMode = mode;
  @override
  Future<bool> nightModeEnabled() async => _nightModeEnabled;
  @override
  Future<void> setNightModeEnabled(bool value) async =>
      _nightModeEnabled = value;
  @override
  Future<int> nightModeSleepTime() async => _nightModeSleepTime;
  @override
  Future<void> setNightModeSleepTime(int minutes) async =>
      _nightModeSleepTime = minutes;
  @override
  Future<int> nightModeMorningTime() async => _nightModeMorningTime;
  @override
  Future<void> setNightModeMorningTime(int minutes) async =>
      _nightModeMorningTime = minutes;
  @override
  Future<bool> userPresenceEnabled() async => _userPresenceEnabled;
  @override
  Future<void> setUserPresenceEnabled(bool value) async =>
      _userPresenceEnabled = value;
  int sleepTimeoutWriteCount = 0;

  void setRawSleepTimeoutMinutes(int value) => _sleepTimeoutMinutes = value;

  @override
  Future<int> sleepTimeoutMinutes() async => _sleepTimeoutMinutes;
  @override
  Future<void> setSleepTimeoutMinutes(int value) async {
    sleepTimeoutWriteCount++;
    _sleepTimeoutMinutes = value;
  }

  @override
  Future<String> wakeSchedules() async => _wakeSchedules;
  @override
  Future<void> setWakeSchedules(String json) async => _wakeSchedules = json;

  int rememberedDevicesWriteCount = 0;

  bool failRememberedDevicesWrite = false;
  @override
  Future<String> rememberedDevices() async => _rememberedDevices;
  @override
  Future<void> setRememberedDevices(String json) async {
    rememberedDevicesWriteCount++;
    if (failRememberedDevicesWrite) {
      throw StateError('simulated persist failure');
    }
    _rememberedDevices = json;
  }

  @override
  Future<bool> lowBatteryBrightnessLimit() async => _lowBatteryBrightnessLimit;
  @override
  Future<void> setLowBatteryBrightnessLimit(bool value) async =>
      _lowBatteryBrightnessLimit = value;
  @override
  Future<bool> keepAwake() async => _keepAwake;
  @override
  Future<void> setKeepAwake(bool value) async => _keepAwake = value;
  @override
  Future<bool> onboardingCompleted() async => _onboardingCompleted;
  @override
  Future<void> setOnboardingCompleted(bool value) async =>
      _onboardingCompleted = value;
  @override
  Future<bool> accountStepSeen() async => _accountStepSeen;
  @override
  Future<void> setAccountStepSeen(bool value) async => _accountStepSeen = value;
  @override
  Future<bool> androidWarningDismissed() async => _androidWarningDismissed;
  @override
  Future<void> setAndroidWarningDismissed(bool value) async =>
      _androidWarningDismissed = value;
  @override
  Future<bool> showSkinExitInstructions() async => _showSkinExitInstructions;
  @override
  Future<void> setShowSkinExitInstructions(bool value) async =>
      _showSkinExitInstructions = value;
  @override
  Future<bool> enableSimulatedWebViews() async => _enableSimulatedWebViews;
  @override
  Future<void> setEnableSimulatedWebViews(bool value) async =>
      _enableSimulatedWebViews = value;

  @override
  Future<bool?> featureFlag(FeatureFlag flag) async => _featureFlags[flag.name];
  @override
  Future<void> setFeatureFlag(FeatureFlag flag, bool value) async =>
      _featureFlags[flag.name] = value;
}
