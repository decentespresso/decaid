part of 'unified_de1.dart';

// Persistent LED palette (MMR rows 45-48, 0x00803898-0x008038A4), verified
// against BengleMainCPUFirmware at 2377c7e0 (APIView.cpp F_LEDStoreColor,
// applyLEDsForGivenState, syncSwitchColorsFromStrip, sendLEDColors).
//
// Firmware model:
// - FrontLEDAwake/RearLEDAwake/FrontLEDSleep/RearLEDSleep are persisted
//   palette registers (PERM_RWD). Writes are write-through; the firmware
//   applies the colour immediately when the machine is currently in the
//   matching state, and on every sleep/wake transition.
// - There is no independent frontSwitch register. The HV switch palette is
//   derived from the FRONT strip palette; a black strip colour falls back to
//   product defaults so an "LEDs off" strip never blanks a lit switch.
// - The live FrontLEDColor/RearLEDColor registers are persisted snapshots
//   that the firmware overwrites on every state change; they are not a
//   configuration surface and are not exposed.
//
// Decaid therefore keeps the existing 3-zone JSON shape (frontStrip,
// backStrip, frontSwitch) but: frontStrip/backStrip map 1:1 to the palette
// registers, and frontSwitch is DERIVED (read-only). Hydration happens once
// per connection; a failed hydration leaves the state unknown (null) rather
// than fabricating black. commit is a compatibility no-op (palette writes
// are already persisted) and reset re-reads from the firmware.

/// Product-default front-switch colours used when the user's front strip
/// colour is black/off (mirrors kSwitchDefaultAwake/kSwitchDefaultAsleep in
/// APIView.cpp — keep the two in sync).
const int kSwitchDefaultAwakeRgb = 0xFFF0C8; // 255,240,200 warm white
const int kSwitchDefaultAsleepRgb = 0x555043; // 85,80,67 dim warm

int _toFirmwareRgb(Color16 color) =>
    ((color.red >> 8) << 16) | ((color.green >> 8) << 8) | (color.blue >> 8);

Color16 _fromFirmwareRgb(int rgb) => Color16(
  ((rgb >> 16) & 0xFF) << 8,
  ((rgb >> 8) & 0xFF) << 8,
  (rgb & 0xFF) << 8,
);

bool _isBlack(Color16 color) =>
    color.red == 0 && color.green == 0 && color.blue == 0;

/// Derive the HV front-switch palette exactly like the firmware does
/// (syncSwitchColorsFromStrip): front strip awake/sleep colours, with black
/// substituted by the product defaults.
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

  /// The last successfully hydrated state, or null when hydration has not
  /// succeeded (no fabrication of black as authoritative state).
  Future<LedStripState?> getLedStripState() => _ledStripState.first;

  Future<void> setLedStrip(LedStripState state) async {
    await writeMmrInt(
      BengleMmr.frontLedAwake,
      _toFirmwareRgb(state.frontStrip.awake),
    );
    await writeMmrInt(
      BengleMmr.frontLedSleep,
      _toFirmwareRgb(state.frontStrip.sleeping),
    );
    await writeMmrInt(
      BengleMmr.rearLedAwake,
      _toFirmwareRgb(state.backStrip.awake),
    );
    await writeMmrInt(
      BengleMmr.rearLedSleep,
      _toFirmwareRgb(state.backStrip.sleeping),
    );
    final derived = LedStripState(
      frontStrip: state.frontStrip,
      backStrip: state.backStrip,
      frontSwitch: _deriveSwitchPalette(state.frontStrip),
    );
    if (!_ledStripState.isClosed) {
      _ledStripState.add(derived);
    }
  }

  /// Palette writes are write-through and persisted by the firmware; there
  /// is no separate commit latch. Kept for API compatibility as a no-op.
  Future<void> commitLedStrip() async {}

  /// Re-read the palette from the firmware. This is a truthful "reload", not
  /// a rollback: the firmware cannot undo a persisted write.
  Future<LedStripState?> resetLedStrip() async {
    await _hydrateLedStrip();
    return _ledStripState.value;
  }

  Future<void> initLedStrip() async {
    if (_ledStripState.isClosed) {
      _ledStripState = BehaviorSubject<LedStripState?>.seeded(null);
    }
    if (!bengleFeatureSurfaceSupported) {
      this.log.info(
        'LedStripCapability: firmware predates the LED palette MMR '
        'surface; LED state unavailable',
      );
      return;
    }
    await _hydrateLedStrip();
  }

  Future<void> _hydrateLedStrip() async {
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
    } catch (e) {
      this.log.warning('LedStripCapability: palette hydration failed: $e');
    }
  }

  Future<void> disposeLedStrip() async {
    if (!_ledStripState.isClosed) {
      await _ledStripState.close();
    }
  }
}
