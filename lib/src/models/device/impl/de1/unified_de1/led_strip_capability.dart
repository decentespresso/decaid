part of 'unified_de1.dart';

const int kSwitchDefaultAwakeRgb = 0xFFF0C8;
const int kSwitchDefaultAsleepRgb = 0x555043;

int _toFirmwareRgb(Color16 color) =>
    ((color.red >> 8) << 16) | ((color.green >> 8) << 8) | (color.blue >> 8);

Color16 _fromFirmwareRgb(int rgb) => Color16(
  ((rgb >> 16) & 0xFF) << 8,
  ((rgb >> 8) & 0xFF) << 8,
  (rgb & 0xFF) << 8,
);

bool _isBlack(Color16 color) =>
    color.red == 0 && color.green == 0 && color.blue == 0;

Color16 _quantize(Color16 color) =>
    Color16(color.red & 0xFF00, color.green & 0xFF00, color.blue & 0xFF00);

ZoneLedState _quantizeZone(ZoneLedState zone) => ZoneLedState(
  awake: _quantize(zone.awake),
  sleeping: _quantize(zone.sleeping),
);

ZoneLedState _deriveSwitchPalette(ZoneLedState frontStrip) {
  return ZoneLedState(
    awake: _isBlack(frontStrip.awake)
        ? _fromFirmwareRgb(kSwitchDefaultAwakeRgb)
        : frontStrip.awake,
    sleeping: _isBlack(frontStrip.sleeping)
        ? _fromFirmwareRgb(kSwitchDefaultAsleepRgb)
        : frontStrip.sleeping,
  );
}

mixin LedStripCapability on UnifiedDe1 {
  BehaviorSubject<LedStripState?> _ledStripState =
      BehaviorSubject<LedStripState?>.seeded(null);

  Stream<LedStripState?> get ledStripState => _ledStripState.stream;

  Future<LedStripState?> getLedStripState() => _ledStripState.first;

  Future<void> setLedStrip(LedStripState state) async {
    final frontStrip = _quantizeZone(state.frontStrip);
    final backStrip = _quantizeZone(state.backStrip);
    try {
      await writeMmrInt(
        BengleMmr.frontLedAwake,
        _toFirmwareRgb(frontStrip.awake),
      );
      await writeMmrInt(
        BengleMmr.frontLedSleep,
        _toFirmwareRgb(frontStrip.sleeping),
      );
      await writeMmrInt(
        BengleMmr.rearLedAwake,
        _toFirmwareRgb(backStrip.awake),
      );
      await writeMmrInt(
        BengleMmr.rearLedSleep,
        _toFirmwareRgb(backStrip.sleeping),
      );
    } catch (e) {
      if (!_ledStripState.isClosed) {
        _ledStripState.add(null);
      }
      rethrow;
    }
    final derived = LedStripState(
      frontStrip: frontStrip,
      backStrip: backStrip,
      frontSwitch: _deriveSwitchPalette(frontStrip),
    );
    if (!_ledStripState.isClosed) {
      _ledStripState.add(derived);
    }
  }

  /// Show these colours on the strips WITHOUT deciding them.
  ///
  /// The firmware keeps the live colour apart from the stored palette:
  /// `FrontLEDColor` / `RearLEDColor` light the strip the moment they are written,
  /// and `applyLEDsForGivenState` recomputes them from the stored awake/sleep pair
  /// at the next sleep or wake transition. So a preview shows a colour and never
  /// becomes the machine's answer for a state.
  ///
  /// This is the only way to show an ASLEEP colour to someone editing it while the
  /// machine is awake: writing the stored sleep colour would be kept and not lit,
  /// because the firmware applies a stored colour only when the machine is already
  /// in the state that colour belongs to.
  ///
  /// The stored palette is untouched, so [ledStripState] does not move.
  Future<void> previewLedStrip({Color16? front, Color16? back}) async {
    if (front != null) {
      await writeMmrInt(BengleMmr.frontLedColor, _toFirmwareRgb(front));
    }
    if (back != null) {
      await writeMmrInt(BengleMmr.rearLedColor, _toFirmwareRgb(back));
    }
  }

  /// Put the strips back to the stored palette for the state the machine is in.
  ///
  /// A preview otherwise stands until the next sleep or wake transition, which may
  /// be hours away, so leaving a picker has to end it explicitly.
  Future<void> clearLedStripPreview() async {
    final state = _ledStripState.value;
    if (state == null) return;
    final snapshot = await currentSnapshot.first;
    final asleep = snapshot.state.state == MachineState.sleeping;
    await previewLedStrip(
      front: asleep ? state.frontStrip.sleeping : state.frontStrip.awake,
      back: asleep ? state.backStrip.sleeping : state.backStrip.awake,
    );
  }

  Future<void> commitLedStrip() async {}

  Future<LedStripState?> resetLedStrip() async {
    if (await _hydrateLedStrip()) {
      return _ledStripState.value;
    }
    return null;
  }

  Future<void> initLedStrip() async {
    if (_ledStripState.isClosed) {
      _ledStripState = BehaviorSubject<LedStripState?>.seeded(null);
    }
    await _hydrateLedStrip();
  }

  Future<bool> _hydrateLedStrip() async {
    try {
      final frontAwake = await readMmrInt(BengleMmr.frontLedAwake);
      final frontSleep = await readMmrInt(BengleMmr.frontLedSleep);
      final rearAwake = await readMmrInt(BengleMmr.rearLedAwake);
      final rearSleep = await readMmrInt(BengleMmr.rearLedSleep);
      final frontStrip = ZoneLedState(
        awake: _fromFirmwareRgb(frontAwake),
        sleeping: _fromFirmwareRgb(frontSleep),
      );
      final state = LedStripState(
        frontStrip: frontStrip,
        backStrip: ZoneLedState(
          awake: _fromFirmwareRgb(rearAwake),
          sleeping: _fromFirmwareRgb(rearSleep),
        ),
        frontSwitch: _deriveSwitchPalette(frontStrip),
      );
      if (!_ledStripState.isClosed) {
        _ledStripState.add(state);
      }
      return true;
    } catch (e) {
      this.log.warning('LedStripCapability: palette hydration failed: $e');
      if (!_ledStripState.isClosed) {
        _ledStripState.add(null);
      }
      return false;
    }
  }

  Future<void> disposeLedStrip() async {
    if (!_ledStripState.isClosed) {
      await _ledStripState.close();
    }
  }
}
