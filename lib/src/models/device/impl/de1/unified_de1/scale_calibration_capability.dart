part of 'unified_de1.dart';

/// Bengle scale-calibration surface; see doc/AI_BENGLE_NOTES.md.
mixin ScaleCalibrationCapability on UnifiedDe1 {
  static const double _minCalibrationWeightGrams = 1.0;
  static const double _maxCalibrationWeightGrams = 10000.0;

  Future<void> _calCommandQueue = Future<void>.value();

  Future<ScaleCalibrationState> getScaleCalibrationState() async {
    final raw = await readMmrInt(BengleMmr.scaleCalState);
    return ScaleCalibrationState.decode(raw);
  }

  Future<double> getScaleCalibrationWeight() async {
    return readMmrScaled(BengleMmr.scaleCalWeight);
  }

  Future<bool> startScaleCalibration(
    ScaleCalibrationCommand command, {
    double? weightGrams,
  }) {
    final run = _calCommandQueue.then(
      (_) => _startScaleCalibration(command, weightGrams: weightGrams),
    );
    _calCommandQueue = run.then((_) {}, onError: (_) {});
    return run;
  }

  Future<bool> _startScaleCalibration(
    ScaleCalibrationCommand command, {
    double? weightGrams,
  }) async {
    if (command == ScaleCalibrationCommand.latch) {
      final weight = (weightGrams ?? 200.0).clamp(
        _minCalibrationWeightGrams,
        _maxCalibrationWeightGrams,
      );
      await writeMmrScaled(BengleMmr.scaleCalWeight, weight);
    }
    final before = await getScaleCalibrationState();
    await writeMmrInt(BengleMmr.scaleCalCmd, command.wireValue);
    final after = await getScaleCalibrationState();
    if (command == ScaleCalibrationCommand.abort) {
      return after.step == ScaleCalibrationStep.idle;
    }
    return after.step != before.step;
  }
}
