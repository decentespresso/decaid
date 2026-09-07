# Issue #810 — BLE discovery cache ownership plan

## Problem

`UniversalBleDiscoveryService._deviceScanned()` uses a fresh advertisement to decide both whether a cached Dart `Device` should be replaced and whether the shared native BLE connection for that device ID should be disconnected. Those are different permissions. Because state checks and listener cancellation await, `existing.disconnect()` can run after `ConnectionManager` or `EarlyConnectWatcher` has started or completed a newer connection for the same normalized device ID.

The per-device `BleLifecycleGate` only orders operations. It cannot make a stale disconnect safe: a disconnect queued behind a connect can still execute after the connect succeeds. Instance-local transport generations likewise do not identify the owner across two transports for one native device ID.

## Invariant

For a normalized BLE device ID, discovery owns only advertisement and cache maintenance. It must never issue native disconnect or disposal that can tear down a connection lifecycle it does not own.

Cache replacement remains allowed when an entry is genuinely stale, but it must not mutate a newer cache generation or discard an instance whose connection state changed while stale-state evidence was being gathered.

## Smallest safe design

Keep native connection teardown with the connection/device lifecycle owner. Do not add another ownership registry or extend `BleLifecycleGate` when removing discovery's destructive operation makes generation fencing unnecessary.

In `UniversalBleDiscoveryService`:

1. Treat `ConnectionState.connecting` as active ownership regardless of the platform's current native state. Preserve it without probing. Treat `disconnecting` as an in-flight lifecycle transition too.
2. For a cached `connected` device, retain the existing native-state probe solely to distinguish a live cache entry from the #773 hard-power-loss case:
   - native `connected` or `connecting`: preserve the cache entry;
   - probe failure/timeout: state is unknown, so preserve and retry on a later advertisement;
   - native `disconnected` or `disconnecting`: stale evidence permits cache replacement, not native teardown.
3. After the native probe, recheck that `_devices[id]` is still the same instance and re-read its Dart connection state. If it became `connecting`, `disconnecting`, or otherwise cannot be determined, preserve it. This closes the cache TOCTOU window; no destructive native operation remains after the check.
4. Evict only the identical stale cache instance, cancel its discovery listener, emit the cache change, and create the fresh candidate. Remove the `existing.disconnect()` call entirely.
5. Fence both normal-discovery and quick-connect disconnect listeners with device-instance identity before removing `_devices[id]`. A delayed event from generation A must not remove generation B. Keep the code local; use one small private cache-listener helper only if it removes the duplicated adoption logic without broadening scope.
6. Do not change `BleLifecycleGate` production behavior. Its FIFO remains valid for lifecycle owners; discovery will no longer enqueue stale teardown behind connect.

This preserves #773 recovery: a cached device that still says `connected`, while the native link is confirmed gone and no state transition starts during the decision, is removed so the advertisement can produce a fresh usable instance. Recovery no longer depends on disconnecting a shared native ID.

## Test-first implementation

Extend `test/services/universal_ble_discovery_service_test.dart` before production changes. Reuse the existing service/factory setup and add the minimum shared-native fake needed to make `connect(id)` and `disconnect(id)` affect the same backend state across transport instances.

1. **Connecting is protected across platform semantics.** Parameterize the meaningful Linux/Windows-style case: cached Dart state is `connecting`, native state still reports `disconnected`; a fresh advertisement neither replaces nor disconnects the active attempt. The same assertion covers Darwin/Android pre-native-connect timing without production platform conditionals.
2. **Stale observation racing connection.** Pause the native-state probe after it observes a cached `connected` instance with an apparently dead link, transition that same instance to `connecting`, then release the probe. Assert no native disconnect and that the connecting cache owner remains current.
3. **No queued teardown behind connect.** Hold a shared-native connect inside the existing lifecycle gate while a duplicate advertisement is processed, complete the connect, and assert no later discovery disconnect executes. The fake must make a stale disconnect capable of cancelling the shared native connection so the old implementation fails meaningfully.
4. **Genuine stale recovery.** Update the existing `fresh advertisement replaces...` test to assert a second usable transport/device is emitted while the stale and new shared native connection are not disconnected. Remove the implementation-specific `disconnectCalls >= 1` expectation.
5. **Unknown is non-destructive.** Cover cached-state timeout/error and native-state timeout/error. Assert no disconnect; unknown connected ownership is preserved/deferred rather than treated as permission to clean up.
6. **Listener generation fencing.** For normal discovery, replace A with B, deliver A's delayed `disconnected`, and assert B remains cached/emitted. Repeat through quick-connect, including the assignment/cancellation window.
7. Keep or adapt the existing live-native-link test to prove ordinary duplicate advertisements still reuse the cached device.

If a test-only seam is needed to pause state evaluation, inject a narrowly scoped callback/future into the test transport or fake platform. Do not add timing delays or platform branches to production code.

## Verification

Run in this order:

1. `dart format lib test`
2. `flutter test test/services/universal_ble_discovery_service_test.dart`
3. `flutter test test/services/ble/ble_lifecycle_gate_test.dart test/universal_ble_transport_recovery_test.dart`
4. `flutter analyze`
5. `flutter test`

The pre-change full-suite baseline has one unrelated intermittent failure in `test/controllers/de1_controller_shotsettings_stall_test.dart` (`Bad state: Cannot add new events after calling close`, line 165). Re-run it separately; do not change that subsystem as part of #810 unless it reproduces deterministically and blocks verification.

## Hardware follow-up

User-reported spot check: Bengle connected successfully on iPhone with this fix. This is not evidence that the full sleep/reconnect matrix passed.

Code completion can prove the shared lifecycle invariant deterministically, but issue closure still requires the issue's field checks:

- iOS affected DE1: sleeping connect, live snapshots, sleep-to-idle, forced snapshot-staleness reconnect, no repeated 10-second timeout loop;
- Android DE1 plus preferred BLE scale: sleep, hard scale power-off/on, machine wake, fresh advertisement recovers without app restart.

Record hardware results in the PR; do not add iOS-only workarounds, retries, delays, longer timeouts, or disable the snapshot watchdog.
