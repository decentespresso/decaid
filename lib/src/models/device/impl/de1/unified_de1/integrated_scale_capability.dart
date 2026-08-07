part of 'unified_de1.dart';

/// Wire endpoints for Bengle's integrated scale.
///
/// Both [uuid] and [representation] return `null` for now — the firmware
/// slots have not yet been published. The [IntegratedScaleCapability]
/// mixin treats null wires as "capability not yet wired" and silently
/// no-ops. Once FW publishes the wire spec, fill these in and the rest
/// of the capability light up unchanged.
enum BengleScaleEndpoint implements LogicalEndpoint {
  /// Notify characteristic carrying weight frames.
  weight,

  /// Write characteristic for tare and other scale commands.
  control;

  @override
  String? get uuid => null;

  @override
  String? get representation => null;

  @override
  String get name => (this as Enum).name;
}

/// MMR addresses for the integrated scale.
///
/// Co-located with [IntegratedScaleCapability] so the mixin owns its
/// wire identifiers (mirrors how `LedStripCapability` owns
/// [BengleLedEndpoint]). Address is stubbed `0x00000000` — FW slot
/// TBD. While stubbed the capability is a logged no-op; once FW
/// publishes the address, fill it in and the rest lights up.
enum BengleScaleMmr implements MmrAddress {
  /// Stop-at-weight target in grams. `0.0` disables autonomous SAW
  /// (mirrors cup-warmer `0.0 = off`). Encoded as `scaledFloat` with
  /// scale factor 10 — decigrams on the wire.
  stopAtWeightTarget(
    0x00000000,
    4,
    MmrValueKind.scaledFloat,
    'StopAtWeightTarget',
    min: 0,
    max: 5000,
    readScale: 0.1,
    writeScale: 10.0,
  );

  const BengleScaleMmr(
    this.address,
    this.length,
    this.kind,
    this.description, {
    this.readScale = 1.0,
    this.writeScale = 1.0,
    this.min,
    this.max,
  });

  @override
  final int address;
  @override
  final int length;
  @override
  final MmrValueKind kind;
  final String description;
  @override
  final double readScale;
  @override
  final double writeScale;
  @override
  final int? min;
  @override
  final int? max;

  @override
  String get name => (this as Enum).name;
}

