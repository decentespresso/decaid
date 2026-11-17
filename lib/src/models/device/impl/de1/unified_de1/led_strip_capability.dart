part of 'unified_de1.dart';

int _toFirmwareRgb(Color16 color) =>
    ((color.red >> 8) << 16) | ((color.green >> 8) << 8) | (color.blue >> 8);

mixin LedStripCapability on UnifiedDe1 {
  BehaviorSubject<LedStripState?> _ledStripState =
      BehaviorSubject<LedStripState?>.seeded(null);

  Stream<LedStripState?> get ledStripState => _ledStripState.stream;

  Future<LedStripState?> getLedStripState() => _ledStripState.first;

  Future<void> setLedStrip(LedStripState state) async {
    _forgetLedStripPreview();
    final stored = state.canonical();
    try {
      await writeMmrInt(
        BengleMmr.frontLedAwake,
        _toFirmwareRgb(stored.frontStrip.awake),
      );
      await writeMmrInt(
        BengleMmr.frontLedSleep,
        _toFirmwareRgb(stored.frontStrip.sleeping),
      );
      await writeMmrInt(
        BengleMmr.rearLedAwake,
        _toFirmwareRgb(stored.backStrip.awake),
      );
      await writeMmrInt(
        BengleMmr.rearLedSleep,
        _toFirmwareRgb(stored.backStrip.sleeping),
      );
    } catch (e) {
      if (!_ledStripState.isClosed) {
        _ledStripState.add(null);
      }
      rethrow;
    }
    if (!_ledStripState.isClosed) {
      _ledStripState.add(stored);
    }
  }

  Future<void> previewLedStrip({Color16? front, Color16? back}) async {
    if (front != null) {
      final rgb = _toFirmwareRgb(front);
      if (rgb != _shownFront) {
        final generation = _ledStripPreviewGeneration;
        try {
          await writeMmrInt(BengleMmr.frontLedColor, rgb);
        } catch (_) {
          _shownFront = null;
          rethrow;
        }
        if (generation == _ledStripPreviewGeneration) {
          _shownFront = rgb;
        }
      }
    }
    if (back != null) {
      final rgb = _toFirmwareRgb(back);
      if (rgb != _shownBack) {
        final generation = _ledStripPreviewGeneration;
        try {
          await writeMmrInt(BengleMmr.rearLedColor, rgb);
        } catch (_) {
          _shownBack = null;
          rethrow;
        }
        if (generation == _ledStripPreviewGeneration) {
          _shownBack = rgb;
        }
      }
    }
  }

  int? _shownFront;
  int? _shownBack;
  int _ledStripPreviewGeneration = 0;
  StreamSubscription<bool>? _ledStripSleepSubscription;

  void _forgetLedStripPreview() {
    _ledStripPreviewGeneration++;
    _shownFront = null;
    _shownBack = null;
  }

  Future<void> clearLedStripPreview() async {
    _forgetLedStripPreview();
    await _hydrateLedStrip();
    final state = _ledStripState.value;
    if (state == null) {
      throw LedStripStateUnavailableException(
        'ledStrip state unavailable (hydration failed or not yet complete)',
      );
    }
    for (var pass = 0; pass < 5; pass++) {
      final machineState = latestMachineState;
      if (machineState == null) {
        throw LedStripStateUnavailableException(
          'machine state unavailable (stateInfo not yet received)',
        );
      }
      final asleep = machineState == MachineState.sleeping;
      await writeMmrInt(
        BengleMmr.frontLedColor,
        _toFirmwareRgb(
          asleep ? state.frontStrip.sleeping : state.frontStrip.awake,
        ),
      );
      await writeMmrInt(
        BengleMmr.rearLedColor,
        _toFirmwareRgb(
          asleep ? state.backStrip.sleeping : state.backStrip.awake,
        ),
      );
      final restoredState = latestMachineState;
      if (restoredState != null &&
          (restoredState == MachineState.sleeping) == asleep) {
        return;
      }
    }
    throw LedStripStateUnavailableException(
      'machine awake/sleep phase did not settle after five restore passes',
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
    await _ledStripSleepSubscription?.cancel();
    _forgetLedStripPreview();
    _ledStripSleepSubscription = notificationsFor(Endpoint.stateInfo)
        .where((data) => data.lengthInBytes > 0)
        .map((data) => data.getUint8(0) == De1StateEnum.sleep.hexValue)
        .distinct()
        .listen((_) => _forgetLedStripPreview());
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
    await _ledStripSleepSubscription?.cancel();
    _ledStripSleepSubscription = null;
    _forgetLedStripPreview();
    if (!_ledStripState.isClosed) {
      await _ledStripState.close();
    }
  }
}
