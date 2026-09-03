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

## Terminal Lifecycle Teardown

`AppLifecycleObserver` treats `detached` and `didRequestAppExit()` as best-effort terminal events. It cancels its state subscriptions, awaits `ConnectionManager.shutdown()`, then disposes the plugin loader before the app-log upload service. Shutdown rejects new connection work, stops discovery and recovery sources, releases queued requests, waits for in-flight work, then disconnects the machine and scale in order while isolating cleanup failures. `paused` and `hidden` preserve active connections.

Android does not guarantee any Dart, activity, application, or Flutter-engine callback for Settings Force stop, SIGKILL, or other abrupt process death. Those paths can skip cleanup entirely and must not be described as supported. Decaid still pins `universal_ble` 2.2.6, whose Android `onDetachedFromEngine()` does not close active central GATT clients, so native engine-detach cleanup is not shipped with this lifecycle change.

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
These two codes now log, throw the domain `GattAttributeUnavailableException`, and hand off to
`_probeAndDeclareIfDead()`, which asks the OS for the real link state and only then declares the link dead.
`GattAttributeUnavailableException` extends `DeviceNotConnectedException`, so the lowest-level scale write
helpers that already catch `DeviceNotConnectedException` keep swallowing it: for a write, a stale-GATT
`characteristicNotFound` may still mean a dead link, and the asynchronous probe cannot retroactively change
the exception the caller already received.
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

AtomHeart Eclair uses service `B905EAEA-2E63-0E04-7582-7913F10D8F81`, data/status characteristic `AD736C5F-BBC9-1F96-D304-CB5D5F41E160`, and command characteristic `4F9A45BA-8E1B-4E07-E157-0814D393B968`. Its connection remains `connecting` until a valid checksummed `0x57` weight frame arrives. Silence for 800 ms resets the notification subscription at most twice; a third silent window tears down the transport so ConnectionManager owns recovery. Timer reset/start/stop commands are `520101`, `530101`, and `450101`; tare remains `540101`.

The Eclair weight frame is fixed at exactly 10 bytes: `0x57` header, four little-endian weight bytes in milligrams, four timer bytes, and one XOR checksum over bytes 1 to 8. Accept only that exact width. A shorter frame makes the last payload byte double as the checksum, so `57 00 00 00 00 00 00 00 00` would otherwise XOR-validate as a zero-weight snapshot and satisfy the readiness gate.

Timemore Dot uses service `FFF0`, weight notifications on `FFF1`, and commands on `FFF2`. Frames are `A5 5A`-framed with a length field, payload, and two-byte tail (total = payloadLen + 8, max payload 64). Weight frames (opcode 0x01/0x02, cmdId 0x01) carry a signed big-endian int32 at payload offset 0 in 0.1 g resolution and the running timer in seconds at offset 6; battery frames (cmdId 0x05) report a percentage in payload byte 1 (fallback byte 0). Sending commands requires CRC16/MODBUS (reflected poly 0xA001, init 0xFFFF, no final XOR): the reference ESP32 driver's comment claims CRC16/IBM with init 0x0000, but its own verified command bytes only reproduce with init 0xFFFF — `timemore_dot_protocol_test.dart` asserts byte-equality against all seven verified command frames so a "correction" to init 0x0000 fails loudly. Notification frames, however, are NOT CRC-validated: captures from a physical Dot show the two-byte tail stays `00 00` across every weight/timer value, i.e. the firmware's notify path never computes a real CRC (the verified reference driver likewise skips CRC checking). The parse loop mirrors the driver's resync: drop one byte until `A5 5A` magic, drop one byte when the length field exceeds 64, wait for more data on an incomplete frame, and consume-and-skip on a malformed frame; the buffer is capped at 256 bytes (drop-oldest) so a glitched stream cannot grow without bound. The scale only reports weight after the unit/mode init commands, so connect() sends subscribe → 500 ms → unit=gram → 200 ms → mode=standard → 100 ms → battery request, tolerating individual init-write failures (logged, connect still completes; the next reconnect retries). Command writes use `withResponse: false` (the Dot ACKs over FFF1 notifications, matching skale2/atomheart precedent). Detection matches advertised names containing `dot` or `tes017` (case-insensitive); because the Dot can advertise the FFF0 service with no name at all outside pairing mode, nameless advertisements carrying FFF0 are also matched via `DeviceMatcher.advertisesKnownService` — the FFF0 service check in `onConnect` rejects false positives from any other device whose name contains "dot". The `dot` substring rule is deliberately narrow (no collision with existing matcher rules) and must be kept before the Acaia contains-block.

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

