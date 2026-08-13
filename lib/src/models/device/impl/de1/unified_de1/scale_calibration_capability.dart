part of 'unified_de1.dart';

/// Firmware scale-calibration surface (MMR rows 39-41): precision zero,
/// isolated-cell gain latch with a known weight, and abort.
///
/// The current firmware calibration engine is order-free: platform removed,
/// a known mass placed directly on either load cell, `latch` run once per
/// cell; the firmware auto-detects the loaded cell and the second
/// distinct-cell latch solves and persists the calibration. Commands are
/// staged asynchronously by the firmware; a non-zero command is ignored
/// while the cal machine is busy or a shot is in progress, so [startScaleCalibration]
/// reports acceptance by observing the step leave its previous value.
///
/// Verified against BengleMainCPUFirmware at 2377c7e0: startScaleCalStep /
/// updateScaleCalProcedure / getScaleCalStatePackedU32 (System.cpp),
/// C_LoadCellCal.hpp.
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

  /// Submit a calibration command, serialized so concurrent submissions
  /// cannot interleave their acceptance reads.
  ///
  /// Returns true when the firmware accepted the command (the polled step
  /// left its previous value, or an abort landed on Idle) and false when it
  /// was ignored (machine busy, or shot in progress — the step stays put).
  /// `weightGrams` is required for [ScaleCalibrationCommand.latch] and must
  /// be within 1..10000 g; the firmware stores it as a float, so fractional
  /// grams are preserved.
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
      // Abort always lands on Idle and is never rejected by the firmware.
      return after.step == ScaleCalibrationStep.idle;
    }
    return after.step != before.step;
  }
}
