# AI BLE Notes

Read this when changing BLE transport, scanning, connection lifecycle, GATT error handling, or transport abstractions. Skip it for pure REST/WS, UI, profile, or plugin changes.

## Source Of Truth

- Transport interfaces: `lib/src/models/device/data_transport.dart`, `lib/src/models/device/ble_transport.dart`.
- BLE transport: `lib/src/services/ble/universal_ble_transport.dart` (cross-platform via `universal_ble` package).
- Connection orchestration: `lib/src/controllers/connection/connection_manager.dart`.
- Device discovery + matching: `lib/src/services/device_matcher.dart`, `lib/src/services/device_discovery/`.
- Error filtering: `lib/src/services/crashlytics_error_filter.dart`.

## Hard Rules

- Never import 3rd-party BLE libraries (e.g. `universal_ble`) outside `lib/src/services/ble/`. Wrap library-specific types (errors, events) in domain types at the transport boundary.
- All BLE operations use 128-bit UUID format for maximum platform compatibility.
- Throttle rapid characteristic reads to avoid overwhelming the Bluetooth stack.
- Always cancel stream subscriptions in `dispose()` methods.
- Scale write paths must catch `DeviceNotConnectedException` at their lowest-level write helper so the exception doesn't escape from fire-and-forget Timer callbacks.

## Transport Architecture

The single BLE transport is `UniversalBleTransport` in `lib/src/services/ble/universal_ble_transport.dart`, wrapping the `universal_ble` package. It implements the `DataTransport` interface: `connect()`, `disconnect()`, `dispose()`, `read(uuid)`, `write(uuid, data)`, `writeWithResponse(uuid, data)`, `subscribe(uuid)`, `connectionState` stream.

`UnifiedDe1Transport` wraps `UniversalBleTransport` and adds MMR read/write on top of raw characteristic I/O. It provides `rawData` stream, `readMmr()`, `writeMmr()`, and typed connection guards (`DeviceNotConnectedException.machine()` on read/write when disconnected).

## Connection Flow

`ConnectionManager` supports three distinct connection intents, selected via
`ConnectionAttemptPolicy`:

### automatic `connect()`

Used by startup, machine recovery, and USB-attach recovery. Tries
remembered-machine quick-connect first. If that fails, scans for devices.
During the scan, preferred machines and scales are connected as they appear
(`connectPreferredDuringScan: true`). The scan stops early once all
preferences are satisfied (`stopScanAfterPreferredConnect: true`).
Preferred-scale watch and deferred scale scan handle the wake-after-connect
race.

### explicit `scanAndConnect()`

Used by the launcher scan page, REST/WS scan commands (when `connect=true`),
and explicit retry buttons. Completes full discovery before policy runs
(`connectPreferredDuringScan: false`), never quick-connects, and never
stops early. Preserves occupied machine/scale slots. When discovery
produces ambiguity (multiple candidates for an unoccupied slot),
a `ConnectionSelectionSession` holds the immutable scan snapshot.
`selectMachine()` and `selectScale()` continue the session against the
session-owned canonical candidates — no new scan fires.

### `scaleOnly` / scale recovery

Triggered by the background scale watch, deferred scale scan, and queued
scale-only reconnect callers. Skips the machine phase entirely — a scale
can connect independently of the machine. If a selection session is active
with pending ambiguity, scale recovery is deferred to avoid racing with
the user's choice. Scales powered off while the machine is sleeping are
skipped to respect the radio-disconnect power mode. On Android, uses a
filtered scan to bypass background throttling.

### Phase lifecycle

`StatusPublisher` drives the `ConnectionStatus` stream with phases:
`idle` → `scanning` → `connectingMachine` → `connectingScale` → `ready`.

Errors transit through the status-publisher gatekeeper: transient errors
(most `ConnectionErrorKind` values) are stripped when the phase moves
into a clearing phase (`connectingMachine`, `connectingScale`, `ready`).
Sticky errors (`scanFailed`, `bluetoothPermissionDenied`) survive
transitions.

### Slot policy

