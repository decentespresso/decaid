// Decoder for the Bengle fused puck-estimator sample (`0xA014` / serial `[T]`).
// Mirrors `bengle_shot_sample.dart`: a big-endian PACKED frame, decoded with
// per-field sentinels that map to `null`, and dropped (→ `null`) when the
// frame is too short.
import 'dart:typed_data';

/// Minimum wire length of the Bengle `0xA014` estimator characteristic, in
/// bytes. Bytes 0–15 (the base fused-estimator layout) are frozen across wire
/// revisions, so this is also the shortest frame the decoder will accept.
const int bengleEstSampleBytes = 16;

/// Wire length once the Rev-2 R1-collapse detector tail is appended. Offsets
/// 0–15 are byte-identical to the Rev-1 layout; offsets 16–20 carry the
/// detector summary.
const int bengleEstSampleV2Bytes = 21;

/// Wire length once the Rev-3 measured-power tail is appended. Offsets 0-20 are
/// byte-identical to the Rev-2 layout; offset 21 carries [BengleEstSample.wPuck].
const int bengleEstSampleV3Bytes = 23;

/// Sentinel for a U16 field the firmware has not yet observed.
const int _u16Sentinel = 0xFFFF;

/// Sentinel for the U8 lag field ("no usable lag estimate").
const int _u8Sentinel = 0xFF;

/// Sentinel for the Rev-2 detector U8 magnitude / concentration fields
/// ("no event / undefined"). Same `0xFF` value as [_u8Sentinel]; named
/// separately to keep the detector-tail intent explicit.
const int _detU8Sentinel = 0xFF;

/// Decoded Bengle `0xA014` fused-estimator frame.
///
/// The estimator is a pure observer: it is streamed to the tablet for charting
/// and logging and drives no machine behaviour. Multi-byte fields are
/// **big-endian** (the `0xA013` convention, unlike the little-endian MMR
/// registers). Each "not yet observed" field decodes to `null` from its wire
/// sentinel rather than to a fake `0.0` — an unobserved value is a first-class
/// state, not zero.
class BengleEstSample {
  /// Struct revision (offset 0, `u8`). `1` = the base fused-estimator layout
  /// (offsets 0–15); `2` adds the R1-collapse detector tail (offsets 16–20;
  /// see the `detLastEvent*` fields).
  final int rev;

  /// Opaque estimator status-flags byte (offset 1, `u8`). Raw status bits
  /// reported by the firmware, forwarded unparsed as the snapshot's `estFlags`;
  /// the app does not interpret them.
  final int flags;

  /// Fused puck resistance, n=1 convention **R1** in bar·s/mL (offset 2,
  /// `u16 / 100`). `null` = not yet observed (sentinel `0xFFFF`).
  final double? r1;

  /// Fused puck resistance, n=2 convention **R2** in bar·s²/mL² (offset 4,
  /// `u16 / 1000`). `null` = not yet observed (sentinel `0xFFFF`).
  final double? r2;

  /// Fused compliance **C** in mL/bar (offset 6, `u16 / 1000`). `null` =
  /// unobserved (sentinel `0xFFFF`).
  final double? c;

  /// Resistance confidence 0..1 (offset 8, `u8 / 255`). Always present.
  final double confR;

  /// Estimated Qout lag in seconds (offset 9, `u8 / 10`, range 0..25.5).
  /// `null` = no usable lag estimate (sentinel `0xFF`).
  final double? lag;

  /// Lag-estimate confidence 0..1 (offset 10, `u8 / 255`). Always present.
  final double lagConf;

  /// Inflated Qout noise σ̂ in mL/s (offset 11, `u8 / 100`, cap 2.55). Always
  /// present.
  final double sigmaQ;

  /// Absorbed / voids volume estimate **V_abs** in mL (offset 12,
  /// `u16 / 10`). `null` = n/a (sentinel `0xFFFF`).
  final double? vAbs;

  /// Last closed pause's fitted decay time constant τ in seconds (offset 14,
  /// `u16 / 100`). `null` = no pause fitted yet (sentinel `0xFFFF`).
  final double? lastPauseTau;

  // R1-collapse detector tail (Rev 2, offsets 16–20). All four fields are
  // `null` when the frame predates Rev 2 (len < 21 or rev < 2) — either the
  // detector never ran or this build's firmware does not emit the tail, so the
  // corresponding snapshot keys stay absent. When the tail IS present,
  // [detEventCount] is always a real count (0 is a valid "no R1 collapse yet
  // this shot"); the other three describe the most recent event and are `null`
  // on their own wire sentinels. These are "R1 collapse events" (never
  // "channel openings") everywhere user-visible.

  /// Confirmed R1-collapse events so far THIS shot (offset 16, `u8`; 0 at shot
  /// start). `null` = no Rev-2 detector tail on this frame.
  final int? detEventCount;

  /// Onset time t0 of the most recent R1-collapse event, in seconds (offset
  /// 17, `u16` big-endian, 0.1 s units). `null` = none yet (sentinel `0xFFFF`)
  /// or no detector tail.
  final double? detLastEventT;

  /// Drop magnitude of the most recent event, `1 − R1/R1_ref` in 0..1 (offset
  /// 19, `u8 / 200`; the firmware clamps the raw byte at 200 → 1.0). `null` =
  /// none (sentinel `0xFF`) or no detector tail.
  final double? detLastEventMag;

