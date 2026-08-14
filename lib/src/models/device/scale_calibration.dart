enum ScaleCalibrationStep {
  idle(0),
  zeroing(1),
  calLatch(2),
  taring(4),
  complete(5),
  error(6);

  const ScaleCalibrationStep(this.wireValue);

  final int wireValue;

  static ScaleCalibrationStep fromWire(int value) {
    for (final step in values) {
      if (step.wireValue == value) return step;
    }
    return ScaleCalibrationStep.idle;
  }
}

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

enum ScaleCalibrationCommand {
  abort(0),
  zero(1),
  latch(2);

  const ScaleCalibrationCommand(this.wireValue);

  final int wireValue;
}

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