Machine and scale are independently fillable. Occupied slots are never
replaced automatically by a scan. A missing slot auto-connects its
preferred device when found. Without a preferred ID, exactly one candidate
auto-connects; more than one produces ambiguity.

### Cancellation and superseding

`cancelActiveScan()` bumps the generation token, stops the scanner,
cancels any active selection session, discards any queued explicit
replacement, and clears pending ambiguity. An in-flight `_connectImpl`
detects the generation mismatch after `runScan` returns and skips policy.
`cancelSelectionSession()` finalises an already-completed scan as cancelled
without touching an in-flight scan.

Repeated explicit scan requests ("ReScan", stale-scan recovery, repeated
REST/UI calls) supersede the active scan and coalesce into a single
queued replacement. The superseded scan emits one cancelled report; the
replacement emits its normal report. If `cancelActiveScan()` fires while
a replacement is queued, the replacement is discarded and its waiting
callers complete cleanly.

Cancel (launcher) and route-back interception both route through
`cancelActiveScan()`. "View found devices" intentionally stops discovery
and proceeds with partial results — that is a different action, not
cancellation.

## Footgun #1: GATT-133 on Cold Boot

**Symptom:** `Unknown Error 133` on first connect after app restart. Second scan/connect succeeds normally.

**Root cause:** Android BLE stack (`BluetoothGatt.gattStatus = 133 = GATT_ERROR`) busy during connect init. Not a device problem — the `connect()` call itself fails before any characteristic I/O.

**Fix pattern:** `EarlyConnectWatcher` already retries; the 2nd attempt succeeds.

**Status:** The early-connect watcher handles this. Not a code bug — an Android BLE stack behavior.

## Footgun #2: Listener Stacking on Reconnect

**Symptom:** Duplicate WebSocket state messages, `currentSnapshot` emits duplicates.

