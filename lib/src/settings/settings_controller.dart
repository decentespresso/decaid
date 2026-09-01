import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:logging/logging.dart';
import 'package:reaprime/src/services/android_updater.dart';
import 'package:reaprime/src/settings/charging_mode.dart';
import 'package:reaprime/src/settings/feature_flags.dart';
import 'package:reaprime/src/settings/gateway_mode.dart';
import 'package:reaprime/src/settings/scale_power_mode.dart';
import 'package:reaprime/src/settings/sleep_timeout_preference.dart';
import 'package:reaprime/src/services/telemetry/telemetry_service.dart';

import 'settings_service.dart';

class SettingsController with ChangeNotifier {
  SettingsController(this._settingsService);

  final SettingsService _settingsService;

  ThemeMode _themeMode = ThemeMode.system;

  GatewayMode _gatewayMode = GatewayMode.disabled;

  String _logLevel = 'INFO';

  Set<SimulatedDevicesTypes> _simulatedDevices = {};

  double _weightFlowMultiplier = 1.0;

  double _volumeFlowMultiplier = 0.3;

  double _hotWaterFlowMultiplier = 0.3;

  ScalePowerMode _scalePowerMode = ScalePowerMode.disconnect;

  bool _blockOnNoScale = false;

  bool _blockTareDuringShot = false;

  bool _stopHotWaterAtWeight = true;

  String? _preferredMachineId;

  String? _preferredScaleId;

  String? _preferredGrinderId;

  String _defaultSkinId = 'streamline.js';

  bool _automaticUpdateCheck = true;

  UpdateChannel _updateChannel = UpdateChannel.stable;

  bool _telemetryConsent = false;

  bool _telemetryPromptShown = false;

  bool _telemetryConsentDialogShown = false;

  ChargingMode _chargingMode = ChargingMode.disabled;
  bool _nightModeEnabled = false;
  int _nightModeSleepTime = 1320;
  int _nightModeMorningTime = 420;

  bool _userPresenceEnabled = true;
  int _sleepTimeoutMinutes = 30;
  String _wakeSchedules = '[]';
  bool _lowBatteryBrightnessLimit = true;
  bool _keepAwake = true;
  bool _onboardingCompleted = false;
  bool _accountStepSeen = false;
  bool _androidWarningDismissed = false;
  bool _showSkinExitInstructions = true;
  bool _enableSimulatedWebViews = false;

  final Map<FeatureFlag, bool> _featureFlags = {};

  TelemetryService? _telemetryService;

  ThemeMode get themeMode => _themeMode;
  GatewayMode get gatewayMode => _gatewayMode;
  String get logLevel => _logLevel;
  Set<SimulatedDevicesTypes> get simulatedDevices => _simulatedDevices;
  double get weightFlowMultiplier => _weightFlowMultiplier;
  double get volumeFlowMultiplier => _volumeFlowMultiplier;
  double get hotWaterFlowMultiplier => _hotWaterFlowMultiplier;
  ScalePowerMode get scalePowerMode => _scalePowerMode;
  bool get blockOnNoScale => _blockOnNoScale;
  bool get blockTareDuringShot => _blockTareDuringShot;
  bool get stopHotWaterAtWeight => _stopHotWaterAtWeight;
  String? get preferredMachineId => _preferredMachineId;
  String? get preferredScaleId => _preferredScaleId;
  String? get preferredGrinderId => _preferredGrinderId;
  String get defaultSkinId => _defaultSkinId;
  bool get automaticUpdateCheck => _automaticUpdateCheck;
  UpdateChannel get updateChannel => _updateChannel;
  bool get telemetryConsent => _telemetryConsent;
  bool get telemetryPromptShown => _telemetryPromptShown;
  bool get telemetryConsentDialogShown => _telemetryConsentDialogShown;
  ChargingMode get chargingMode => _chargingMode;
  bool get nightModeEnabled => _nightModeEnabled;
  int get nightModeSleepTime => _nightModeSleepTime;
  int get nightModeMorningTime => _nightModeMorningTime;
  bool get userPresenceEnabled => _userPresenceEnabled;
  int get sleepTimeoutMinutes => _sleepTimeoutMinutes;
  String get wakeSchedules => _wakeSchedules;
  bool get lowBatteryBrightnessLimit => _lowBatteryBrightnessLimit;
  bool get keepAwake => _keepAwake;
  bool get onboardingCompleted => _onboardingCompleted;
  bool get accountStepSeen => _accountStepSeen;
  bool get androidWarningDismissed => _androidWarningDismissed;
  bool get showSkinExitInstructions => _showSkinExitInstructions;
  bool get enableSimulatedWebViews => _enableSimulatedWebViews;

