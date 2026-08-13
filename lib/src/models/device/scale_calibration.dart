/// Scale-calibration surface for Bengle firmware MMR rows 39-41
/// (ScaleCalCmd 0x00803880 / ScaleCalState 0x00803884 / ScaleCalWeight
/// 0x00803888), verified against BengleMainCPUFirmware at tadelv/Bengle
/// master 2377c7e0 (src/Classes/System.cpp startScaleCalStep +
/// getScaleCalStatePackedU32, src/Classes/CLoadCellCal.hpp).
library;

/// Firmware procedure step, serialized in ScaleCalState bits 31-24.
enum ScaleCalibrationStep {
  idle(0),
  zeroing(1),
  calLatch(2),
  taring(4),
  complete(5),
  error(6);

  const ScaleCalibrationStep(this.wireValue);

  final int wireValue;

  /// Wire value 3 was the old explicit point-2 step and is never emitted by
  /// current firmware; unknown values decode as [idle].
  static ScaleCalibrationStep fromWire(int value) {
    for (final step in values) {
      if (step.wireValue == value) return step;
    }
    return ScaleCalibrationStep.idle;
  }
}

/// Phase within a running step, serialized in ScaleCalState bits 19-16.
enum ScaleCalibrationSubState {
  settling(0),
  averaging(1),
  done(2),
  error(3);

  const ScaleCalibrationSubState(this.wireValue);

  final int wireValue;

  static ScaleCalibrationSubState fromWire(int value) {
    for (final sub in values) {
      if (sub.wireValue == value) return sub;
    }
    return ScaleCalibrationSubState.settling;
  }
}

/// Result code of the last latch attempt, serialized in ScaleCalState bits
/// 7-0. 0xFF means none/in-progress. Mirrors C_LoadCellCal::E_CalStatus.
enum ScaleCalibrationStatus {
  ok(0),
  incomplete(1),
  noZero(2),
  notSettled(3),
  badWeight(4),
  badDelta(5),
  illConditioned(6),
  outOfRange(7),
  notIsolated(8),
  none(0xFF);

  const ScaleCalibrationStatus(this.wireValue);

  final int wireValue;

  static ScaleCalibrationStatus fromWire(int value) {
    for (final status in values) {
      if (status.wireValue == value) return status;
    }
    return ScaleCalibrationStatus.none;
  }
}

/// Firmware-detected load cell of the last successful latch, serialized in
/// ScaleCalState bits 23-20 (0 = none, 1 = cell A, 2 = cell B).
enum ScaleCalibrationCell {
  none(0),
  a(1),
  b(2);

  const ScaleCalibrationCell(this.wireValue);

  final int wireValue;

  static ScaleCalibrationCell fromWire(int value) {
    for (final cell in values) {
      if (cell.wireValue == value) return cell;
    }
    return ScaleCalibrationCell.none;
  }
}

/// Commands accepted by ScaleCalCmd. Quick tare (3) is deliberately not
/// exposed here: Decaid already has the integrated-scale tare path
/// (ScaleTare 0x0080388C), and commands 4/5 (explicit left/right latches)
/// are retired in current firmware.
enum ScaleCalibrationCommand {
  abort(0),
  zero(1),
  latch(2);

  const ScaleCalibrationCommand(this.wireValue);

  final int wireValue;
}

/// Fully decoded ScaleCalState. All fields are populated from the packed
/// u32 exactly as the firmware builds it.
class ScaleCalibrationState {
  const ScaleCalibrationState({
    required this.step,
    required this.detectedCell,
    required this.subState,
    required this.secondsRemaining,
    required this.status,
  });

  final ScaleCalibrationStep step;
  final ScaleCalibrationCell detectedCell;
  final ScaleCalibrationSubState subState;
  final int secondsRemaining;
  final ScaleCalibrationStatus status;

  bool get isInProgress =>
      step == ScaleCalibrationStep.zeroing ||
      step == ScaleCalibrationStep.calLatch;

  bool get isTerminal =>
      step == ScaleCalibrationStep.complete ||
      step == ScaleCalibrationStep.error;

  factory ScaleCalibrationState.decode(int packed) {
    return ScaleCalibrationState(
      step: ScaleCalibrationStep.fromWire((packed >> 24) & 0xFF),
      detectedCell: ScaleCalibrationCell.fromWire((packed >> 20) & 0x0F),
      subState: ScaleCalibrationSubState.fromWire((packed >> 16) & 0x0F),
      secondsRemaining: (packed >> 8) & 0xFF,
      status: ScaleCalibrationStatus.fromWire(packed & 0xFF),
    );
  }

  Map<String, dynamic> toJson() => {
    'step': step.name,
    'detectedCell': detectedCell.name,
    'subState': subState.name,
    'secondsRemaining': secondsRemaining,
    'status': status.name,
  };
}
