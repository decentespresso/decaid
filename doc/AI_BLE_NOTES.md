# AI BLE Notes

## Concurrent scale ownership

ScaleController remains the primary scale owner. Auxiliary scales are held by a
runtime registry keyed by device ID, with one physical device claim at a time.
Claims reserve IDs before asynchronous connect work, retain closing reservations
until subscriptions and transport cleanup settle, and release only the owning
session. Auxiliary sessions forward device snapshots independently and do not
feed shot or primary-scale state.

The primary policy filters auxiliary reservations from automatic and picker
selection. Explicit auxiliary connection is a separate intent and remains
available while automatic Bengle primary selection skips external scales.

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

This behavior depends on DE1 firmware. See
[`device-notes/de1.md`](device-notes/de1.md#usb-charger-deduplication).

## Footgun #4: Watch Scan Silent Death (fork SafeScanner)

**Symptom:** background scale watch armed (`Background device watch started` in the log) but the preferred scale never auto-connects; a manual scan connects it immediately. No error anywhere.

**Root cause (two mechanisms in the universal_ble fork's Android code):**
1. `SafeScanner`'s scan-frequency throttle (>5 starts/30s) silently swallows a start: the Dart call returns success while the real start is deferred via `handler.postDelayed`, and any `stopScan` in between cancels the deferral (`removeCallbacksAndMessages(null)`). Scan churn (bursts + watch pause/resume around machine reconnects) is the trigger.
2. `onScanFailed` is logged Kotlin-side and never surfaced to Dart, so a scan Android kills post-start is invisible.

**Fix:** `UniversalBleDiscoveryService` probes `UniversalBle.isScanning()` every 90s while the watch scan is believed running (`_armWatchLiveness`). Dead scan → teardown + restart through `_restartWatchOrReportFailure`, so a failing restart reports on `deviceWatchFailures` and `ScaleWatch` activates the legacy backoff. Probe errors fail open — an unprovable probe must not churn the session; ownership is re-checked after the await (a burst may have taken the session).

**Coverage limit:** `isScanning()` reflects SafeScanner's *host-side bookkeeping*, not adapter truth. Mechanism 1 is caught (bookkeeping never went true). Mechanism 2 is NOT (bookkeeping stays true after `onScanFailed`) — bounded by the 25-min refresh until the fork updates SafeScanner state in `onScanFailed` / emits a scan-state event (candidate fork follow-up).

**Field triage:** `ScaleWatch` logs sightings at INFO. `Background device watch started` with no `Preferred scale … sighted` → scan/screen problem (this footgun, or unfiltered-scan screen-off suspension). `sighted` with no connect → connect-path problem.

## Decent Scale / HDS Profile Negotiation (#839)

**Symptom:** An original full-height Decent Scale connects and streams weight, then drops with Android GATT 133 during a periodic write; repeated disconnects shortly after the DE1 enters sleep.

**Root cause:** `DecentScale` mixed the shared Decent protocol with HDS-only behaviour — unconditional HDS SoftSleep (`0A 04`), a LED/status write every other 4s maintenance tick, and a trailing heartbeat byte of `01` on tare while heartbeat support is disabled.

**Design:** identity is evidence, capabilities control behaviour. `profile.dart` holds `DecentScaleIdentity`, `DecentScaleCapabilities`, and pure frame parsers; a connection starts conservative and only widens on positive protocol evidence.

- A `0x0A` status response or a 10-byte timestamped weight frame identifies an original Decent Scale (the timestamped variant adds power off and drops the unreliable command buffer).
- Only a valid `0x22` voltage response promotes to HDS, and that alone grants extended commands and power off, not SoftSleep. HDS firmware v2.5.8 introduced `0x22` but SoftSleep only arrived in v2.6.3, so a voltage probe is not evidence of SoftSleep.
- SoftSleep is gated separately on trustworthy modern firmware: HDS identity plus a decoded firmware version with major `>= 3`. HDS firmware before 3.0.1 does not report a version at all, so those scales use the shared display-off command while staying connected, rather than risk a `0A 04` they may not understand.
- Display off, HDS SoftSleep, power off and BLE disconnect are separate. `ScalePowerMode.displayOff` never disconnects a healthy Decent Scale: original, unknown and pre-modern HDS scales all use the shared `0A 00` display-off command and keep weighing.
- Unidentified scales stay conservative: shared weighing/tare/timer and shared display-off only, never `0A 04`, never power off.

**Rules that came out of this:**

- Maintenance is read-only. No periodic LED/status writes; notification age alone drives re-subscribe (12s) and disconnect (20s).
- No heartbeat subsystem at all; every heartbeat-control byte is `00`.
- Negotiation is unawaited so `connected` is still published promptly. Evidence is guarded by a profile-attempt token that is bound into the notification callback and re-armed on every connect and wake, so a late status/voltage frame after sleep, or a stale initialization attempt, cannot promote capabilities on a newer connection. Connection ownership uses a separate connection-attempt token: a superseded `onConnect()` returns before it can cancel the live transport listener or the maintenance loop.
- Nonessential writes (LED/status, SoftSleep, power off) tolerate transient failures while notifications are still arriving; tare/timer still fail loudly.
- Sleep never intentionally disconnects a healthy link. `displayOff` sends the shared `0A 00` command and retains the connection; proven HDS SoftSleep is attempted first and falls back to `0A 00` on failure. A failed display-off write is logged and the connection kept - only the transport watchdog tears down a genuinely dead link. Field report #874 showed the old disconnect-on-sleep policy churning a healthy original v1.1 scale after a 30-minute session.
- Wake restores the same physical connection: `0A 01` LED-on for display-off, `0A 04 00` plus `0A 01` for SoftSleep. Capabilities are re-established only on a genuinely new connection, never merely because the display was toggled.
- The 50ms duplicate write from the canonical de1app is applied only to profiles with the unreliable command buffer (7-byte weight frames).

**Firmware decode:** status byte 5 is decoded against `{0xFE: 1.0, 0x02: 1.1, 0x03: 1.2}` (the public `pydecentscale` client's table, consistent with the plan's `original-fw=0x02 -> fw=1.1` example). Only v1.0 needs the 50ms duplicate command; only v1.2 supports power off. A timestamped 10-byte weight frame independently proves v1.2+. An unrecognised marker stays conservative.

For modern HDS the same bytes 5-6 are a version: byte 5 is BCD (`majorTens << 4 | majorUnits`), byte 6 packs `minor << 4 | patch`. The low nibbles are raw 0-15, not decimal BCD digit pairs, so 3.1.14 legitimately arrives as `0x03 0x1E`. The 10-byte weight frame's `timestampMillis` is decisecond-resolution on the wire (`minute*600 + second*10 + decisecond`) and is scaled to milliseconds in the parser.

**Known gap:** the marker table comes from a third-party client, not from Decent firmware source. Sub-version labelling needs confirmation against the original full-height hardware before the duplicate/power-off gates are trusted in the field.

## Gone-Device Error Handling

`UniversalBleTransport._handleGattError()` catches `UniversalBleException` with gone-device codes:
`deviceNotFound`, `connectionTerminated`, `deviceDisconnected`, `unknownError`.

On hit: emits `disconnected`, drains the queue with typed `deviceDisconnected`, and throws `DeviceNotConnectedException`.

`characteristicNotFound` and `serviceNotFound` are ambiguous: a live peripheral
can omit an attribute, while a dead link can return the same error from a stale
cache. These codes throw `GattAttributeUnavailableException` and hand off to
`_probeAndDeclareIfDead()`, which asks the OS for the real link state.
`GattAttributeUnavailableException` extends `DeviceNotConnectedException`, so the lowest-level scale write
helpers that already catch `DeviceNotConnectedException` keep swallowing it: for a write, a stale-GATT
`characteristicNotFound` may still mean a dead link, and the asynchronous probe cannot retroactively change
the exception the caller already received.
Device implementations should still gate optional reads on `discoverServices()` rather than relying on the probe.
See [`device-notes/scales.md`](device-notes/scales.md#optional-gatt-attributes)
for the scale behavior that motivated this distinction.

The `isBenignFrameworkError()` filter in `crashlytics_error_filter.dart` suppresses these from `FlutterError.onError` — but scale-level catches at the write helper are defense-in-depth.

## Faulted Queue Recovery

Dart `Future.timeout()` does not cancel the native BLE Future. When a queued operation times out, universal_ble 2.2.1 faults that exact queue generation. The original caller receives `TimeoutException`; pending and newly submitted commands receive typed `operationCancelled` and are not dispatched.

`UniversalBleTransport._onOperationTimeout()` must never immediately clear this barrier. Recovery follows one of two safe paths:

1. Poll payload-free queue diagnostics. Once `activeOperations == 0`, clear the faulted generation with `clearQueueWithError(... operationCancelled)`; the next command creates a clean generation.
2. If the native operation is still unresolved after the 2-second grace period, request an unqueued `disconnect()`. Keep the queue faulted unless the native disconnect event confirms teardown; `UniversalBle.disconnect()` swallows timeout/failure, so its returned Future is not confirmation. The native event clears with `deviceDisconnected` and starts the normal reconnect cascade.

A queue can produce only one wrapper timeout per faulted generation; followers are cancelled rather than dispatched. Therefore the old "three consecutive operation timeouts" policy is invalid under 2.2.1. The bounded unresolved-operation grace period is now the dead-link policy. Recovery tasks and asynchronous OS probes carry the transport connection generation so late completion from an old connection cannot clear a replacement queue or emit stale state.

`operationCancelled` means local queue recovery, never physical disconnect. It is benign Crashlytics noise. `deviceDisconnected` remains reserved for a confirmed or forced physical disconnect. The legacy `Exception('Queue Cancelled')` string sentinel is not part of the 2.2.1 path.

## Stale Disconnect vs Queued GATT Work

`universal_ble` installs an automatic per-device queue drain (`UniversalBle._wireQueueDrain`) that disposes a device's queue on every raw `isConnected == false` connection update. Decaid runs `QueueType.perDevice` (`universal_ble_discovery_service.dart`), so that drain is keyed on the same id as every queued Decaid GATT call: `BleCommandQueue.clearQueue` removes the queue and `Queue.dispose` completes every pending caller with `deviceDisconnected`.

A platform can publish that update late for a link that a newer connection attempt already re-established. `UniversalBleTransport._confirmDisconnect()` already probes the OS link before publishing the domain disconnect, but that probe cannot run early enough to protect queued callers: the dependency drains them in the same stream dispatch, and the rejected caller then reaches `_handleGattError()`'s gone-device branch and reports `disconnected`. Suppressing that later state does not restore the cancelled callers, so the destructive action has to be fixed at its owner.

Decaid therefore pins `universal_ble` on the unreleased commit `9c50e12fcc33b061fe37e7037c69e44e30d96c79` (a merge of `tadelv/universal_ble` `main` into `tadelv/universal_ble` PR #24). It confirms the authoritative link state before draining and holds the device queue while that confirmation is in flight, so a genuine disconnect still cancels pending commands before the next one can dispatch. The hold is owned by the newest confirmation for that device: `connected` or `connecting` releases it, an inconclusive confirmation clears it, a queue created while the hold is live starts held, and a superseded confirmation can neither resume nor clear. Releasing a live-link hold resumes dispatch only once the active command has completed, so a confirmed stale disconnect cannot run two commands on the same device at once. Re-pin to a released tag once that change lands.

`test/universal_ble_transport_recovery_test.dart`, group `stale disconnect vs queued GATT work`, guards the Decaid side of that contract: a stale update must leave the in-flight and queued writes alive with the queue still `running`, confirming the stale update as connected must not dispatch the queued write while the in-flight write is still running, a genuine disconnect must still cancel exactly once and publish exactly one `disconnected`, and a genuine disconnect whose link probe is still pending must hold queued work instead of dispatching it.

## Plugin Connection Deadlines

A host-bound BLE plugin device connects in two phases. `PluginProtocolDevice.prepareConnection` establishes the physical BLE session and `PluginBleBinding` owns admission, claim reservation and `session.connect()` there; only then does the plugin's own `connect` handler run, and only then does `invocationTimeout` bound protocol startup and readiness.

The split exists because platform acquisition and recovery are transport policy: a slow Android connect, a BlueZ cache-refresh retry, or an MTU negotiation can legitimately outlive any budget a plugin timeout would pick, and killing them there reports a healthy recovery as a plugin failure. Raising the plugin timeout instead would only move the same ownership error and weaken the bound on a stalled plugin, so the phases stay separate. Cancellation or disposal in either phase must settle without publishing `connected` and must retire the physical session the attempt prepared, even when the logical session was already cleared.

A plugin that creates a first-packet readiness promise must attach its own rejection handler when it creates it. Startup can fail before that promise is awaited, and a later disconnect or silence watchdog would otherwise reject an unobserved promise. The Bookoo reference plugin and `scripts/test_bookoo_readiness_rejection.mjs` show the pattern and its regression.

## BLE Scanning

- Device discovery uses unfiltered scans with name-based matching (`DeviceMatcher`).
- Service verification during `onConnect()` via `BleServiceIdentifier`.
- `ScanStateGuardian` guards against overlapping scans and tracks adapter state.
- `ScanOrchestrator` manages single-scan lifecycle.
- Discovery owns cache state, not native connection teardown. Duplicate advertisements preserve unknown, discovered, connecting, and disconnecting devices. A connected cache entry is replaced only after identity-fenced Dart and native rechecks confirm it is stale; the final identity/Dart recheck runs after the last native probe with no await before cache removal. Replacement never calls native disconnect.
- Cache disconnect listeners are device-instance-fenced so an older generation cannot evict its replacement.

## Sleep From NeedsWater (Refill State)

This behavior is firmware-specific. See
[`device-notes/de1.md`](device-notes/de1.md#sleep-from-refill-state).

## Comms-Layer Patterns

An awake Decent Scale connection requires a recognised FFF4 status or weight frame after subscription and a status request. Two seconds of silence triggers one immediate re-subscribe and status request; a second silent window tears down the transport without sending the physical power-off command so ConnectionManager owns the next reconnect. A deliberately sleeping reconnect only restores the subscription while remaining dark and defers the same readiness probe until wake.

Acaia parsing is frame-bounded. Payload lengths above 64 bytes and impossible lengths for known settings or weight events trigger header resynchronization; complete unsupported frames are consumed whole so embedded `EF DD` bytes cannot become top-level frames. Only accepted settings, weight, or timer frames refresh liveness. Event 11 selector 5 carries weight, while selector 7 is timer data. Connection readiness requires a decoded valid weight rather than an arbitrary notification.

AtomHeart Eclair uses service `B905EAEA-2E63-0E04-7582-7913F10D8F81`, data/status characteristic `AD736C5F-BBC9-1F96-D304-CB5D5F41E160`, and command characteristic `4F9A45BA-8E1B-4E07-E157-0814D393B968`. Its connection remains `connecting` until a valid checksummed `0x57` weight frame arrives. Silence for 800 ms resets the notification subscription at most twice; a third silent window tears down the transport so ConnectionManager owns recovery. Timer reset/start/stop commands are `520101`, `530101`, and `450101`; tare remains `540101`.

Eclair battery notifications use the command characteristic. Current firmware sends the 3-byte frame `42 <level> <xor>`, while legacy firmware may send the 5-byte frame `42 <level> <reserved> <reserved> <xor>`. In both forms, the XOR covers every payload byte between the header and checksum, and the first payload byte is the battery percentage from 0 through 100.

A readiness gate that only reports "timed out" cannot be diagnosed from a user log. The Eclair connect timeout names how many notifications arrived and the last frame that failed validation, which separates a dead subscription (zero notifications, a CCCD or GATT problem) from a frame format the parser rejects (notifications arriving, none accepted). Issue #629 was closed without a root cause for want of exactly that distinction.

A characteristic advertises write-with-response, write-without-response, or both, and the requested type must match. CoreBluetooth rejects a mismatch locally, before any radio traffic: universal_ble surfaces `characteristicDoesNotSupportWrite` or `characteristicDoesNotSupportWriteWithoutResponse` in single-digit milliseconds. The Eclair command characteristic is write-with-response only on current firmware, so every `540101` tare issued as write-without-response failed instantly (issue #780). `AtomheartScale` therefore issues its commands with response; the device contract belongs at the caller.

The two ATT write procedures are not equivalent, so the transport never substitutes one for the other freely. A write request is acknowledged and has a server error path; a write command is not and does not. `UniversalBleTransport.write` retries in one direction only: a write the caller asked to send unacknowledged that the platform rejects for its property is retried once with response, which adds an acknowledgement the caller did not ask for but never removes one it did. A rejected write-with-response is surfaced as-is, never downgraded.

The retry cannot duplicate a command. Darwin, Android, and Windows all validate the requested property against the GATT database and return the error before dispatching anything to the radio, so a rejected write never reached the device. BlueZ does not report these codes at all and never enters the retry path. A write that the platform accepts is issued exactly once, with the property the caller asked for.

`_handleGattError` must log before it rethrows. An unmapped `UniversalBleException` used to escape silently, which is why #780 reached the tracker as a bare HTTP 500 with no cause anywhere in the log. REST handlers that turn an exception into a 500 body must log it too; a response body the user never sees is not evidence.

The Eclair weight frame is fixed at exactly 10 bytes: `0x57` header, four little-endian weight bytes in milligrams, four timer bytes, and one XOR checksum over bytes 1 to 8. Accept only that exact width. A shorter frame makes the last payload byte double as the checksum, so `57 00 00 00 00 00 00 00 00` would otherwise XOR-validate as a zero-weight snapshot and satisfy the readiness gate.

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

See [`device-notes/de1.md`](device-notes/de1.md#mmr-model-mapping).

## Focused Tests

```sh
flutter test test/services/ble/
flutter test test/controllers/connection/
```

## Profile Upload Safety

See [`device-notes/de1.md`](device-notes/de1.md#profile-upload-safety).

## Plugin BLE Binding (#809 Checkpoint)

Bookoo's opt-in JS reference lives under `examples/plugins/bookoo-mini.reaplugin`.
Shared native/plugin byte fixtures are in `test/helpers/bookoo_packets.dart`.
The driver's valid-packet silence deadline is two seconds, a provisional protocol
health policy pending hardware cadence measurements, not a native GATT timeout.

Notification provenance is captured before JS dispatch. An optional opaque token
round-trips through the callback and publication; host validation supplies the
Scale timestamp. Four-event/100 ms trace tests reproduced collapsed timestamps
without it. Keep the two-second expiry aligned with shot freshness, retain bounded
session ownership, and measure arrival delay separately from timestamp quality.

`PluginBleBinding` reserves the physical ID before transport creation and owns a
fresh `PluginBleSession` per connect. Factory metadata has no mutable publication
target: all publication and GATT closures capture a session capability. Do not
move those closures onto a persistent factory object when adding Scale protocols.

Expose the domain session only after `PluginBleSession.connect()` succeeds. Android
GATT-133 can emit a disconnect event before the native connect Future reports its
error; exposing the domain session earlier lets terminal cleanup cancel the domain
connect and masks the actionable BLE error as `stale_session`. The Scale debug view
owns connect failures and lets the user retry the same binding without rescanning.

Retirement and native teardown are different boundaries. The session fences normal
operations immediately, permits only bounded cleanup reads/writes, then awaits
`disconnectConfirmed`. If confirmation times out, retain the physical claim. A
caller-facing timeout must never imply that the native link has closed.
`BleAdmissionTransport` applies the same physical exclusion to native candidates;
discarding a candidate which never reserved ownership must not disconnect another
owner's link.

Plugin arbitration uses the native cache's identity-fenced eviction and adoption
helpers. Cache eviction never disconnects a native candidate. Plugin candidate
retirement rechecks binding occupancy and physical claims after asynchronous
listener cancellation; active or unconfirmed-teardown bindings remain owned.

Discovery records whole observations before its native empty-name gate. System
metadata is incomplete; it cannot erase complete advertisements. Observations
arriving during async candidate creation are replayed and admission rechecks the
current registry/evidence. Watch filter changes use the existing scan owner rather
than a second scanner. Initial loader settlement gates native fallback.

Every scan-generation advance also resets evidence, observations, ownership
decisions, and queued observation work. Watch stop and adapter recovery are
generation boundaries too; otherwise fresh Apple quick-connect system evidence
is rejected by the previous cache generation.

Real-JS integration fixtures are in `test/plugins/plugin_manager_ble_test.dart`,
`plugin_ble_native_bridge_test.dart`, and `plugin_ble_sensor_api_test.dart`. The
last drives actual HTTP/WebSocket clients through DeviceController, SensorController,
the JS bridge, and a fake GATT edge. Native bridge coverage uses
UniversalBleTransport to prove CCCD reset and write-property error behavior.
These checks do not replace hardware or Scale timing acceptance.
## Skale firmware metadata

Skale exposes its revision through the standard Device Information Service
Firmware Revision String (`0x180A` / `0x2A26`). Treat it as opaque,
connected-session metadata such as `R029`: discover the optional service before
reading, decode strict UTF-8, ignore empty/malformed values and read failures,
and fence the result by connection generation so a late read cannot repopulate
metadata after disconnect or reconnect.

Atomax does not publish a firmware update contract, so Decaid displays the
revision only and does not infer update availability or implement Skale DFU.

## Firmware Update: Erase/Verify Poll Fallback

Some DE1 firmwares never emit the terminal firmware-map notification after erase
or after verify. The old flow awaited that notify alone, so an update on such a
machine timed out near completion even though the flash had finished.

`UnifiedDe1Firmware._waitForFirmwareResponse` now races the existing notify
future against `_pollFirmwareResponse`, which re-reads `fwMapRequest`
(`Endpoint.fwMapRequest` / A009 / `[I]`) every 250 ms until a terminal response
matches the stage predicate. Whichever arrives first wins. Firmware that does
notify completes exactly as before; the poll simply loses the race.

Terminal frames are 7 bytes: window, erase, map, then three error bytes. Erase
is terminal only for `window=0, firmwareToErase=0, firmwareToMap=1` with error
`ff ff ff`. During verify, that same `ff ff ff` error is pending/non-terminal;
with the same first three fields, every other error tuple is terminal. `ff ff fd`
is success, while `ff ff 01` is a terminal failure.

### Both transports need a FRESH read

`UnifiedDe1Transport.readFwMapRequestFresh` exists because the serial normal
read path is cached, while BLE's public `read()` does make a fresh GATT read but
is unsuitable here: timeout recovery may disconnect and reconnect mid-update.

On **serial**, `_serialRead` hands back the last pushed `[I]` frame, which never
changes once the firmware stops emitting the notify. `fwMapRequest` is already
continuously `<+I>`-subscribed, and the firmware treats an add-notify as a
force-update, so re-sending `<+I>` provokes a fresh `[I]`. Do not send the
matching `<-I>` the way `_serialSingleNotifyRead` does: dropping the continuous
subscription mid-update would blind the notify path that a stock DE1 still
relies on.

The read arms on the NEXT `[I]` frame before it provokes one. The subject
replays its current value to a new listener, so the read skips one value - but
only when the subject holds one. The subject is no longer seeded upstream, so an
unconditional `skip(1)` would swallow the very frame the first poll of a
connection provoked, and that read would time out.

On **BLE**, a genuine GATT read of A009 returns the current value, but it must
go through `_bleRead` rather than the public `read()`. `read()` recovers from a
timeout with a disconnect and reconnect. This poll fires repeatedly across the
flash-busy erase and verify windows, and tearing the link down mid-update would
corrupt the in-flight firmware write. A failed poll read throws instead; the
loop logs it and retries on the next cadence tick.

### Timeout bounds

| Bound | Value | Purpose |
|---|---|---|
| `_firmwareMapPollInterval` | 250 ms | Poll cadence. |
| `_firmwareMapPollReadTimeout` | 2 s | Per-read bound, so one stalled read cannot hang the loop. |
| `firmwareEraseTimeout` | 60 s | Whole erase stage. |
| `firmwareVerificationTimeout` | 120 s | Whole verify stage. |

The stage bounds were 30 s each. On-device erase and verify of a larger image
can outlast 30 s while the machine emits only non-terminal frames, which tripped
the outer timeout near completion. The stage bound is the only limit on the
poll loop, so raising it grants more poll iterations and nothing else. A
genuinely stuck erase still fails.

Skale battery metadata uses the standard Battery Service (`0x180F`) and Battery
Level characteristic (`0x2A19`). The value is optional device-reported metadata:
only one-byte values from 0 through 100 are accepted. Failed, empty, malformed,
or out-of-range reads clear the current value and do not fail the connection.
Reads run on connect and on an injected 30-minute timer, with a single in-flight
read and connection-generation fencing to prevent stale values after disconnect
or reconnect. Historical de1app evidence reports fixed `100%` values on some
Atomax firmware generations, while the observed R029 unit reports changing
values, so the app must preserve the device value rather than manufacture a
fallback percentage.

## Keeping Notes Fresh

Add lessons that would have saved debugging time: new footguns, thread-safety constraints, connection-lifecycle changes, non-obvious symptoms, and cross-transport dependencies. Prune stale claims. Prefer fewer, sharper notes over long background.