  bool isFeatureFlagEnabled(FeatureFlag flag) =>
      _featureFlags[flag] ?? defaultFeatureFlagValues[flag]!;

  set telemetryService(TelemetryService service) => _telemetryService = service;

  Future<void> loadSettings() async {
    _themeMode = await _settingsService.themeMode();
    _gatewayMode = await _settingsService.gatewayMode();
    _logLevel = await _settingsService.logLevel();
    _simulatedDevices = await _settingsService.simulateDevices();
    _weightFlowMultiplier = await _settingsService.weightFlowMultiplier();
    _volumeFlowMultiplier = await _settingsService.volumeFlowMultiplier();
    _hotWaterFlowMultiplier = await _settingsService.hotWaterFlowMultiplier();
    _scalePowerMode = await _settingsService.scalePowerMode();
    _blockOnNoScale = await _settingsService.blockOnNoScale();
    _blockTareDuringShot = await _settingsService.blockTareDuringShot();
    _stopHotWaterAtWeight = await _settingsService.stopHotWaterAtWeight();
    _preferredMachineId = await _settingsService.preferredMachineId();
    _preferredScaleId = await _settingsService.preferredScaleId();
    _preferredGrinderId = await _settingsService.preferredGrinderId();
    _defaultSkinId = await _settingsService.defaultSkinId();
    _automaticUpdateCheck = await _settingsService.automaticUpdateCheck();
    _updateChannel = await _settingsService.updateChannel();
    _telemetryConsent = await _settingsService.telemetryConsent();
    _telemetryPromptShown = await _settingsService.telemetryPromptShown();
    _telemetryConsentDialogShown = await _settingsService
        .telemetryConsentDialogShown();
    _chargingMode = await _settingsService.chargingMode();
    _nightModeEnabled = await _settingsService.nightModeEnabled();
    _nightModeSleepTime = await _settingsService.nightModeSleepTime();
    _nightModeMorningTime = await _settingsService.nightModeMorningTime();
    _userPresenceEnabled = await _settingsService.userPresenceEnabled();
    final rawTimeout = await _settingsService.sleepTimeoutMinutes();
    final repaired = normalizeSleepTimeoutPreferenceMinutes(rawTimeout);
    if (repaired != rawTimeout) {
      await _settingsService.setSleepTimeoutMinutes(repaired);
    }
    _sleepTimeoutMinutes = repaired;
    _wakeSchedules = await _settingsService.wakeSchedules();
    _lowBatteryBrightnessLimit = await _settingsService
        .lowBatteryBrightnessLimit();
    _keepAwake = await _settingsService.keepAwake();
    _onboardingCompleted = await _settingsService.onboardingCompleted();
    _accountStepSeen = await _settingsService.accountStepSeen();
    _androidWarningDismissed = await _settingsService.androidWarningDismissed();
    _showSkinExitInstructions = await _settingsService
        .showSkinExitInstructions();
    _enableSimulatedWebViews = await _settingsService.enableSimulatedWebViews();

    for (final flag in FeatureFlag.values) {
      final stored = await _settingsService.featureFlag(flag);
      _featureFlags[flag] = stored ?? defaultFeatureFlagValues[flag]!;
    }

    if (_telemetryService != null) {
      await _telemetryService!.setConsentEnabled(_telemetryConsent);
    }

    notifyListeners();
  }

  Future<void> updateThemeMode(ThemeMode? newThemeMode) async {
    if (newThemeMode == null) return;

    if (newThemeMode == _themeMode) return;

    _themeMode = newThemeMode;

    notifyListeners();

    await _settingsService.updateThemeMode(newThemeMode);
  }

  Future<void> updateGatewayMode(GatewayMode mode) async {
    if (mode == _gatewayMode) {
      return;
    }

    _gatewayMode = mode;

    notifyListeners();

    await _settingsService.updateGatewayMode(mode);
  }

  Future<void> updateLogLevel(String? newLogLevel) async {
    if (newLogLevel == null) {
      return;
    }
    if (newLogLevel == _logLevel) {
      return;
    }
    final loggerLevel = Level.LEVELS.firstWhereOrNull(
      (e) => e.name == newLogLevel,
    );
    if (loggerLevel == null) {
      return;
    }
    Logger.root.level = loggerLevel;

    _logLevel = newLogLevel;

    notifyListeners();

    await _settingsService.updateLogLevel(newLogLevel);
  }