**Root cause (fixed in PR #246):** `UnifiedDe1Transport.connect()` re-ran `_bleConnect()` → re-`subscribe()`d all characteristics without disconnecting first. `cancelWhenDisconnected` never fired, so listeners stacked → every notification delivered twice.

**Fix:** `CharSubscriptions` helper (cancel-before-replace per characteristic UUID). Unit-tested.

**Verification:** Cannot reproduce in unit/simulate. Rely on Crashlytics + `DuplicateBleSubscription` telemetry to confirm the path fires.

## Footgun #3: USB Charger Dedup

**Symptom:** `BatteryController` writing `setUsbChargerMode` every 60s unconditionally (~2665 writes/2 days).

**Root cause:** DE1 FW re-enables the charger on its own. The periodic write only matters while discharging.

**Fix (PR #246):** `shouldWriteChargerMode()` in `charging_logic.dart`: write-on-change, re-assert "off" every 5min while discharging, skip otherwise. Reset last-applied on disconnect.

## Footgun #4: Watch Scan Silent Death (fork SafeScanner)

**Symptom:** background scale watch armed (`Background device watch started` in the log) but the preferred scale never auto-connects; a manual scan connects it immediately. No error anywhere.

**Root cause (two mechanisms in the universal_ble fork's Android code):**
1. `SafeScanner`'s scan-frequency throttle (>5 starts/30s) silently swallows a start: the Dart call returns success while the real start is deferred via `handler.postDelayed`, and any `stopScan` in between cancels the deferral (`removeCallbacksAndMessages(null)`). Scan churn (bursts + watch pause/resume around machine reconnects) is the trigger.
2. `onScanFailed` is logged Kotlin-side and never surfaced to Dart, so a scan Android kills post-start is invisible.

**Fix:** `UniversalBleDiscoveryService` probes `UniversalBle.isScanning()` every 90s while the watch scan is believed running (`_armWatchLiveness`). Dead scan → teardown + restart through `_restartWatchOrReportFailure`, so a failing restart reports on `deviceWatchFailures` and `ScaleWatch` activates the legacy backoff. Probe errors fail open — an unprovable probe must not churn the session; ownership is re-checked after the await (a burst may have taken the session).

**Coverage limit:** `isScanning()` reflects SafeScanner's *host-side bookkeeping*, not adapter truth. Mechanism 1 is caught (bookkeeping never went true). Mechanism 2 is NOT (bookkeeping stays true after `onScanFailed`) — bounded by the 25-min refresh until the fork updates SafeScanner state in `onScanFailed` / emits a scan-state event (candidate fork follow-up).

**Field triage:** `ScaleWatch` logs sightings at INFO. `Background device watch started` with no `Preferred scale … sighted` → scan/screen problem (this footgun, or unfiltered-scan screen-off suspension). `sighted` with no connect → connect-path problem.

## Gone-Device Error Handling

`UniversalBleTransport._handleGattError()` catches `UniversalBleException` with gone-device codes:
`deviceNotFound`, `connectionTerminated`, `deviceDisconnected`, `unknownError`.

On hit: emits `disconnected`, drains the queue with typed `deviceDisconnected`, and throws `DeviceNotConnectedException`.

`characteristicNotFound` and `serviceNotFound` are ambiguous and are handled separately. A live peripheral
returns them when the attribute simply is not in its GATT database, and a dead link returns them from a stale
cache. Treating them as gone-device broke the Solo Barista (LSJ-001), which the matcher routes to `EurekaScale`
but which has no 0x180F battery service: the optional battery read at the end of `onConnect()` failed with
`characteristicNotFound`, the transport emitted `disconnected`, and the scale dropped one tick after connecting
(log signature: `GATT read(...2a19...) failed - device gone`, then `scale connection update: disconnected`).
These two codes now log, rethrow the original `UniversalBleException`, and hand off to
`_probeAndDeclareIfDead()`, which asks the OS for the real link state and only then declares the link dead.
Device implementations should still gate optional reads on `discoverServices()` rather than relying on the probe.

The `isBenignFrameworkError()` filter in `crashlytics_error_filter.dart` suppresses these from `FlutterError.onError` — but scale-level catches at the write helper are defense-in-depth.

## Faulted Queue Recovery

Dart `Future.timeout()` does not cancel the native BLE Future. When a queued operation times out, universal_ble 2.2.1 faults that exact queue generation. The original caller receives `TimeoutException`; pending and newly submitted commands receive typed `operationCancelled` and are not dispatched.

`UniversalBleTransport._onOperationTimeout()` must never immediately clear this barrier. Recovery follows one of two safe paths:

1. Poll payload-free queue diagnostics. Once `activeOperations == 0`, clear the faulted generation with `clearQueueWithError(... operationCancelled)`; the next command creates a clean generation.
2. If the native operation is still unresolved after the 2-second grace period, request an unqueued `disconnect()`. Keep the queue faulted unless the native disconnect event confirms teardown; `UniversalBle.disconnect()` swallows timeout/failure, so its returned Future is not confirmation. The native event clears with `deviceDisconnected` and starts the normal reconnect cascade.

A queue can produce only one wrapper timeout per faulted generation; followers are cancelled rather than dispatched. Therefore the old "three consecutive operation timeouts" policy is invalid under 2.2.1. The bounded unresolved-operation grace period is now the dead-link policy. Recovery tasks and asynchronous OS probes carry the transport connection generation so late completion from an old connection cannot clear a replacement queue or emit stale state.

`operationCancelled` means local queue recovery, never physical disconnect. It is benign Crashlytics noise. `deviceDisconnected` remains reserved for a confirmed or forced physical disconnect. The legacy `Exception('Queue Cancelled')` string sentinel is not part of the 2.2.1 path.

## BLE Scanning

- Device discovery uses unfiltered scans with name-based matching (`DeviceMatcher`).
- Service verification during `onConnect()` via `BleServiceIdentifier`.
- `ScanStateGuardian` guards against overlapping scans and tracks adapter state.
- `ScanOrchestrator` manages single-scan lifecycle.

## Sleep From NeedsWater (Refill State)

DE1 firmware build 1357+ honors a BLE sleep request while the machine is in refill/needsWater state when no refill kit is present. The app sends sleep from `needsWater` only for DE1 (not Bengle) on FW >= 1357 (`PresenceController._kSleepOnRefillMinFwBuild` / `_canSleepFromState`); idle/schedIdle are always eligible.

**Why the build gate exists:** older firmware ignores the sleep request *while in refill* but keeps it latched, honoring it once the machine exits refill (e.g. right after the user refills the tank), so sending sleep from needsWater on old FW would put the machine straight back to sleep after a refill. With a refill kit present, the FW ignores the request (kit refill in progress) — the FW owns that guard, the app just sends the request.

## Comms-Layer Patterns

An awake Decent Scale connection requires a recognised FFF4 status or weight frame after subscription and a status request. Two seconds of silence triggers one immediate re-subscribe and status request; a second silent window tears down the transport without sending the physical power-off command so ConnectionManager owns the next reconnect. A deliberately sleeping reconnect only restores the subscription while remaining dark and defers the same readiness probe until wake.

Acaia parsing is frame-bounded. Payload lengths above 64 bytes and impossible lengths for known settings or weight events trigger header resynchronization; complete unsupported frames are consumed whole so embedded `EF DD` bytes cannot become top-level frames. Only accepted settings, weight, or timer frames refresh liveness. Event 11 selector 5 carries weight, while selector 7 is timer data. Connection readiness requires a decoded valid weight rather than an arbitrary notification.

Scale maintenance uses self-scheduling one-shot timers and owns each asynchronous operation before scheduling another cycle. Do not perform asynchronous BLE writes directly from `Timer.periodic`; that permits overlap and leaves failures unowned. Decent notification recovery remains single-flight across connection generations, so reconnect waits for an unresolved prior subscription operation.

Three reusable idioms from the comms-harden effort:

1. **Tracked-latest over `Rx.combineLatest`** — for single-writer derived state, capture each stream's latest value into a field and route everything through one `_computeStatus()` method. Avoids hidden reentrancy.

2. **Queue-with-coalesce** for concurrent ops of the same kind — one shared `Completer`, drain in the `finally` of the in-flight op (see `scaleOnly` reconnect in `ConnectionManager`). Cleaner than mutex + retry.

3. **Generation token + cancellable Timer/Completer** for debounce-across-disconnect races — bump the generation in the disconnect path, capture it in the debounce closure, bail if it changed when the timer fires (see `De1Controller._shotSettingsDebounce`).

## Troubleshooting

| Symptom | First place to look |
|---------|---------------------|
| GATT-133 on first connect, works on retry | `EarlyConnectWatcher` — 2nd attempt should succeed. |
| Duplicate state messages | Listener stacking. Check `CharSubscriptions` is cancel-before-replace. |
| Scale write exceptions escaping to framework | Scale write path missing `DeviceNotConnectedException` catch. Add at `_writeCommand` / `_safeWrite`. |
| BLE scan overlaps | `ScanStateGuardian` — check adapter state tracking. |
| `TimeoutException` in `universal_ble/queue.dart` | Queue generation must stay faulted until the native Future settles or a native event confirms disconnect; a disconnect request timing out is not confirmation. May relate to zombie-link (#431) or concurrent BLE write contention (#423). |
| `PlatformException: Location services required` | Android location permissions not granted. Onboarding check or troubleshooting wizard (#125/#126). |

## Android USB Attach Recovery

`SerialServiceAndroid` implements the optional `DeviceAttachNotifier`
capability. Attach events are non-replaying hints and may carry incomplete
metadata; serial scanning and detection remain the support filter. Android can
broadcast attach before the CDC interface is usable, so
`AttachReconnectCoordinator` coalesces bursts and waits a configurable 500 ms
before acting.

A second optional capability, `UsbAttachProbe`, lets the originating serial
service positively identify and connect the specifically attached USB device.
`SerialServiceAndroid.connectAttachedMachine` correlates the event with a
newly listed USB device (stable-ID match when Android supplied one, otherwise
only devices not already connected), runs the existing serial admission and
`_detectDevice` logic, and connects only supported `De1Interface` machines.
Scales, sensors, debug ports, and arbitrary USB devices are rejected with
full transport cleanup. The typed result distinguishes connected / nothing
supported / detected-but-failed, plus "probe unavailable" when the
originating service lacks the capability — which falls back to the legacy
preferred-machine connect policy.

The central distinction: preferred-machine policy controls passive automatic
discovery; physically attaching a supported USB machine is explicit connection
intent. On a probe-capable scanner, `ConnectionManager` runs the probe ahead of
any preferred-machine scan — no preference, a stale BLE preference, another
USB preference, or a simulated preference are all overridden by the attached
machine, and the machine's USB ID becomes the preferred machine only after a
successful connection and adoption. Unsupported attachments change nothing;
failed attachments preserve the previous preference and return control to the
existing preferred-machine recovery policy (or surface the normal connection
failure). A connected machine is never replaced.

Attach attempts never run in parallel with another connect. An attach arriving
while an automatic/recovery connect is in flight supersedes that scan via the
existing generation mechanism and runs one coalesced probe as soon as the
ownership releases; explicit user scans and scale-only connects are waited
out. No BLE, Wi-Fi, simulated-device, or scale-only behavior exposes attach
events.

## Quick Connect

`tryQuickConnect` on `UniversalBleDiscoveryService` connects to a known
device by ID without scanning. GATT-133 (cold-boot Android, Teclast) is
handled by a single retry with a 1s delay inside `_connectWithRetry`:

```
await device.onConnect().timeout(10s)
  catch BleConnectException:
    wait 1s
    disconnect
    await device.onConnect().timeout(10s)  // one retry only
```

If both attempts fail, `tryQuickConnect` returns null and the scan fallback
runs. The `EarlyConnectWatcher` does its own retry during the scan.

On Apple (iOS/macOS), `getSystemDevices` is used to find the peripheral in
the system cache. If not cached, returns null immediately (no timeout waste).
A system-connected Apple peripheral must still go through `connect()` so
`universal_ble` attaches its native callbacks and CoreBluetooth delegate.
This call is idempotent for an existing link and does not start a second
physical connection. On Android/Linux/Windows, direct
`UniversalBle.connect(deviceId)` works.

The identity check happens during `onConnect()` — for machines, `v13Model`
is read and compared against the expected `DeviceImplementation`.

## Focused Tests

```sh
flutter test test/services/ble/
flutter test test/controllers/connection/
```

## Profile Upload Safety

### Firmware Latch: ProfileDownloadInProgress

The DE1 firmware sets `ProfileDownloadInProgress` on header write and clears it
on tail write + flash commit. If the upload dies mid-sequence (GATT timeout,
connection drop), the latch stays set indefinitely. While latched:
- The machine silently ignores all start requests.
- The group-head LED pulses magenta (~2 Hz).
- The only recovery is a complete profile upload.

### Two Cache Layers

| Cache | Location | Cleared on | Effect |
|-------|----------|------------|--------|
| Sync `_lastPushedProfile` | `WorkflowDeviceSync` | Disconnect, upload failure | Prevents redundant uploads within one connection |
| Device `_currentProfile` | `UnifiedDe1` | Every `onConnect()`, every upload start | Prevents redundant uploads within one device session |

Both must be cleared on connection edges. The sync cache is cleared by
`_onDe1Change(null)` which runs on disconnect. The device cache is cleared
in `UnifiedDe1.onConnect()` before the `_info` guard.

### Startup Ordering

The on-connect profile push is triggered by `De1Controller.initSettled`, which
fires after machine readiness + startup defaults complete. This replaces the
single-shot `_setDe1Defaults` path whose failures were swallowed.

Generation tokens in both `De1Controller` (`_connectionGeneration`) and
`WorkflowDeviceSync` (`_generation`) guard against stale init completions
from a disconnected generation.

## Keeping Notes Fresh

Add lessons that would have saved debugging time: new footguns, thread-safety constraints, connection-lifecycle changes, non-obvious symptoms, and cross-transport dependencies. Prune stale claims. Prefer fewer, sharper notes over long background.