/// Stateful capability for Bengle's integrated scale.
///
/// Owns the weight stream and tare endpoint. Lifecycle is managed by the
/// concrete `Bengle` device — call [initIntegratedScale] from
/// `onConnect`, [disposeIntegratedScale] from `onDisconnect`.
/// `UnifiedDe1.disconnect()` invokes `onDisconnect()` for the device, so
/// `disposeIntegratedScale()` runs on every real disconnect. The
/// capability is also re-init-safe: `initIntegratedScale()` recreates
/// `_bengleWeight` if a previous dispose closed it, so a reconnect on
/// the same instance restores a live stream. The capability is
/// intentionally a no-op until firmware publishes the wire identifiers
/// (see [BengleScaleEndpoint]); when that happens, fill in the enum and
/// replace the placeholder parser/encoder bodies.
mixin IntegratedScaleCapability on UnifiedDe1 {
  BehaviorSubject<ScaleSnapshot> _bengleWeight =
      BehaviorSubject<ScaleSnapshot>();
  StreamSubscription<ByteData>? _bengleWeightSub;

  /// App-side cache of the SAW target in grams. `0.0` = SAW off.
  /// Seeded so late subscribers see the current value immediately.
  BehaviorSubject<double> _sawTarget = BehaviorSubject<double>.seeded(0.0);

  /// Count of stub-related info logs emitted this session (avoids
  /// spam — same pattern as `LedStripCapability._stubWarningsEmitted`).
  int _sawStubWarningsEmitted = 0;

  /// Live weight stream from the integrated scale. Emits nothing while
  /// the wire identifiers in [BengleScaleEndpoint] are null (FW TBD).
  Stream<ScaleSnapshot> get weightSnapshot => _bengleWeight.stream;

  /// Current stop-at-weight target in grams (`0.0` = SAW off).
  Stream<double> get stopAtWeightTarget => _sawTarget.stream;

  /// Subscribe to the integrated-scale weight notify endpoint. No-op
  /// (with a single info log) while the endpoint wires are null.
  ///
  /// Re-init-safe: if a previous [disposeIntegratedScale] closed the
  /// subject, a fresh one is created here so that listeners attaching
  /// after a reconnect see a live stream rather than an immediately-
  /// done one.
  Future<void> initIntegratedScale() async {
    if (_bengleWeight.isClosed) {
      _bengleWeight = BehaviorSubject<ScaleSnapshot>();
    }
    if (_sawTarget.isClosed) {
      _sawTarget = BehaviorSubject<double>.seeded(0.0);
    }
    final endpoint = BengleScaleEndpoint.weight;
    if (endpoint.uuid == null && endpoint.representation == null) {
      this.log.info(
        'IntegratedScaleCapability: weight endpoint unwired; '
        'no notify subscription. Awaiting FW.',
      );
      return;
    }
  }

  /// Cancel the weight subscription and close the snapshot subject.
  Future<void> disposeIntegratedScale() async {
    await _bengleWeightSub?.cancel();
    _bengleWeightSub = null;
    if (!_bengleWeight.isClosed) {
      await _bengleWeight.close();
    }
    if (!_sawTarget.isClosed) {
      await _sawTarget.close();
    }
  }

  /// Tare the integrated scale. No-op (with a single info log) while
  /// the control endpoint wires are null.
  Future<void> tareIntegratedScale() async {
    final ctl = BengleScaleEndpoint.control;
    if (ctl.uuid == null && ctl.representation == null) {
      this.log.info(
        'IntegratedScaleCapability: tare ignored — control '
        'endpoint unwired. Awaiting FW.',
      );
      return;
    }
  }

  /// Write the autonomous SAW target (grams) to FW. `0.0` disables
  /// SAW. Range `0.0..500.0`; out-of-range values are clamped.
  ///
  /// While [BengleScaleMmr.stopAtWeightTarget] is stubbed
  /// (`address == 0x00000000`) this is a logged no-op on the wire —
  /// the value is still cached so [stopAtWeightTarget] subscribers
  /// see the intent. Mirrors `LedStripCapability.setLedStrip`'s
  /// stub-friendly behaviour.
  Future<void> setStopAtWeightTarget(double grams) async {
    final clamped = grams.clamp(0.0, 500.0).toDouble();
    if (!_sawTarget.isClosed) {
      _sawTarget.add(clamped);
    }
    final addr = BengleScaleMmr.stopAtWeightTarget;
    if (addr.address == 0x00000000) {
      _logSawStubOnce('setStopAtWeightTarget($clamped) ignored. Awaiting FW.');
      return;
    }
    await writeMmrScaled(addr, clamped);
  }

  /// Read the SAW target from cache. While the MMR slot is stubbed
  /// the cache is authoritative; once FW publishes the address this
  /// hydrates from the wire on first call.
  Future<double> getStopAtWeightTarget() async {
    final addr = BengleScaleMmr.stopAtWeightTarget;
    if (addr.address == 0x00000000) {
      return _sawTarget.value;
    }
    final value = await readMmrScaled(addr);
    if (!_sawTarget.isClosed) {
      _sawTarget.add(value);
    }
    return value;
  }

  void _logSawStubOnce(String msg) {
    if (_sawStubWarningsEmitted < 1) {
      this.log.info('IntegratedScaleCapability: SAW endpoint unwired; $msg');
      _sawStubWarningsEmitted++;
    }
  }

  // Frame parser placeholder — replaced once FW spec lands.
  // ignore: unused_element
  void _handleWeightFrame(ByteData frame) {
    this.log.warning(
      'IntegratedScaleCapability: weight frame received but '
      'parser not yet implemented (FW spec TBD)',
    );
  }

  // Tare command encoder placeholder — replaced once FW spec lands.
  // ignore: unused_element
  List<int> _encodeTareCommand() => const [];
}
