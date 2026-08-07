import 'package:reaprime/src/models/device/impl/de1/mmr_address.dart';

/// Bengle-only MMR addresses. Future Bengle peripherals (LED strip,
/// integrated scale) declare their addresses here as the FW slots are
/// confirmed. Addresses live with the capability that owns them —
/// shared DE1 MMRs stay in `de1.models.dart#MMRItem`. The milk-probe
/// stop-at-temperature target lives in [BengleSteamMmr].
enum BengleMmr implements MmrAddress {
  /// Cup-warmer mat target temperature in °C, stored as raw IEEE-754
  /// float32 (little-endian). Range `0.0..80.0`; `0.0` = off.
  /// FW name: `MatSetPoint`. Permission RWD.
  matSetPoint(
    0x00803874,
    4,
    MmrValueKind.scaledFloat,
    'MatSetPoint',
    min: 0,
    max: 800,
    readScale: 0.1,
    writeScale: 10.0,
  ),

  /// Integrated-scale tare trigger. Address and value semantics are
  /// stubbed — FW slot TBD. Once published, fill in the real address
  /// and tighten [kind] / bounds. Capability code (`IntegratedScale-
  /// Capability.tareIntegratedScale`) currently routes through the
  /// control endpoint, not MMR — this entry exists so the FW slot has
  /// a home when the wire spec arrives.
  scaleTare(0x00000000, 4, MmrValueKind.int32, 'ScaleTare');

  const BengleMmr(
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

  /// Dart enums auto-synthesize `name`, but the analyzer doesn't see it
  /// as satisfying `MmrAddress.name` through `implements` — the cast
  /// forces dispatch to the synthesized `Enum.name`. See `MMRItem` for
  /// the same pattern + history (553550d / b7b8ed7).
  @override
  String get name => (this as Enum).name;
}

/// MMR addresses for the milk-probe steam stop. Currently the
/// stop-at-temperature target only — probe discovery / temperature
/// transport is unknown and may end up as a separate characteristic
/// rather than another MMR slot.
///
/// `stopAtTemperatureTarget` is a **set/get target** endpoint, not a
/// presence/detection mechanism. Address is stubbed `0x00000000`; the
/// `setStopAtTemperatureTarget` implementation no-ops on the wire and
/// caches locally until FW publishes the slot. Pin tests assert the
/// stub address so the day FW lands, the test flips and forces review.
enum BengleSteamMmr implements MmrAddress {
  /// Stop-at-temperature target in °C. `0.0` disables autonomous stop.
  /// Encoded as `scaledFloat` with scale factor 10 — decicelsius on
  /// the wire, unsigned. Range `0..80 °C`.
  stopAtTemperatureTarget(
    0x00000000,
    4,
    MmrValueKind.scaledFloat,
    'StopAtTemperatureTarget',
    min: 0,
    max: 800,
    readScale: 0.1,
    writeScale: 10.0,
  );

  const BengleSteamMmr(
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
