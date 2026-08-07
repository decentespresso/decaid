import 'package:reaprime/src/models/device/de1_interface.dart';
import 'package:reaprime/src/models/device/led_strip.dart';
import 'package:reaprime/src/models/device/scale.dart';

abstract class BengleInterface extends De1Interface {
  Future<void> setCupWarmerTemperature(double celsius);

  Future<double> getCupWarmerTemperature();

  Stream<ScaleSnapshot> get weightSnapshot;

  Future<void> tareIntegratedScale();

  Future<void> setStopAtWeightTarget(double grams);

  Future<double> getStopAtWeightTarget();

  Stream<double> get stopAtWeightTarget;

  Stream<LedStripState> get ledStripState;

  Future<LedStripState> getLedStripState();

  Future<void> setLedStrip(LedStripState state);

  Future<void> commitLedStrip();

  Future<void> resetLedStrip();

  Future<void> setStopAtTemperatureTarget(double celsius);

  Future<double> getStopAtTemperatureTarget();

  Stream<double> get stopAtTemperatureTarget;

  Stream<bool> get probeAttached;

  Stream<double> get probeTemperature;
}
