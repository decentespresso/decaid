import 'package:reaprime/src/models/device/de1_interface.dart';
import 'package:reaprime/src/models/device/cup_warmer.dart';
import 'package:reaprime/src/models/firmware_wake_window.dart';
import 'package:reaprime/src/models/device/led_strip.dart';
import 'package:reaprime/src/models/device/scale.dart';
import 'package:reaprime/src/models/device/scale_calibration.dart';

abstract class BengleInterface extends De1Interface {
  /// True when the connected firmware implements the post-0x00803880 MMR
  /// surface (scale calibration, LED palette, cup-warmer mode/temperature,
  /// preheat, wake schedule). Detected once per connection; old firmware
  /// reports false and all surface endpoints answer "not supported".
  bool get bengleFeatureSurfaceSupported;

  Future<ScaleCalibrationState> getScaleCalibrationState();

  Future<bool> startScaleCalibration(
    ScaleCalibrationCommand command, {
    double? weightGrams,
  });

  Future<void> setCupWarmerTemperature(double celsius);

  Future<double> getCupWarmerTemperature();

  /// Manual cup-warmer enable (CupWarmerMode). RAM-only in firmware: boots
  /// off after every power cycle and is never re-enabled by the app on
  /// reconnect.
  Future<void> setCupWarmerEnabled(bool enabled);

  Future<bool> getCupWarmerEnabled();

  /// Live mat temperature in deg C, or null when the firmware has no valid
  /// reading.
  Future<double?> getCupWarmerCurrentTemperature();

  /// Persisted firmware pre-warm configuration.
  Future<void> setCupWarmerPreheat({
    required bool enabled,
    required int leadMinutes,
  });

  Future<CupWarmerPreheatState> getCupWarmerPreheatState();

  /// Persisted autonomous inactivity sleep timeout, minutes, 0 = disabled
  /// (max 240). Mirrors the app's `sleepTimeoutMinutes` 1:1.
  Future<void> setInactivitySleepTimeout(int minutes);

  /// Push the local wall-clock (seconds since Sunday 00:00:00 local) and
  /// replace the firmware wake table. The clock and table are RAM-only:
  /// pushed on every connect and whenever the authoritative schedules
  /// change. An empty [windows] list clears and disables the table.
  Future<void> pushFirmwareWakeSchedule({
    required int secondsSinceSundayLocal,
    required List<FirmwareWakeWindow> windows,
  });

  Stream<ScaleSnapshot> get weightSnapshot;

  Future<void> tareIntegratedScale();

  Future<void> setStopAtWeightTarget(double grams);

  Future<double> getStopAtWeightTarget();

  Stream<double> get stopAtWeightTarget;

  Stream<LedStripState?> get ledStripState;

  /// The last successfully hydrated LED state, or null when hydration has
  /// not succeeded (never fabricated black).
  Future<LedStripState?> getLedStripState();

  Future<void> setLedStrip(LedStripState state);

  Future<void> commitLedStrip();

  Future<LedStripState?> resetLedStrip();

  Future<void> setStopAtTemperatureTarget(double celsius);

  Future<double> getStopAtTemperatureTarget();

  Stream<double> get stopAtTemperatureTarget;

  Stream<bool> get probeAttached;

  Stream<double> get probeTemperature;
}