USB intent is latched on the attach event, before the 500 ms settle delay, and
automatic preferred-machine selection is paused while latched:
`AttachReconnectCoordinator.onLatched` cancels the machine reconnect timer and
supersedes an in-flight automatic/adapter-recovery attempt (generation bump +
`stopScan`). Automatic connects are refused at `connectMachine` and deferred at
`_executeConnect` while latched; explicit direct connects, explicit scans, and
scale-only work are untouched. The `_activeAutomaticMachineAttempt` gate
requires an active `_isConnecting` operation with automatic/adapter-recovery
intent, so the sticky default status intent cannot misclassify a direct REST or
picker connect. A machine connected by the superseded attempt inside the
settle window is released through the intentional `disconnectMachine()` path
(both the tracked-connect and remembered quick-connect routes) before the
queued probe runs, so a BLE connect that finishes mid-window cannot win.
`_shouldAttemptAttachReconnect` treats that transient machine as
not-established so settle expiry queues the attach instead of skipping it. A
single completion helper clears the latch, consumes the supersession marker,
and resumes whatever the latch interrupted — replaying a deferred automatic
connect or re-arming recovery.

Startup ordering matters: `ConnectionManager` (and the coordinator
subscription) is constructed before onboarding initializes `DeviceController`,
and `DeviceController` subscribes to each service's attach stream before
awaiting its `initialize()`. `SerialServiceAndroid.initialize()` therefore
emits one metadata-free startup hint for a non-empty enumeration, and the hint
flows through the existing latch → settle → probe → adopt path before the
onboarding scan step calls `connect()`.

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

### Cross-listener ordering after adopt (PR #746)

`De1Controller.adoptDevice()` emits exactly one event on the `de1` stream
when replacing an already-connected device — no interim null — so
`DisconnectSupervisor` has nothing to misread as a disconnect. Do not
"flush" the supervisor with a fresh `de1.firstWhere(...)` subscription
instead: the `de1` stream is a default-async `BehaviorSubject` (async
broadcast), and Dart gives no delivery-ordering guarantee across
independently scheduled listeners, so the fresh subscription can see the
new device while the supervisor's own listener still has the earlier
value queued. When a caller must know the supervisor has caught up
(e.g. `_tryQuickConnectMachine` reading `_machineConnected` right after
adopt), use `DisconnectSupervisor.waitForMachine(deviceId)` — it resolves
from inside the supervisor's own pre-existing listener, so ordering is
correct by construction.

## DE1 MMR model mapping (`DecentMachineModel`)

`v13Model` (MMR `0x0080000C`) is the machine model read on connect. For the
DE1 family the raw value is 0 (unset) through 7, per de1app:

| value | model     |
|-------|-----------|
| 0     | Unknown   |
| 1     | DE1       |
| 2     | DE1+      |
| 3     | DE1PRO    |
| 4     | DE1XL     |
| 5     | DE1CAFE   |
| 6     | DE1XXL    |
| 7     | DE1XXXL   |
| >=128 | Bengle    |

The 5/6/7 rows were previously collapsed to DE1XXL/DE1XXXL/Unknown. The
corrected mapping matches the firmware values used by de1app and is the
canonical conversion for both raw MMR reads (`DecentMachineModel.fromInt`)
and API SKU parsing (`parseSkuModel`), so firmware values and SKU tokens
agree. Bengle values (>= 128) are outside the legacy DE1 identity-resolution
flow.

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

### shotSettings Never Arrives (gh-634)

`UnifiedDe1Transport._shotSettingsSubject` is an unseeded `BehaviorSubject`. It
is seeded by the connect-time characteristic read; if that read fails, the
subject stays empty for the whole connection and `shotSettings.first` never
completes.

Every steam and hot-water write reads the current `De1ShotSettings` first, so an
empty subject used to hang the write forever. That hang propagated outward: the
`De1Controller` device-write queue never advanced, and every later
`PUT /api/v1/workflow` sat behind it until the 30 s queue wait expired with 503.
Field symptom was "steam duration change does nothing" - the DE1 kept running on
its firmware value while the app reported an error 30 s later.

Guards now in place:
- `De1Controller._readShotSettings` bounds every read with
  `ConnectionTimings.initialShotSettingsTimeout` and maps a closed subject
  (`StateError`) to `DeviceNotConnectedException`.
- A connect-time read timeout no longer skips startup defaults permanently.
  `_deferStartupDefaults` re-arms on the first frame that does arrive, so a
  transient MMR timeout at connect no longer leaves the machine unconfigured
  until app restart. The deferred defaults run through `runDeviceWrite`, so
  they cannot overlap a normal workflow write that started while init was
  still waiting on shot settings.

No generic stall timeout guards the device-write queue. `Future.timeout()` does
not cancel the underlying future, so releasing the queue on timeout would let a
stalled write resume later and overwrite a newer one. Bound the actual
unbounded read instead; a real anti-wedge mechanism needs explicit
cancellation or fencing.

## Keeping Notes Fresh

Add lessons that would have saved debugging time: new footguns, thread-safety constraints, connection-lifecycle changes, non-obvious symptoms, and cross-transport dependencies. Prune stale claims. Prefer fewer, sharper notes over long background.