  /// Drop concentration of the most recent event, 0..1 (offset 20, `u8 / 200`;
  /// firmware-clamped at 200 → 1.0). ≈1 → the drop is concentrated in the last
  /// couple of seconds (a cliff); ≈0.33 → a linear ramp. `null` = none /
  /// undefined (sentinel `0xFF`) or no detector tail.
  final double? detLastEventConc;

  /// Hydraulic power delivered **into the puck**, in watts (offset 21,
  /// `u16 / 1000`, Rev 3+).
  ///
  /// Measured by the firmware from its own `(P, Q_puck)` pair — the same one
  /// the resistance fit consumes — so it is NOT the `0.1 * pressure * flow` a
  /// client can derive from `0xA013`. That derivation can only use reported
  /// group flow (`Q_in`); this uses the flow actually passing through the puck.
  /// They agree in steady state and diverge during compliance transients, which
  /// is the reason the field exists. Compare
  /// `MachineSnapshot.hydraulicPowerDerived`,
  /// which is the derived form and is what a plain DE1 gets.
  ///
  /// `null` = not yet observed (sentinel `0xFFFF`), or a pre-Rev-3 frame. Never
  /// substitute `0.0`: zero watts is a real, different statement.
  ///
  /// Hydraulic, not electrical — mains draw is hundreds of watts and is not on
  /// this frame.
  final double? wPuck;

  const BengleEstSample({
    required this.rev,
    required this.flags,
    required this.r1,
    required this.r2,
    required this.c,
    required this.confR,
    required this.lag,
    required this.lagConf,
    required this.sigmaQ,
    required this.vAbs,
    required this.lastPauseTau,
    this.detEventCount,
    this.detLastEventT,
    this.detLastEventMag,
    this.detLastEventConc,
    this.wPuck,
  });
}

/// Decode a big-endian `0xA014` estimator frame.
///
/// Returns `null` when the frame is shorter than [bengleEstSampleBytes] — a
/// truncated notification is dropped rather than throwing a `RangeError`.
/// Extra trailing bytes are ignored, which is what keeps an older app
/// forward-compatible with a longer future frame. Per-field sentinels decode
/// to `null`.
///
/// The Rev-2 R1-collapse detector tail (offsets 16–20) is decoded ONLY when
/// the frame carries the full [bengleEstSampleV2Bytes] AND advertises
/// `rev >= 2`; otherwise all four `detLastEvent*`/`detEventCount` fields stay
/// `null`. A 16-byte Rev-1 frame, a 20-byte truncated Rev-2 frame, or a frame
/// whose rev is too old all take this backward-compatible path.
BengleEstSample? parseBengleEstSample(ByteData d) {
  if (d.lengthInBytes < bengleEstSampleBytes) return null;
  final rev = d.getUint8(0);
  final r1raw = d.getUint16(2, Endian.big);
  final r2raw = d.getUint16(4, Endian.big);
  final craw = d.getUint16(6, Endian.big);
  final lagraw = d.getUint8(9);
  final vabsraw = d.getUint16(12, Endian.big);
  final tauraw = d.getUint16(14, Endian.big);

  // Rev-2 detector tail. `detEventCount` is a real count (0 valid) whenever the
  // tail is present; the three event descriptors map their sentinels to null.
  int? detEventCount;
  double? detLastEventT;
  double? detLastEventMag;
  double? detLastEventConc;
  if (d.lengthInBytes >= bengleEstSampleV2Bytes && rev >= 2) {
    detEventCount = d.getUint8(16);
    final tRaw = d.getUint16(17, Endian.big);
    detLastEventT = tRaw == _u16Sentinel ? null : tRaw / 10.0;
    final magRaw = d.getUint8(19);
    detLastEventMag = magRaw == _detU8Sentinel ? null : magRaw / 200.0;
    final concRaw = d.getUint8(20);
    detLastEventConc = concRaw == _detU8Sentinel ? null : concRaw / 200.0;
  }

  // Rev-3 measured-power tail.
  double? wPuck;
  if (d.lengthInBytes >= bengleEstSampleV3Bytes && rev >= 3) {
    final wRaw = d.getUint16(21, Endian.big);
    wPuck = wRaw == _u16Sentinel ? null : wRaw / 1000.0;
  }

  return BengleEstSample(
    rev: rev,
    flags: d.getUint8(1),
    r1: r1raw == _u16Sentinel ? null : r1raw / 100.0,
    r2: r2raw == _u16Sentinel ? null : r2raw / 1000.0,
    c: craw == _u16Sentinel ? null : craw / 1000.0,
    confR: d.getUint8(8) / 255.0,
    lag: lagraw == _u8Sentinel ? null : lagraw / 10.0,
    lagConf: d.getUint8(10) / 255.0,
    sigmaQ: d.getUint8(11) / 100.0,
    vAbs: vabsraw == _u16Sentinel ? null : vabsraw / 10.0,
    lastPauseTau: tauraw == _u16Sentinel ? null : tauraw / 100.0,
    detEventCount: detEventCount,
    detLastEventT: detLastEventT,
    detLastEventMag: detLastEventMag,
    detLastEventConc: detLastEventConc,
    wPuck: wPuck,
  );
}
