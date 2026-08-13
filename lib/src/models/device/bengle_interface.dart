import 'package:reaprime/src/models/device/de1_interface.dart';
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
