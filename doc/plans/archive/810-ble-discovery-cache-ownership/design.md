# Issue #810 — BLE discovery cache ownership design

## Problem

`UniversalBleDiscoveryService._deviceScanned()` uses a fresh advertisement to decide both whether a cached Dart `Device` should be replaced and whether the shared native BLE connection for that device ID should be disconnected. Those are different permissions. Because state checks and listener cancellation await, `existing.disconnect()` can run after `ConnectionManager` or `EarlyConnectWatcher` has started or completed a newer connection for the same normalized device ID.

The per-device `BleLifecycleGate` only orders operations. It cannot make a stale disconnect safe: a disconnect queued behind a connect can still execute after the connect succeeds. Instance-local transport generations likewise do not identify the owner across two transports for one native device ID.

## Invariant

For a normalized BLE device ID, discovery owns only advertisement and cache maintenance. It must never issue native disconnect or disposal that can tear down a connection lifecycle it does not own.

Cache replacement remains allowed when an entry is genuinely stale, but it must not mutate a newer cache generation or discard an instance whose connection state changed while stale-state evidence was being gathered.

## Smallest safe design

Keep native connection teardown with the connection/device lifecycle owner. Do not add another ownership registry or extend `BleLifecycleGate` when removing discovery's destructive operation makes generation fencing unnecessary.

In `UniversalBleDiscoveryService`:

1. Preserve `ConnectionState.discovered`, `connecting`, and `disconnecting` without probing. A device can still report `discovered` while Linux or Windows has a native connection attempt in flight.
2. For a cached `connected` device, retain the existing native-state probe solely to distinguish a live cache entry from the #773 hard-power-loss case:
   - native `connected` or `connecting`: preserve the cache entry;
   - probe failure/timeout: state is unknown, so preserve and retry on a later advertisement;
   - native `disconnected` or `disconnecting`: stale evidence permits cache replacement, not native teardown.
3. After the native probe, recheck that `_devices[id]` is still the same instance, then re-read its Dart state and probe native state again. Preserve it if either result is active or unknown. This closes the cache TOCTOU window; no destructive native operation remains after the check.
4. Evict only the identical stale cache instance, cancel its discovery listener, emit the cache change, and create the fresh candidate. Remove the `existing.disconnect()` call entirely.
5. Fence both normal-discovery and quick-connect disconnect listeners with device-instance identity before removing `_devices[id]`. A delayed event from generation A must not remove generation B. Keep the code local; use one small private cache-listener helper only if it removes the duplicated adoption logic without broadening scope.
6. Do not change `BleLifecycleGate` production behavior. Its FIFO remains valid for lifecycle owners; discovery will no longer enqueue stale teardown behind connect.

This preserves #773 recovery: a cached device that still says `connected`, while the native link is confirmed gone and no state transition starts during the decision, is removed so the advertisement can produce a fresh usable instance. Recovery no longer depends on disconnecting a shared native ID.

## Hardware follow-up

User-reported spot check: Bengle connected successfully on iPhone with this fix. This is not evidence that the full sleep/reconnect matrix passed.

Code completion can prove the shared lifecycle invariant deterministically, but issue closure still requires the issue's field checks:

- iOS affected DE1: sleeping connect, live snapshots, sleep-to-idle, forced snapshot-staleness reconnect, no repeated 10-second timeout loop;
- Android DE1 plus preferred BLE scale: sleep, hard scale power-off/on, machine wake, fresh advertisement recovers without app restart.

Record hardware results in the PR; do not add iOS-only workarounds, retries, delays, longer timeouts, or disable the snapshot watchdog.
