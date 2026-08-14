part of 'unified_de1.dart';

/// Persistent Bengle LED palette; see doc/AI_BENGLE_NOTES.md.
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
    if (!supportsCurrentBengleFirmwareSurface) {
      this.log.info(
        'LedStripCapability: firmware predates the LED palette MMR '
        'surface; LED state unavailable',
      );
      return;
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