  Future<void> setSimulatedDevices(Set<SimulatedDevicesTypes> value) async {
    if (const SetEquality<SimulatedDevicesTypes>().equals(
      value,
      _simulatedDevices,
    )) {
      return;
    }
    _simulatedDevices = value;
    await _settingsService.setSimulatedDevices(value);
    notifyListeners();
  }

  void enableSimulatedDevicesForSession(Set<SimulatedDevicesTypes> devices) {
    _simulatedDevices = devices;
    _preferredMachineId = devices.contains(SimulatedDevicesTypes.machine)
        ? 'MockDe1'
        : devices.contains(SimulatedDevicesTypes.replay)
        ? 'MockReplayDe1'
        : null;
    _preferredScaleId = devices.contains(SimulatedDevicesTypes.scale)
        ? 'MockScale'
        : null;
    _preferredGrinderId = devices.contains(SimulatedDevicesTypes.grinder)
        ? 'MockGrinder'
        : null;
    notifyListeners();
  }

  Future<void> setWeightFlowMultiplier(double value) async {
    if (value == _weightFlowMultiplier) {
      return;
    }
    _weightFlowMultiplier = value;
    await _settingsService.setWeightFlowMultiplier(value);
    notifyListeners();
  }

  Future<void> setVolumeFlowMultiplier(double value) async {
    if (value == _volumeFlowMultiplier) {
      return;
    }
    _volumeFlowMultiplier = value;
    await _settingsService.setVolumeFlowMultiplier(value);
    notifyListeners();
  }

  Future<void> setHotWaterFlowMultiplier(double value) async {
    if (value == _hotWaterFlowMultiplier) {
      return;
    }
    _hotWaterFlowMultiplier = value;
    await _settingsService.setHotWaterFlowMultiplier(value);
    notifyListeners();
  }

  Future<void> setScalePowerMode(ScalePowerMode mode) async {
    if (mode == _scalePowerMode) {
      return;
    }
    _scalePowerMode = mode;
    await _settingsService.setScalePowerMode(mode);
    notifyListeners();
  }

  Future<void> setBlockOnNoScale(bool value) async {
    if (value == _blockOnNoScale) {
      return;
    }
    _blockOnNoScale = value;
    await _settingsService.setBlockOnNoScale(value);
    notifyListeners();
  }

  Future<void> setStopHotWaterAtWeight(bool value) async {
    if (value == _stopHotWaterAtWeight) {
      return;
    }
    _stopHotWaterAtWeight = value;
    await _settingsService.setStopHotWaterAtWeight(value);
    notifyListeners();
  }

  Future<void> setBlockTareDuringShot(bool value) async {
    if (value == _blockTareDuringShot) {
      return;
    }
    _blockTareDuringShot = value;
    await _settingsService.setBlockTareDuringShot(value);
    notifyListeners();
  }

  Future<void> setPreferredMachineId(String? machineId) async {
    if (machineId == _preferredMachineId) {
      return;
    }
    _preferredMachineId = machineId;
    await _settingsService.setPreferredMachineId(machineId);
    notifyListeners();
  }

  Future<void> setPreferredScaleId(String? scaleId) async {
    if (scaleId == _preferredScaleId) {
      return;
    }
    _preferredScaleId = scaleId;
    await _settingsService.setPreferredScaleId(scaleId);
    notifyListeners();
  }

  Future<void> setPreferredGrinderId(String? grinderId) async {
    if (grinderId == _preferredGrinderId) {
      return;
    }
    _preferredGrinderId = grinderId;
    await _settingsService.setPreferredGrinderId(grinderId);
    notifyListeners();
  }

  Future<void> setDefaultSkinId(String skinId) async {
    if (skinId == _defaultSkinId) {
      return;
    }
    _defaultSkinId = skinId;
    await _settingsService.setDefaultSkinId(skinId);
    notifyListeners();
  }

  Future<void> setAutomaticUpdateCheck(bool value) async {
    if (value == _automaticUpdateCheck) {
      return;
    }
    _automaticUpdateCheck = value;
    await _settingsService.setAutomaticUpdateCheck(value);
    notifyListeners();
  }

  Future<void> setUpdateChannel(UpdateChannel channel) async {
    if (channel == _updateChannel) return;
    _updateChannel = channel;
    await _settingsService.setUpdateChannel(channel);
    notifyListeners();
  }

