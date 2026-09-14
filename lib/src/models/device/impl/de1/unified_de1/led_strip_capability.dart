part of 'unified_de1.dart';

int _toFirmwareRgb(Color16 color) =>
    ((color.red >> 8) << 16) | ((color.green >> 8) << 8) | (color.blue >> 8);

mixin LedStripCapability on UnifiedDe1 {
  BehaviorSubject<LedStripState?> _ledStripState =
      BehaviorSubject<LedStripState?>.seeded(null);

  Stream<LedStripState?> get ledStripState => _ledStripState.stream;

  Future<LedStripState?> getLedStripState() => _ledStripState.first;

  /// Store the palette. Only a zone whose colour changed is written.
  Future<void> setLedStrip(LedStripState state) async {
    final stored = state.canonical();
    final held = _ledStripState.valueOrNull?.canonical();
    try {
      if (held?.frontStrip.awake != stored.frontStrip.awake) {
        await writeMmrInt(
          BengleMmr.frontLedAwake,
          _toFirmwareRgb(stored.frontStrip.awake),
        );
      }
      if (held?.frontStrip.sleeping != stored.frontStrip.sleeping) {
        await writeMmrInt(
          BengleMmr.frontLedSleep,
          _toFirmwareRgb(stored.frontStrip.sleeping),
        );
      }
      if (held?.backStrip.awake != stored.backStrip.awake) {
        await writeMmrInt(
          BengleMmr.rearLedAwake,
          _toFirmwareRgb(stored.backStrip.awake),
        );
      }
      if (held?.backStrip.sleeping != stored.backStrip.sleeping) {
        await writeMmrInt(
          BengleMmr.rearLedSleep,
          _toFirmwareRgb(stored.backStrip.sleeping),
        );
      }
    } catch (e) {
      if (!_ledStripState.isClosed) {
        _ledStripState.add(null);
      }
      rethrow;
    }
    _shownFront = null;
    _shownBack = null;
    if (!_ledStripState.isClosed) {
      _ledStripState.add(stored);
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
  /// A frame that repeats the colour already showing writes nothing.
  Future<void> previewLedStrip({Color16? front, Color16? back}) async {
    if (front != null) {
      final rgb = _toFirmwareRgb(front);
      if (rgb != _shownFront) {
        await writeMmrInt(BengleMmr.frontLedColor, rgb);
        _shownFront = rgb;
      }
    }
    if (back != null) {
      final rgb = _toFirmwareRgb(back);
      if (rgb != _shownBack) {
        await writeMmrInt(BengleMmr.rearLedColor, rgb);
        _shownBack = rgb;
      }
    }
  }

  /// The colour each live register was last sent, or null when unknown.
  int? _shownFront;
  int? _shownBack;

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
      final state = LedStripState(
        frontStrip: ZoneLedState(
          awake: Color16.fromFirmwareRgb(frontAwake),
          sleeping: Color16.fromFirmwareRgb(frontSleep),
        ),
        backStrip: ZoneLedState(
          awake: Color16.fromFirmwareRgb(rearAwake),
          sleeping: Color16.fromFirmwareRgb(rearSleep),
        ),
      ).canonical();
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
