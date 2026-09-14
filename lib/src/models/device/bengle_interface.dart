import 'package:reaprime/src/models/device/de1_interface.dart';
import 'package:reaprime/src/models/device/cup_warmer.dart';
import 'package:reaprime/src/models/firmware_wake_window.dart';
import 'package:reaprime/src/models/device/led_strip.dart';
import 'package:reaprime/src/models/device/scale.dart';
import 'package:reaprime/src/models/device/scale_calibration.dart';
import 'package:reaprime/src/models/device/impl/de1/unified_de1/bengle_est_sample.dart';

abstract class BengleInterface extends De1Interface {
  Future<ScaleCalibrationState> getScaleCalibrationState();

  Future<bool> startScaleCalibration(
    ScaleCalibrationCommand command, {
    double? weightGrams,
  });

  Future<void> setCupWarmerTemperature(double celsius);

  Future<double> getCupWarmerTemperature();

  Future<void> setCupWarmerEnabled(bool enabled);

  Future<bool> getCupWarmerEnabled();

  Future<double?> getCupWarmerCurrentTemperature();

  Future<void> setCupWarmerPreheat({
    required bool enabled,
    required int leadMinutes,
  });

  Future<CupWarmerPreheatState> getCupWarmerPreheatState();

  Future<void> setInactivitySleepTimeout(int minutes);

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

  Future<LedStripState?> getLedStripState();

  Future<void> setLedStrip(LedStripState state);

  Future<void> commitLedStrip();

  Future<LedStripState?> resetLedStrip();

  Future<void> setStopAtTemperatureTarget(double celsius);

  Future<double> getStopAtTemperatureTarget();

  Stream<double> get stopAtTemperatureTarget;

  Stream<bool> get probeAttached;

  Stream<double> get probeTemperature;

  /// Decoded `0xA014` fused puck-estimator frames. Unconditional over
  /// serial/CDC, and over BLE only when the machine registers the
  /// characteristic. Silent until the first frame arrives, so a subscriber can
  /// treat "no event" as "this machine has no estimator".
  Stream<BengleEstSample> get puckEstimator;
}