  Future<void> setTelemetryConsent(bool value) async {
    if (value == _telemetryConsent) {
      return;
    }
    _telemetryConsent = value;
    await _settingsService.setTelemetryConsent(value);
    if (_telemetryService != null) {
      await _telemetryService!.setConsentEnabled(value);
    }
    notifyListeners();
  }

  Future<void> setTelemetryPromptShown(bool value) async {
    if (value == _telemetryPromptShown) {
      return;
    }
    _telemetryPromptShown = value;
    await _settingsService.setTelemetryPromptShown(value);
    notifyListeners();
  }

  Future<void> setTelemetryConsentDialogShown(bool value) async {
    if (value == _telemetryConsentDialogShown) {
      return;
    }
    _telemetryConsentDialogShown = value;
    await _settingsService.setTelemetryConsentDialogShown(value);
    notifyListeners();
  }

  Future<void> setChargingMode(ChargingMode mode) async {
    if (mode == _chargingMode) return;
    _chargingMode = mode;
    await _settingsService.setChargingMode(mode);
    notifyListeners();
  }

  Future<void> setNightModeEnabled(bool value) async {
    if (value == _nightModeEnabled) return;
    _nightModeEnabled = value;
    await _settingsService.setNightModeEnabled(value);
    notifyListeners();
  }

  Future<void> setNightModeSleepTime(int minutes) async {
    if (minutes == _nightModeSleepTime) return;
    _nightModeSleepTime = minutes;
    await _settingsService.setNightModeSleepTime(minutes);
    notifyListeners();
  }

  Future<void> setNightModeMorningTime(int minutes) async {
    if (minutes == _nightModeMorningTime) return;
    _nightModeMorningTime = minutes;
    await _settingsService.setNightModeMorningTime(minutes);
    notifyListeners();
  }

  Future<void> setUserPresenceEnabled(bool value) async {
    if (value == _userPresenceEnabled) return;
    _userPresenceEnabled = value;
    await _settingsService.setUserPresenceEnabled(value);
    notifyListeners();
  }

  Future<void> setSleepTimeoutMinutes(int value) async {
    final normalized = normalizeSleepTimeoutPreferenceMinutes(value);
    if (normalized == _sleepTimeoutMinutes) return;
    _sleepTimeoutMinutes = normalized;
    await _settingsService.setSleepTimeoutMinutes(normalized);
    notifyListeners();
  }

  Future<void> setWakeSchedules(String json) async {
    if (json == _wakeSchedules) return;
    _wakeSchedules = json;
    await _settingsService.setWakeSchedules(json);
    notifyListeners();
  }

  Future<void> setLowBatteryBrightnessLimit(bool value) async {
    if (value == _lowBatteryBrightnessLimit) return;
    _lowBatteryBrightnessLimit = value;
    await _settingsService.setLowBatteryBrightnessLimit(value);
    notifyListeners();
  }

  Future<void> setKeepAwake(bool value) async {
    if (value == _keepAwake) return;
    _keepAwake = value;
    await _settingsService.setKeepAwake(value);
    notifyListeners();
  }

  Future<void> setOnboardingCompleted(bool value) async {
    if (value == _onboardingCompleted) return;
    _onboardingCompleted = value;
    await _settingsService.setOnboardingCompleted(value);
    notifyListeners();
  }

  Future<void> setAccountStepSeen(bool value) async {
    if (value == _accountStepSeen) return;
    _accountStepSeen = value;
    await _settingsService.setAccountStepSeen(value);
    notifyListeners();
  }

  Future<void> setAndroidWarningDismissed(bool value) async {
    if (value == _androidWarningDismissed) return;
    _androidWarningDismissed = value;
    await _settingsService.setAndroidWarningDismissed(value);
    notifyListeners();
  }

  Future<void> setShowSkinExitInstructions(bool value) async {
    if (value == _showSkinExitInstructions) return;
    _showSkinExitInstructions = value;
    await _settingsService.setShowSkinExitInstructions(value);
    notifyListeners();
  }

  Future<void> setEnableSimulatedWebViews(bool value) async {
    if (value == _enableSimulatedWebViews) return;
    _enableSimulatedWebViews = value;
    await _settingsService.setEnableSimulatedWebViews(value);
    notifyListeners();
  }

  Future<void> setFeatureFlag(FeatureFlag flag, bool value) async {
    if (value == _featureFlags[flag]) return;
    _featureFlags[flag] = value;
    await _settingsService.setFeatureFlag(flag, value);
    notifyListeners();
  }
}
