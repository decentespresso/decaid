import 'package:reaprime/src/models/device/de1_interface.dart';
import 'package:reaprime/src/models/device/led_strip.dart';
import 'package:reaprime/src/models/device/scale.dart';

/// Marker interface for Bengle-specific machine API.
///
/// **Future capability methods land here.** When a Bengle capability
/// (cup warmer, integrated scale, LED strip, etc.) needs a public
/// API method, add it to this interface and implement it on `Bengle`.
/// Capability-internal state and helpers belong in their own
/// `Capability` mixins on `UnifiedDe1` (see the protected surface in
/// `UnifiedDe1` for the contract: `readMmrInt`, `readMmrScaled`,
/// `writeMmrInt`, `writeMmrScaled`, `notificationsFor`, etc.).
abstract class BengleInterface extends De1Interface {
  /// Set the cup-warmer mat target temperature in °C. Range 0.0–80.0.
  /// `0.0` turns the mat off — there is no separate enable flag in FW.
  /// Implementations clamp out-of-range values before writing.
  Future<void> setCupWarmerTemperature(double celsius);

  /// Read the current cup-warmer mat setpoint in °C.
  Future<double> getCupWarmerTemperature();

  /// Live snapshot stream from the integrated scale.
  ///
  /// Real `Bengle` wires this to `IntegratedScaleCapability.weightSnapshot`
  /// (notify endpoint TBD with FW; lands in Task 7). `MockBengle` synthesises
  /// weight by integrating `MockDe1`'s simulated flow.
  Stream<ScaleSnapshot> get weightSnapshot;

  /// Tare the integrated scale. Subsequent snapshots have weight relative
  /// to this zero.
  Future<void> tareIntegratedScale();

  /// Set the autonomous stop-at-weight target in grams. `0.0` disables
  /// SAW (mirrors cup-warmer `0.0 = off`). Range `0.0..500.0`.
  /// Implementations clamp out-of-range values.
  ///
  /// When set to a positive value the Bengle FW stops the shot when
  /// the integrated scale reads >= the target — the app's own
  /// `ShotSequencer` SAW path should bypass for `BengleInterface`
  /// machines to avoid a double stop.
  Future<void> setStopAtWeightTarget(double grams);

  /// Read the current SAW target in grams.
  Future<double> getStopAtWeightTarget();

  /// Latest SAW target stream (`0.0` = SAW off). Late subscribers see
  /// the cached current value immediately.
  Stream<double> get stopAtWeightTarget;

  /// Current LED strip state stream.
  Stream<LedStripState> get ledStripState;

  /// One-shot read of the current LED strip state.
  Future<LedStripState> getLedStripState();

  /// Write a full LED strip configuration (all zones, both modes).
  /// Updates cache and pushes to FW live registers. Does NOT persist
  /// to NVM — call [commitLedStrip] separately.
  Future<void> setLedStrip(LedStripState state);

  /// Persist the current LED strip configuration to FW NVM.
  Future<void> commitLedStrip();

  /// Reload the LED strip configuration from FW NVM, dropping uncommitted changes.
  Future<void> resetLedStrip();

  // --- Milk-probe steam stop (scaffolding) -----------------------------------
  // FW is not yet ready. The methods + streams below are the API surface
  // skin developers can target now. On real `Bengle` the streams are inert
  // (target replays cached value, probeAttached stays `false`,
  // probeTemperature never emits) until FW publishes the wire spec. See
  // [[bengle_steam_mmr]] for the MMR slot and [[bengle_milk_probe]] for
  // the planned probe device wrapper.

  /// Set the autonomous stop-at-temperature target in °C. `0.0` disables
  /// the stop. Range `0..80`. Today: caches locally + log-once; no MMR
  /// write until FW publishes the slot.
  Future<void> setStopAtTemperatureTarget(double celsius);

  /// Read the current stop-at-temperature target in °C.
  Future<double> getStopAtTemperatureTarget();

  /// Latest stop-at-temperature target stream (`0.0` = stop off).
  /// `BehaviorSubject` — late subscribers see the cached current value.
  Stream<double> get stopAtTemperatureTarget;

  /// Whether the milk probe is physically attached to the machine.
  /// `BehaviorSubject<bool>` seeded `false`. Real `Bengle` stays `false`
  /// until FW publishes a presence signal; `MockBengle` defaults to
  /// `true` for tests.
  Stream<bool> get probeAttached;

  /// Live milk-probe temperature stream (°C). `PublishSubject<double>` —
  /// no replay, latest-only consumers should track themselves. Real
  /// `Bengle` never emits today; `MockBengle` synthesises during steam.
  Stream<double> get probeTemperature;
}
