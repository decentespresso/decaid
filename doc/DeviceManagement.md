# Device Management in Decaid

This document explains how devices (DE1 machines, scales, sensors) are discovered, connected, and managed throughout the Decaid application lifecycle.

## Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [Discovery Services](#discovery-services)
3. [Device Controller](#device-controller)
4. [Connection Manager](#connection-manager)
5. [Device-Specific Controllers](#device-specific-controllers)
6. [Connection Flow](#connection-flow)
7. [State Management](#state-management)
8. [Adding New Devices](#adding-new-devices)

---

## Architecture Overview

Decaid uses a layered architecture for device management:

```
┌─────────────────────────────────────────────────────────┐
│                    Application Layer                     │
│        (UI, API Handlers, De1StateManager)              │
└─────────────────┬───────────────────────────────────────┘
                  │
┌─────────────────▼───────────────────────────────────────┐
│              Connection Manager                          │
│   Orchestrates scan → connect policy (preferred devices)│
└─────────────────┬───────────────────────────────────────┘
                  │
┌─────────────────▼───────────────────────────────────────┐
│              Controller Layer                            │
│   De1Controller  │  ScaleController  │  SensorController│
└─────────────────┬───────────────────────────────────────┘
                  │
┌─────────────────▼───────────────────────────────────────┐
│              Device Controller                           │
│   Coordinates discovery services and device stream      │
└─────────────────┬───────────────────────────────────────┘
                  │
┌─────────────────▼───────────────────────────────────────┐
│           Discovery Services Layer                       │
│   UniversalBle (BLE)  │  Serial  │  Simulated           │
└─────────────────┬───────────────────────────────────────┘
                  │
┌─────────────────▼───────────────────────────────────────┐
│              Transport Layer                             │
│        BLE Transport  │  Serial Transport               │
└─────────────────┬───────────────────────────────────────┘
                  │
┌─────────────────▼───────────────────────────────────────┐
│               Device Layer                               │
│        De1  │  Scales  │  Sensors  │  Mock Devices     │
└─────────────────────────────────────────────────────────┘
```

**Key Principles:**
- **Transport Abstraction:** Devices depend on injected transport interfaces, not concrete implementations
- **Constructor Dependency Injection:** All dependencies passed through constructors
- **Single Responsibility:** Each layer has a clear, focused purpose
- **Reactive Streams:** RxDart BehaviorSubjects for state broadcasting

---

## Discovery Services

Discovery services are responsible for scanning and creating device instances. Each service handles a specific transport type.

### Available Services

#### 1. UniversalBleDiscoveryService
- **Platform:** All (Android, iOS, macOS, Windows, Linux)
- **Package:** `universal_ble` (native backends on mobile/Windows/macOS; pure-Dart BlueZ backend on Linux)
- **File:** `lib/src/services/universal_ble_discovery_service.dart`
- **Discovery:** Unfiltered BLE scan + name-based matching (`DeviceMatcher`); also queries system/bonded devices (`getSystemDevices`) for CoreBluetooth/BlueZ. Apple devices returned as system-connected must still go through `connect()` so `universal_ble` attaches native callbacks and its CoreBluetooth delegate; this is idempotent and does not start a second physical connection. Single BLE stack on every platform since the flutter_blue_plus → universal_ble consolidation (see `doc/plans/archive/ble-universal-ble-migration/`).
- **Linux/BlueZ note:** `UniversalBleTransport` applies BlueZ-specific connect handling on `Platform.isLinux` (stop scan + settle before connect to avoid `le-connection-abort-by-local`, post-connect settle, `discoverServices` retry) — without it the DE1 cold connect fails with "Failed to resolve services".

#### 2. SerialService
- **Platform:** Desktop (macOS, Linux, Windows), Android (USB OTG)
- **Files:**
  - `lib/src/services/serial/serial_service_desktop.dart` (desktop)
  - `lib/src/services/serial/serial_service_android.dart` (Android)
  - `lib/src/services/serial/serial_service.dart` (factory)
- **Discovery:** Enumerates serial ports, probes for device identification
- **Device protocols:** See [`device-notes/de1.md`](device-notes/de1.md),
  [`device-notes/bengle.md`](device-notes/bengle.md), and
  [`device-notes/scales.md`](device-notes/scales.md).

### Bengle firmware-synced state (post-connect)

See [`device-notes/bengle.md`](device-notes/bengle.md).

#### 3. SimulatedDeviceService
- **Platform:** All
- **File:** `lib/src/services/simulated_device_service.dart`
- **Purpose:** Testing without physical hardware
- **Activation:** Set `simulate=1` compile-time variable or enable in settings

#### 4. WifiScaleDiscoveryService
- **Platform:** All (Android, iOS, macOS, Windows, Linux)
- **Purpose:** Discovers WiFi Half Decent Scales.
- **Protocol and platform details:** See
  [`device-notes/scales.md`](device-notes/scales.md#decent-scale-and-half-decent-scale).

### Device Matching

Discovery services use name-based matching via `DeviceMatcher` to create appropriate device instances from BLE advertisement names:

**File:** `lib/src/services/device_matcher.dart`

**Key Points:**
- Unfiltered BLE scans — no service UUID filtering
- `DeviceMatcher.match()` takes a transport and advertised name, returns a `Device?`
- Name rules map advertisement names to device factories
- Service verification happens during `onConnect()` using `BleServiceIdentifier`
- Named sensor matching details live in
  [`device-notes/sensors.md`](device-notes/sensors.md).

### Service Lifecycle

1. **Initialization:** `service.initialize()`
   - Set up platform-specific scanning
   - Initialize internal state
   - Start listening to platform events

2. **Scanning:** `service.scanForDevices()`
   - Start platform-specific scan
   - Match discovered devices to mappings
   - Create device instances via factories
   - Emit devices via stream

3. **Device Stream:** `service.devices`
   - Broadcast stream of discovered devices
   - Updates when new devices found or existing devices disconnect

### Android USB attach recovery

`DeviceAttachNotifier` is an optional discovery-service capability.
`SerialServiceAndroid` emits an edge-only, non-replaying hint for every
`ACTION_USB_DEVICE_ATTACHED` broadcast. Incomplete Android metadata is allowed:
the notification only says that scanning may now find something, while serial
detection remains responsible for deciding whether the USB device is supported.
Detach and unknown USB actions do not emit attach hints.

`DeviceController` aggregates notifier streams without adding attach events to
the required `DeviceScanner` interface. A scanner exposes attach hints only when
it also implements `DeviceAttachNotifier`, so BLE, Wi-Fi, and simulated scanners
remain unchanged. It subscribes to each service's attach stream before awaiting
that service's `initialize()`, so an attach hint emitted from inside
initialization (such as the serial service's startup enumeration hint) is not
lost.

`AttachReconnectCoordinator` owns the attach subscription, configurable 500 ms
settle timer, burst coalescing, in-flight guard, and disposal. Disposal waits
for an in-flight attempt before `ConnectionManager` tears down its
dependencies. The delay lets Android's CDC interface become usable after the
earlier attach broadcast.

`UsbAttachProbe` is a second optional capability for the originating serial
service. `SerialServiceAndroid.connectAttachedMachine` correlates the attach
event with a newly listed USB device (by stable ID when Android supplied one,
otherwise only devices not already connected), runs the normal serial admission
and detection, and connects the device only when it is a supported machine
(`De1Interface`). Scales, sensors, debug ports, keyboards, and other USB
devices are rejected and their transports disposed. The typed result
distinguishes a connected machine from "no supported machine attached" from
"machine detected but connection or identity initialization failed". When
the originating service only implements the notifier (no probe capability),
the result is "probe unavailable" and the legacy preferred-machine policy
runs instead.

When the scanner implements `UsbAttachProbe`, a physical USB attachment is
explicit connection intent and wins over passive preferred-machine policy:
`ConnectionManager` runs the probe ahead of any preferred-machine scan,
adopts the connected machine, and persists its USB device id as the preferred
machine. A stale BLE preference, a different preferred USB machine, a
simulated preference, or no preference at all are all overridden by the
physically attached machine; no BLE scan runs and no machine picker opens.

USB intent is latched as soon as the attach event is received, not at settle
expiry. `AttachReconnectCoordinator.onLatched` arms while `ConnectionManager`
pauses passive automatic selection: the machine reconnect timer is cancelled,
and an in-flight automatic/adapter-recovery attempt is superseded through the
scan-generation mechanism and `stopScan()`. While latched, automatic machine
connects are refused at `connectMachine()` and deferred at `_executeConnect`;
explicit direct connects, explicit scans, and scale-only work are not
interrupted. A machine that an already-superseded automatic attempt connects
inside the settle window is released through the intentional disconnect path
before the queued probe runs, so the USB machine cannot lose the race to a BLE
connection that completes mid-window.
An attached machine that fails to connect preserves the previous preference
and returns control to the existing preferred-machine recovery policy (or
surfaces the normal machine-connection failure when no preference exists).
Unsupported or uncorrelated attachments change nothing — no scan, no picker,
no preference update, and an already scheduled recovery attempt is left
alone. A machine that is already connected is never replaced; the attach
attempt re-checks before executing. When the latch pauses an interrupted
automatic connect or recovery attempt and the probe does not adopt a machine,
the interrupted automatic policy resumes (recovery re-arms its reconnect
timer, or the deferred automatic connect replays) once the latch clears.

When the probe capability is unavailable (a notifier-only scanner, or a
`DeviceController` whose originating service cannot probe), the original
behavior applies: a preferred machine must exist, and the normal
`ConnectionManager.connect()` policy (remembered-device quick-connect and
scan fallback) runs, with machine recovery explicitly re-armed after an
unsuccessful attempt.

An attach event arriving while another connection operation owns the connect
guard is queued as one coalesced probe; in-flight automatic/recovery scanning
is superseded through the existing scan-generation mechanism, while explicit
user scans and scale-only connects are waited out. The queued probe runs
before other drained work, re-checks that no machine connected meanwhile, and
never runs in parallel with another connect.

At startup, `SerialServiceAndroid.initialize()` subscribes to the platform USB
event stream before enumerating (closing the list-versus-listener gap) and,
when enumeration finds devices, emits one metadata-free startup attach hint.
The hint reuses the latch → settle → probe → adopt path, so a supported USB
DE1 already attached before Decaid starts takes priority over a saved BLE
preference. One generic hint is deliberate: the coordinator keeps only the
latest burst event, and a null-id event makes the probe inspect all not-yet-
known USB devices; an unrelated keyboard or scale still resolves to
"unsupported" and the normal policy continues.

The original incident showed 20.3 seconds between USB enumeration and connection
because recovery was waiting for its backoff timer; the existing backoff can
reach 60 seconds. No improved hardware timing is claimed until the rebased path
is measured on Android hardware.

---

## Device Controller

**File:** `lib/src/controllers/device_controller.dart`

The DeviceController is the central coordinator for all device discovery services.

### Responsibilities

1. **Service Coordination:**
   - Manages multiple discovery services
   - Subscribes to each service's device stream
   - Merges devices from all services into unified stream

2. **Device Lifecycle:**
   - Tracks discovered devices
   - Removes disconnected devices on scan (allows re-discovery with fresh transport)
   - Prevents duplicate device entries

3. **Scan Management:**
   - Exposes `scanningStream` for scan lifecycle tracking
   - Coordinates parallel scans across all discovery services
   - Suppresses disconnect/reconnect detection during active scans — intermediate device list changes are transient noise. Genuine disconnects outside of scans are still detected.

**Note:** DeviceController does **not** handle connection policy. All connection decisions (which device to connect, when to connect) are handled by `ConnectionManager`.

### Key Methods

```dart
// Initialize all services
Future<void> initialize() async {
  for (var service in _services) {
    await service.initialize();
    _serviceSubscriptions.add(
      service.devices.listen((devices) => _serviceUpdate(service, devices))
    );
  }
}

// Trigger scan across all services
Future<void> scanForDevices() async {
  _scanningStream.add(true);
  // Scan all services in parallel
  await Future.wait(_services.map((s) => s.scanForDevices()));
  _scanningStream.add(false);
}
```

### Device Stream

The unified device stream combines all devices from all services:

```dart
Stream<List<Device>> get deviceStream => _deviceStream.asBroadcastStream();

List<Device> get devices => 
  _devices.values.fold(List<Device>.empty(growable: true), (res, el) {
    res.addAll(el);
    return res;
  }).toList();
```

---

## Connection Manager

**File:** `lib/src/controllers/connection_manager.dart`

The ConnectionManager is the centralized orchestrator for all device connection decisions. It replaces the previously scattered auto-connect logic that was spread across DeviceController, ScaleController, and De1StateManager.

### Connection Status

ConnectionManager exposes a `ConnectionStatus` stream driven by the
`ConnectionPhase` enum.

- **`idle`:** No connection activity
- **`scanning`:** BLE/USB scan in progress
- **`connectingMachine`:** Connecting to a DE1 machine
- **`connectingScale`:** Connecting to a scale
- **`ready`:** All requested devices connected

The status also tracks:
- `foundMachines` / `foundScales` — devices discovered during the last scan
- `pendingAmbiguity` — `machinePicker` or `scalePicker` when the UI needs to show a device selection dialog
- `intent` — automatic connection, explicit discovery, or scale recovery
- `activeTargetTransport` — transport of the selected device while connecting
- `conditions` — transport-scoped discovery conditions and affected device types
- `error` — error message from the last connection attempt

USB discovery continues while Bluetooth is unavailable. A Bluetooth condition
is shown as a nonblocking notice when a serial path remains viable, so serial
scanning, selection, and connection continue normally. It becomes blocking when
the current operation has only BLE candidates, such as BLE-only machine
selection or scale recovery. Selected-device connection failures remain visible
independently of discovery conditions.

#### Phase transitions

All phase writes route through `StatusPublisher.publish`. If a
transition isn't listed below, it's not supposed to happen.

```
                              ┌───────────────────┐
                              │ quick-connect path │ (machine-only)
                              │ idle → connMachine │
                              │       → ready      │
                              └───────────────────┘

                       ┌──────────────────────────────┐
                       │                              │
                       ▼                              │
   ┌─────┐         ┌──────────┐    ┌───────────────┐  │    ┌───────────────┐    ┌───────┐
   │idle │──scan──▶│ scanning │───▶│connectingMach.│──┴───▶│connectingScale│───▶│ ready │
   └─────┘         └──────────┘    └───────────────┘       └───────────────┘    └───────┘
      ▲                │                    │                       │                │
      │                │ error              │ error/no-match        │ error/no-scale │
      │                ▼                    ▼                       ▼                │
      │          (idle + error)       (idle + error / ready)   (ready / idle+err)    │
      │                                                                              │
      └──────────────────────────── disconnect ──────────────────────────────────────┘
```

Transition owners (where the `publish(phase: …)` call lives):

| Edge                                    | Owner                                                   |
|-----------------------------------------|---------------------------------------------------------|
| `idle → connectingMachine` (QC)         | `ConnectionManager._connectImpl` (before QC attempt)    |
| `connectingMachine → ready` (QC)        | `ConnectionManager._connectImpl` (after machine adoption)|
| `connectingMachine → scanning` (QC fail)| `ScanOrchestrator.runScan` (QC returned null)            |
| `idle → scanning`                       | `ScanOrchestrator.runScan`                              |
| `scanning → idle` (scan failure)        | `ScanOrchestrator._emitScanStartError`                  |
| `scanning → connectingMachine`          | `ConnectionManager.connectMachine` (policy stage)       |
| `connectingMachine → connectingScale`   | `ConnectionManager.connectScale` (post-machine policy)  |
| `connectingMachine → ready` (no scale)  | `ConnectionManager._settleAfterMachinePhase`           |
| `connectingScale → ready`               | `ConnectionManager._settleAfterScalePhase`             |
| `connectingScale → idle` (scale error)  | `StatusPublisher.emitError` → gatekeeper folds to idle  |
| any `→ idle` on disconnect              | `DisconnectSupervisor._onMachineGone / _onScaleGone`    |

`scaleOnly` reconnects (`connect(scaleOnly: true)`) skip every machine-phase
edge. With a machine connected they settle at `ready`; without one they settle
at `idle` after the scale connects.

Non-phase status fields (`error`, `foundMachines`, `pendingAmbiguity`)
are allowed to change on any edge; only the `phase` field follows the
table above.

### Connection Policy

`connect()` is the automatic startup/recovery path: it may quick-connect a missing remembered machine before falling back to scanning. `scanAndConnect()` is the explicit user/API path: it always scans first, preserves connected machine and scale slots, then fills only missing slots.

Automatic `connect()` scans may early-connect preferred devices as they appear. Explicit `scanAndConnect()` scans collect the complete result first, then apply policy:

1. **Machine phase** — apply preferred machine policy:
   - Preferred set + found → auto-connect
   - Preferred set + not found, but others available → show picker (`machinePicker`)
   - No preferred, 1 machine → auto-connect
   - No preferred, multiple → show picker (`machinePicker`)
2. **Scale phase** — after machine resolution, apply the same policy to a missing scale. If no machine is found, an unambiguous scale can still connect while the overall phase remains `idle`. Machine ambiguity is resolved before scale ambiguity, and selecting a machine continues with scale candidates retained from the same scan. Bengle skips external-scale policy because its integrated scale always owns the slot.

The `ScanReport` covers this full selection session. It is finalized after any
picker continuation and retained scale work complete; a newer full scan or a
disconnect finalizes the superseded session as cancelled.

**Early stop.** With a preferred machine set, the scan stops as soon as
its targets connect rather than running the full timeout: when a preferred
scale is also configured, only once *both* connect; when no preferred scale
is configured, as soon as the machine connects. In the no-preferred-scale
case a scale that advertises just after that stop would be missed, so a
deferred (fire-and-forget) scale-only rescan is armed ~3s later — the
machine is already usable and the scale connects in the background if one
shows up. The delay mirrors the post-wake reconnect (lets the DE1 BLE link
stabilise). The rescan is armed only when the scan was actually cut short,
so a full scan that ran to completion never triggers one.

### Key Methods

- `connect()` — Startup/recovery quick-connect with scan fallback
- `scanAndConnect()` — Explicit scan-first flow that fills missing slots
- `connect(scaleOnly: true)` — Automatic scale recovery (skips machine phase)
- `connectMachine(De1Interface)` / `connectScale(Scale)` — Deliberate direct connection
- `selectMachine(De1Interface)` / `selectScale(Scale)` — Continue the active selection session; stale choices are rejected
- `disconnectMachine()` / `disconnectScale()` — Explicit disconnects
- `shutdown()` — Terminal, idempotent connection teardown

The deliberate connect and selection methods return `ConnectionResult` with a
connected, already-connected, conflict, failed, or timed-out outcome. REST and
WebSocket connect handlers preserve that result instead of inferring success
from normal completion.

`shutdown()` permanently rejects new connection requests, stops active discovery,
adapter and USB-attach recovery, scale watch, and reconnect timers, releases
queued requests, and waits for in-flight connection work. It then disconnects
the machine before the scale while isolating each cleanup failure. Flutter
`detached` and requested desktop exit use this path; `paused` and `hidden` do not.

### Disconnect Handling

ConnectionManager listens for disconnects automatically:
- Watches `de1Controller.de1` stream — `null` means machine disconnected
- Watches `scaleController.connectionState` — resets `_scaleConnected` flag on disconnect
- Resets phase to `idle` when machine disconnects

### Machine Auto-Reconnect (recovery mode)

An *unexpected* machine disconnect (not announced via
`markExpectingDisconnect` / `disconnectMachine`) puts `ConnectionManager`
into machine recovery mode: full `connect()` scans retry with the same
5s→60s exponential backoff the legacy preferred-scale loop uses, rescheduling
after every attempt that ends without a machine, until the machine
reconnects (or the user disconnects deliberately). Gated on
`preferredMachineId` so a background retry can never pop a machine picker —
the id is auto-set on every successful connect, so coverage is effectively
total. Motivation: a power outage previously left the app "disconnected"
indefinitely because nothing ever rescanned for the machine.

### Background Scale Watch (preferred-scale reacquisition)

When a machine is connected but the preferred scale is missing (scale
powered off, unexpected drop, machine wake without the scale), scale
reacquisition runs in one of two modes, selected by
`DeviceScanner.supportsBackgroundWatch`:

- **Watch mode (Android):** one persistent, low-duty-cycle BLE scan.
  `UniversalBleDiscoveryService` starts an `AndroidScanMode.balanced`
  scan (~40% radio duty cycle) — the duty cycle, not filtering, is what
  protects the DE1 link. The scan is deliberately unfiltered: remembered
  device names are friendly constants ("Felicita Arc") that rarely equal
  the advertised name a filter would be matched against, and the
  universal_ble fork evaluates `withNamePrefix` plugin-side anyway (the
  OS scan runs unfiltered either way, so there is no hardware-filter or
  screen-off benefit to reclaim). Matching stays with the normal Dart
  `DeviceMatcher` path, identical to burst scans. The `ScaleWatch`
  collaborator (`lib/src/controllers/connection/scale_watch.dart`)
  listens on the device stream and, on sighting the preferred scale id,
  stops the watch scan (freeing the radio for GATT) and connects —
  typically 1–5s after the scale powers on. Caveat: Android suspends
  OS-unfiltered scans while the screen is off, so a scale powered on
  with the display asleep connects once the screen wakes.
- **Legacy mode (all other platforms, and fallback when the watch fails
  to start):** periodic 15s scale-only burst scans with 5s→60s
  exponential backoff (the pre-watch behavior, unchanged).

The watch replaced the backoff loop on Android because each lowLatency
burst monopolizes the shared radio and starves DE1 GATT traffic
(observed as 10s GATT write timeouts → HTTP 500s on machine endpoints),
while the backoff gaps meant a freshly powered-on scale could wait up
to 60s to connect.

Watch lifecycle details:

- Armed whenever *machine connected && preferred scale set && scale not
  connected && not blocked by scale power mode*; disarmed on scale
  connect, machine disconnect, power-mode sleep, deliberate scale
  disconnect, at the start of any full `connect()` (EarlyConnectWatcher
  owns preferred-device connects during bursts), and on dispose.
- Never armed while a Bengle is the machine — its integrated scale owns
  the scale slot, mirroring `_runScalePhase`'s rule.
- Burst scans pause the watch scan (universal_ble has one global scan
  session) and resume it when they finish; the watch self-restarts
  every 25 minutes to dodge Android's 30-minute opportunistic-scan
  downgrade, and survives adapter off/on cycles.
- While its scan is believed running, the watch probes
  `UniversalBle.isScanning()` every 90 seconds (a host-side bookkeeping
  check, no radio use). A dead scan is torn down and restarted through
  the same failure path as refresh/resume, so a restart that also fails
  reports watch-unavailable and hands off to the legacy backoff
  fallback. Probe errors fail open (treated as alive) so an unprovable
  probe never churns the session. Coverage limit: the probe catches
  starts the fork's `SafeScanner` throttle silently swallowed, but a
  native `onScanFailed` after a successful start does not update the
  host-side bookkeeping, so that flavor stays bounded by the 25-minute
  refresh — see `doc/AI_BLE_NOTES.md` ("Watch Scan Silent Death").
- `De1StateManager` skips its post-wake scale-only burst when the watch
  covers reacquisition (watch supported + preferred scale set); the
  burst remains for the no-preferred-scale discovery/picker case.
- Watch-driven connects do **not** emit a `ScanReport` — they bypass
  the scan/report machinery entirely.
- The watch does not flip `scanningStream`, so no scanning indicator
  shows in the UI while it runs.

### Zombie-Link Detection (BLE transport)

A dead BLE link doesn't always deliver a disconnect event (observed on
Android: GATT writes time out forever while the app still believes it is
connected, and no recovery is possible without an app restart).
`UniversalBleTransport` detects this and emits `disconnected` itself —
which drives the normal disconnect cascade and, for machines, the
auto-reconnect above:

- **On a GATT operation timeout** it probes the OS connection state
  (async, never blocking the caller). An OS-confirmed drop declares the
  link dead; three consecutive timeouts force a teardown even if the OS
  still claims connected. A single timeout on a healthy link keeps the
  existing fail-fast behavior (profile-upload safety — see the comment on
  `UniversalBleTransport.write`).
- **On seeing its own deviceId advertising** while believed connected, it
  runs the same probe (throttled). Teardown is probe-confirmed only,
  because the transport is shared with scales/sensors and some peripherals
  legitimately advertise while connected.

### Gone-Device GATT Error Handling (BLE transport)

When a BLE write/read/subscribe hits a device that has already
 disconnected (scale powered off mid-session, Bluetooth adapter off on
 macOS, DE1 unplugged), `universal_ble` throws `UniversalBleException`
with error codes like `characteristicNotFound`, `deviceNotFound`,
`serviceNotFound`, `connectionTerminated`, `deviceDisconnected`, or
`unknownError`. The transport's `_handleGattError()` catches these,

1. Emits `ConnectionState.disconnected` (drives the normal disconnect cascade),
2. Drains the BLE queue (`clearQueue`) so pending writes don't pile up, and
3. Throws `DeviceNotConnectedException` so upper layers handle it gracefully
   instead of crashing.

GATT error 133 (`gattError`) is treated as transient — the queue is cleared
and a `BleTimeoutException` is thrown so `UnifiedDe1Transport` can retry via
`_handleBleTimeout`. The link is NOT declared dead for GATT-133.

### Crashlytics Error Filtering (telemetry)

The `DeviceNotConnectedException` thrown from `_handleGattError` and the raw
`UniversalBleException` can escape to the Flutter framework's global error
handlers (`FlutterError.onError`, `PlatformDispatcher.instance.onError`)
from fire-and-forget contexts — e.g. a `Timer.periodic` heartbeat callback
where nobody is awaiting the write Future. Without filtering, the
Crashlytics integration records these as FATAL crashes (false positives —
the transport already emitted `disconnected` and the device impl's
connectionState listener handles cleanup).

`isBenignFrameworkError()` in `lib/src/services/telemetry/crashlytics_error_filter.dart`
filters these from both framework error handlers:

- `DeviceNotConnectedException` (any kind)
- `UniversalBleException` with gone-device error codes
- `Exception('Queue Cancelled')` — from `universal_ble`'s `Queue.dispose()`
  when `clearQueue` cancels pending items

This is the safety net. Device implementations should ALSO catch
`DeviceNotConnectedException` at their write level for graceful recovery
(see [Best Practices](#best-practices)).

### Preferred Device Settings

Device preferences are stored via `SettingsController`:
- `preferredMachineId` — auto-set on successful machine connection
- `preferredScaleId` — auto-set on successful scale connection
- Configurable in Settings → Device Management

Identity remains per transport. BLE and USB IDs for the same physical machine
are not aliased. If the BLE ID is preferred while Bluetooth is unavailable, a
discovered USB identity is offered for selection; selecting it persists that USB
ID. Later automatic startup and recovery scans can quick-connect
through the remembered USB record, with normal implementation validation and
scan fallback on failure. A physically attached Android USB machine bypasses
preference entirely (see "Android USB attach recovery") and persists its USB
ID as the preferred machine after a successful connection.

---

## Device-Specific Controllers

Device-specific controllers manage the lifecycle and state of individual device types. They handle the low-level connection mechanics; the ConnectionManager handles the policy of *when* and *which* device to connect.

### De1Controller

**File:** `lib/src/controllers/de1_controller.dart`

**Responsibilities:**
- Manages DE1 connection (manual, user-selected)
- Exposes machine state streams
- Handles steam/hot water/flush settings
- Manages shot settings and profile uploads

**Connection Flow:**
```dart
Future<void> connectToDe1(De1Interface de1Interface) async {
  _onDisconnect(); // Clean up any existing connection
  _de1 = de1Interface;
  await de1Interface.onConnect();
  _de1Controller.add(_de1);
  
  // Subscribe to machine streams
  _subscriptions.add(_de1.ready.listen(_initializeData));
  _subscriptions.add(_de1.connectionState.listen(_processConnection));
}
```

**Key Streams:**
- `de1`: Current connected DE1 (or null)
- `steamData`: Steam settings
- `hotWaterData`: Hot water settings
- `rinseData`: Flush/rinse settings

### ScaleController

**File:** `lib/src/controllers/scale_controller.dart`

**Responsibilities:**
- Manages scale connection lifecycle (called by ConnectionManager)
- Processes weight and flow data
- Calculates low-lag Kalman control flow for weight-based decisions
- Calculates separately smoothed display flow for snapshots and shot history
- Exposes weight snapshots and connection state

**Note:** ScaleController does **not** auto-connect. Connection decisions are made by `ConnectionManager`. ScaleController only handles the mechanics of connecting to a specific scale.

Device implementations define their own readiness gate before `ScaleController`
adopts them. See [`device-notes/scales.md`](device-notes/scales.md).

**Connection Flow:**
```dart
Future<void> connectToScale(Scale scale) async {
  _onDisconnect();
  _scaleConnection = scale.connectionState.listen(_processConnection);
  _scaleSnapshot = scale.currentSnapshot.listen(_processSnapshot);
  await scale.onConnect();
  _scale = scale;
}
```

**Key Streams:**
- `connectionState`: Scale connection status (`BehaviorSubject<ConnectionState>`)
- `weightSnapshot`: Processed weight data with flow calculation
- `currentConnectionState`: Synchronous getter for current state

### SensorController

**File:** `lib/src/controllers/sensor_controller.dart`

**Responsibilities:**
- Manages sensor connections (basket sensors, debug port)
- Auto-connects to first found sensor
- Exposes sensor data streams

**Pattern:** Mirrors ScaleController auto-connect logic

Named sensor behavior lives in
[`device-notes/sensors.md`](device-notes/sensors.md).

`PluginDeviceService` is a `DeviceDiscoveryService` that contributes sensors
registered by plugin generations. This keeps plugin-backed sensors on the same
`DeviceController` → `SensorController` path as native sensors. Public identity
comes from plugin id, declared driver id, and plugin-local instance id; unload
removes the retiring generation without changing that identity for a later
reload. Plugin connection handlers must complete protocol initialization before
the sensor reports `connected`. Registrations are runtime-only and are not added
to remembered-device selection.

### Bengle EBus tap

See [`device-notes/bengle.md`](device-notes/bengle.md#ebus-tap).

### RememberedDevicesController

**File:** `lib/src/controllers/remembered_devices_controller.dart`

Persists devices the user has connected to (machine + scale) so they stay
visible — marked **unavailable** — when they're not currently present, instead
of vanishing. Cross-transport (BLE/USB/WiFi) by construction.

- **Registry:** `{id, name, type}` per device, persisted as a JSON list in the
  settings layer (`SettingsService.rememberedDevices`), mirroring the
  preferred-device persistence pattern. Loaded on `initialize()`.
- **Observation:** consumes two `Stream<RememberedDevice?>` (machine, scale);
  `main.dart` wires these from `De1Controller.de1` and
  `ScaleController.connectionState` (+ `connectedScale()`), reading
  `{id, name, type}` off the connected device. A null emission (disconnect)
  does **not** forget — the device stays remembered.
- **Availability:** computed at the API layer. `DevicesStateAggregator` /
  `DevicesHandler` merge discovered devices and the actively connected scale
  (`available: true`) with remembered devices that aren't present
  (`available: false`, `state: "disconnected"`) via the shared
  `buildAvailabilityDeviceList`. The aggregator re-emits when the registry or
  connected scale changes. `DeviceController` itself stays discovery-only.
- **Forget:** `RememberedDevicesController.forget(id)`, exposed as
  `PUT /api/v1/devices/forget` (deviceId in body/query). A GUI Forget control
  lives in the web skin (separate repo), driven by this endpoint.
- **Identity:** by `deviceId`, stable per transport (BLE MAC, WiFi `wifi:<host>`,
  serial USB stable id or — on macOS where vid/pid is unreadable — the port
  path). Moving a USB device to a different physical port yields a new id (new
  remembered entry); Forget removes the stale one.

### Bengle integrated scale

See [`device-notes/bengle.md`](device-notes/bengle.md#integrated-scale).

---

## Connection Flow

### Quick Connect

Before running a full scan, `ConnectionManager._connectImpl` tries a
**machine-only quick-connect** — a direct connection to the preferred machine
from remembered-device metadata, without scanning:

```
ConnectionManager._connectImpl()
  |
  +-- Publish connectingMachine phase (UI shows spinner, not Retry)
  |
  +-- Look up preferred machine in RememberedDevicesController
  |
  +-- deviceScanner.tryQuickConnect(machineRemembered)
  |     |- BLE: getSystemDevices (Apple) / direct connect (Android)
  |     |      -> BleDevice + UniversalBleTransport + DeviceFactory.create()
  |     |      -> transport.connect() -> device.onConnect() -> identity check
  |     |      -> return connected Device or null
  |     |
  |     |- Serial: open SerialPort(storedPath) -> _detectDevice()
  |     |         -> verify match -> onConnect() -> return Device or null
  |     |
  |     +-- WiFi: WifiScaleDiscoveryService.tryQuickConnect()
  |            (returns null — WiFi scales use deferred discovery)
  |
  +-- If machine returned:
  |     |- de1Controller.adoptDevice()
  |     |- Bengle → attach integrated BengleVirtualScale
  |     |- DE1 + preferred scale configured → schedule preferred scale reconnect
  |     |- DE1 + no preferred scale → arm deferred scale-only scan (~3s delay)
  |     +-- publish ready. DONE (no scan fallthrough).
  |
  +-- If machine null -> fall through to ScanOrchestrator.runScan()
       (existing scan -> match -> EarlyConnectWatcher -> connect)
```

Scales are **excluded** from quick-connect. The machine-only critical path
publishes ready immediately after machine adoption, then kicks off background
scale discovery:

- **Preferred scale configured:** `_maybeSchedulePreferredScaleReconnect()`
  (exponential backoff: 5s → 10s → 20s → 40s → 60s cap)
- **No preferred scale:** `_armPostQuickConnectScaleScan()` (single deferred
  scale-only scan after ~3s, same delay as the post-wake reconnect)

Quick-connect is reserved for automatic startup and recovery. Android
USB-attach recovery probes the attached device directly instead of
quick-connecting when the scanner supports `UsbAttachProbe` (see "Android USB
attach recovery"). Explicit native, REST, and WebSocket scans call
`scanAndConnect()` and always scan before applying policy. The phase stream shows
`idle → connectingMachine → ready` on success. On failure:
`connectingMachine` is published before the attempt, then phase falls
through to `scanning` (existing scan path).

Android serial discovery replaces a registry entry when quick-connect detects
a new device instance with the same `deviceId`, so REST and WebSocket inventory
never retain the disconnected instance beside its connected replacement.

### Initial App Startup

```
1. main.dart
   ↓
2. Create discovery services with device mappings
   ↓
3. Create DeviceController(services), De1Controller, ScaleController
   ↓
4. Create RememberedDevicesController, initialize (loads + migrates registry)
   ↓
5. Create ConnectionManager(deviceController, de1Controller, scaleController,
   settingsController, rememberedDevices)
   ↓
6. runApp(MyApp(...))
   ↓
7. OnboardingView displayed (steps: android-warning → welcome → login →
   permissions → initialization → scan)
   ↓
8. Permissions step grants permissions; initialization step runs
   deviceController.initialize()
   ↓
9. Scan step calls connectionManager.connect()
   ↓
10. ConnectionManager: machine-only quick-connect (preferred machine)
     -> publish connectingMachine -> BLE/serial tryQuickConnect ->
     adoptDevice -> Bengle virtual scale / deferred scale scan ->
     publish ready. On failure: fall through to full scan.
   ↓
11. Status stream (QC success): idle -> connectingMachine -> ready.
     Status stream (QC failure): idle -> connectingMachine -> scanning ->
     connectingMachine -> connectingScale -> ready.
     ↓
12. On `ready`, onboarding completes -> navigates to LauncherView, then pushes
    SkinView on top when the platform supports an in-app WebView, the device
    isn't a degraded Android (SDK < 31), and the skin server is serving.
    Degraded/unsupported devices stay on the launcher (browser hero card).
```

If multiple machines or scales are found without a preferred device set, ConnectionManager emits `pendingAmbiguity: machinePicker` or `scalePicker`, and the UI shows a picker dialog.

### Explicit Retry from Native Device UI

The legacy `home_feature` StatusTile reconnect affordance is retired. Native
scan and retry controls call `scanAndConnect()`, so they perform a complete
scan before filling missing slots. The launcher’s **Connect your machine** hero
opens `LauncherScanPage`, which reuses this scan-first flow.

### Machine Wake → Scale Reconnect Flow

```
1. Machine state: sleeping → idle
   ↓
2. De1StateManager._handleScalePowerManagement() detects transition
   ↓
3. Check if scale connected → NO, scalePowerMode == disconnect → YES
   ↓
4. Call `connectionManager.connect(scaleOnly: true)`
   ↓
5. Scan runs, preferred scale connected automatically
```

---

## State Management

### Device Connection States

**Enum:** `ConnectionState` (defined in `lib/src/models/device/device.dart`)

```dart
enum ConnectionState {
  discovered,
  connecting,
  connected,
  disconnecting,
  disconnected,
}
```

**Lifecycle:** `discovered → connecting → connected → disconnecting → disconnected`

- `discovered` — device created by discovery service, never connected
- `connecting` — connection in progress
- `connected` — connection established
- `disconnecting` — disconnection in progress
- `disconnected` — was connected, connection lost or explicitly closed

### State Transitions

**Devices:**
```
discovered → connecting → connected → disconnecting → disconnected
```

**Controllers:**
- Subscribe to device `connectionState` stream
- Update internal state on transitions
- Clean up resources on disconnect

### De1StateManager Integration

**File:** `lib/src/controllers/de1_state_manager.dart`

The De1StateManager is the central orchestrator for machine state changes and related behaviors:

**Responsibilities:**
1. Listen to machine state transitions
2. Manage scale power based on state transitions
3. Handle gateway mode logic (full/tracking/disabled)
4. Trigger device scans when needed
5. Manage shot tracking in tracking mode
6. Navigate to realtime features in disabled mode

**Dependencies:**
```dart
De1StateManager({
  required De1Controller de1Controller,
  required DeviceController deviceController,
  required ScaleController scaleController,
  required WorkflowController workflowController,
  required PersistenceController persistenceController,
  required SettingsController settingsController,
  required GlobalKey<NavigatorState> navigatorKey,
})
```

**Key Methods:**
- `_handleSnapshot(MachineSnapshot)`: Processes all machine state updates
- `_handleScalePowerManagement(MachineState)`: Manages scale sleep/wake/scan
- `_triggerScaleScan()`: Initiates device scan with 30s timeout

### Legacy DE1 identity resolution (post-connect)

See [`device-notes/de1.md`](device-notes/de1.md#legacy-identity-resolution).

### Hot water stop-at-weight

See [`device-notes/de1.md`](device-notes/de1.md#hot-water-stop-at-weight).

---

## Connection Policy

All connection decisions are centralized in `ConnectionManager`. Individual controllers (De1Controller, ScaleController) only handle the mechanics of connecting/disconnecting.

### Preferred Device Policy

ConnectionManager uses `SettingsController` to read preferred device IDs:

1. **Preferred device set + found during scan** → auto-connect (during discovery for automatic recovery; after discovery completes for explicit scans)
2. **Preferred device set + not found, but others available** → show picker dialog
3. **No preferred device, 1 found** → auto-connect silently
4. **No preferred device, multiple found** → show picker dialog
5. **No devices found** → stay idle

Preferred device IDs are auto-saved on successful connection and can be managed in Settings → Device Management.

### Machine vs Scale Connection

- Connected machine and scale slots are preserved; alternatives discovered by a scan never replace them automatically.
- Machine policy resolves before scale policy so Bengle's integrated scale always wins; selecting or reconnecting Bengle hands off an attached external scale to the integrated scale.
- If no machine is found, a missing unambiguous scale still connects; phase remains `idle` and the scan UI shows the partial result.
- Machine selection continues deterministically into the retained scale phase from the same scan.
- Scale ambiguity pauses preferred-scale reacquisition until the user selects a scale; successful selection updates the preferred ID used by future watches.
- **Scale failures are non-blocking** — if scale connection fails, machine stays connected and phase stays `ready`
- **Scale-only reconnect** — `connect(scaleOnly: true)` skips the machine phase and retains automatic preferred-scale recovery behavior (used by De1StateManager for wake-from-sleep)

---

## Error Surfacing

BLE errors (connect failures, mid-session disconnects, adapter-level problems) emit on `ConnectionManager.status` as a structured `ConnectionError`. The error appears on `ws/v1/devices` as `connectionStatus.error`. See [`doc/Api.md`](Api.md) and [`doc/Skins.md`](Skins.md#handling-connection-errors) for the taxonomy and skin contract.

When wiring a new app-initiated disconnect call site, precede the disconnect with `ConnectionManager.markExpectingDisconnect(deviceId)` so the resulting disconnect event doesn't fire a `scaleDisconnected` / `machineDisconnected` error. A 10s TTL safety timer clears stale expectations if the disconnect event never arrives.

---

## Adding New Devices

### Step-by-Step Guide

#### 1. Define Device Interface

Create an interface in `lib/src/models/device/`:

```dart
// Example: New temperature sensor
abstract class TemperatureSensor implements Device {
  Stream<double> get temperature;
  Future<void> setTargetTemperature(double temp);
}
```

#### 2. Implement Concrete Device

Create implementation in `lib/src/models/device/impl/`:

```dart
class AcaiaTemperatureSensor implements TemperatureSensor {
  final BLETransport _transport;
  
  static const String serviceUUID = "ACAIA-TEMP-SERVICE-UUID";
  
  AcaiaTemperatureSensor({required BLETransport transport})
    : _transport = transport;
  
  @override
  Future<void> onConnect() async {
    // Subscribe to BLE characteristics
  }
  
  @override
  Future<void> disconnect() async {
    // Clean up subscriptions
  }
  
  // ... implement temperature methods
}
```

#### 3. Add Device Mapping

Update `main.dart`:

```dart
services.add(
  UniversalBleDiscoveryService(
    mappings: {
      // ... existing mappings
      AcaiaTemperatureSensor.serviceUUID.toUpperCase(): (t) async {
        return AcaiaTemperatureSensor(transport: t);
      },
    },
  ),
);
```

#### 4. Create Controller (Optional)

If device requires specialized logic, create controller:

```dart
class TemperatureController {
  TemperatureSensor? _sensor;

  /// Called by ConnectionManager when a sensor should be connected.
  Future<void> connectToSensor(TemperatureSensor sensor) async {
    _sensor = sensor;
    await sensor.onConnect();
    // ... subscribe to streams
  }

  void dispose() {
    // ... cancel subscriptions
  }
}
```

**Note:** Connection decisions (when to connect, which device) should be handled by `ConnectionManager`, not by the device-specific controller.

#### 5. Add API Handler (Optional)

Create handler in `lib/src/services/webserver/`:

```dart
class TemperatureHandler {
  final TemperatureController _controller;
  
  void addRoutes(ShelfPlus app) {
    app.get('/api/v1/temperature', () async {
      final temp = await _controller.getCurrentTemperature();
      return {'temperature': temp};
    });
  }
}
```

#### 6. Update OpenAPI Documentation

Add endpoints to `assets/api/rest_v1.yml` and `websocket_v1.yml`.

---

## Best Practices

### Transport Abstraction

Always depend on interfaces, not concrete implementations:

```dart
// ✅ Good
class MyDevice implements Device {
  final BLETransport _transport;
  
  MyDevice({required BLETransport transport}) : _transport = transport;
}

// ❌ Bad
class MyDevice implements Device {
  final UniversalBleTransport _transport; // Coupled to specific implementation
  
  MyDevice({required UniversalBleTransport transport}) : _transport = transport;
}
```

### Stream Cleanup

Always cancel subscriptions in `dispose()` methods:

```dart
class MyController {
  StreamSubscription<Device>? _deviceSubscription;
  
  MyController() {
    _deviceSubscription = deviceStream.listen(...);
  }
  
  void dispose() {
    _deviceSubscription?.cancel();
    _deviceSubscription = null;
  }
}
```

### Error Handling

Use `catchError` for non-critical operations:

```dart
// Scale power management - don't crash if scale disconnected
scale.sleepDisplay().catchError((e) {
  _logger.warning('Failed to sleep scale display: $e');
});
```

Use `try-catch` for critical operations:

```dart
// Device connection - need to handle error gracefully
try {
  await device.onConnect();
} catch (e) {
  _logger.severe('Failed to connect to device', e);
  // Show user error message
}
```

**Scale writes must catch `DeviceNotConnectedException`.** When a BLE
write hits a disconnected device, the transport's `_handleGattError`
throws `DeviceNotConnectedException`. This can escape from fire-and-forget
contexts (Timer.periodic heartbeat callbacks, unawaited Futures) and reach
the framework error handler. Catch it at the lowest-level write helper so all
command paths are covered:

```dart
// ✅ Good — single catch point in _writeCommand / _safeWrite
Future<void> _writeCommand(List<int> commandBytes) async {
  try {
    await _device.write(serviceId, charId, _buildCommand(commandBytes));
  } on DeviceNotConnectedException {
    // Transport already emitted disconnected; the connectionState
    // listener handles cleanup.
  }
}
```

```dart
// ❌ Bad — bare _transport.write() without catch; crashes if scale
// disconnected mid-session
Future<void> tare() async {
  await _transport.write(serviceId, charId, Uint8List.fromList([0x10]));
}
```

The framework error handler filter (`isBenignFrameworkError`) is the safety
net — but scale-level catches are defense-in-depth and keep the log trace
informative (`.info` level rather than silently swallowed).

### State Broadcasting

Use `BehaviorSubject` for stateful streams:

```dart
final BehaviorSubject<ConnectionState> _connectionController =
  BehaviorSubject.seeded(ConnectionState.discovered);

Stream<ConnectionState> get connectionState => _connectionController.stream;
```

### Initialization Order

Controllers must be created before state managers:

```dart
// main.dart
final deviceController = DeviceController(services);
final de1Controller = De1Controller(controller: deviceController);
final scaleController = ScaleController(controller: deviceController);

// app.dart
final stateManager = De1StateManager(
  deviceController: deviceController,
  de1Controller: de1Controller,
  scaleController: scaleController,
  // ...
);
```

---

## Debugging Tips

### Enable Detailed Logging

Set log level in settings UI or SharedPreferences:

```dart
// Settings → Log Level → FINEST
Logger.root.level = Level.FINEST;
```

Logs are written to:
- **All platforms:** `<app_documents>/log.txt`

### Inspect Device Stream

Add temporary logging in DeviceController:

```dart
_deviceStream.listen((devices) {
  _log.info('Current devices: ${devices.map((d) => d.name).join(", ")}');
});
```

### Check ConnectionManager Status

Monitor connection phases via WebSocket or logs:

```dart
// Subscribe to ConnectionManager status
connectionManager.status.listen((status) {
  _log.info('Phase: ${status.phase}, ambiguity: ${status.pendingAmbiguity}');
});
```

Or via the `/ws/v1/devices` WebSocket — the `connectionStatus` field shows the current phase, found devices, and any pending ambiguity.

### Monitor State Transitions

Add logging in De1StateManager:

```dart
void _handleSnapshot(MachineSnapshot snapshot) {
  _logger.info('State transition: $_previousMachineState → ${snapshot.state.state}');
  // ... state handling
}
```

### Simulated Devices

See [`device-notes/simulators.md`](device-notes/simulators.md).

---

## Common Issues

### Scale Doesn't Connect

See [`device-notes/scales.md`](device-notes/scales.md#troubleshooting).

### Multiple Scans Interfere

**Symptoms:** Devices disappear/reappear during scan

**Cause:** Multiple overlapping scans (BLE stack limitation)

**Solution:** Use `_isScanning` flag pattern:

```dart
bool _isScanning = false;

Future<void> scan() async {
  if (_isScanning) {
    _log.info('Scan already in progress');
    return;
  }
  _isScanning = true;
  try {
    await actualScan();
  } finally {
    _isScanning = false;
  }
}
```

### DE1 Auto-Connects (Unexpected)

See [`device-notes/de1.md`](device-notes/de1.md).

### Serial Devices Not Found

**Symptoms:** Serial scales/machines not discovered

**Platform-Specific Issues:**
- **Desktop:** Check `libserialport` package is included
- **Android:** Enable USB debugging, check USB permissions
- **macOS:** Grant serial port access in System Preferences

**Debug:**
```dart
// In SerialService.scanForDevices()
final ports = SerialPort.availablePorts;
_log.info('Found serial ports: $ports');
```

---

## Future Roadmap

### Planned Enhancements

1. **Smart Reconnection:**
   - Exponential backoff for failed reconnections
   - Connection quality monitoring

2. **Multi-Device Support:**
   - Connect to multiple scales simultaneously
   - Aggregate sensor data from multiple sources
   - Switch between devices without disconnection

3. **Connection Indicators:**
   - Signal strength monitoring
   - Connection quality metrics

4. **Device Fingerprinting:**
   - Unique device identification beyond UUID
   - Detect duplicate devices (same scale via BLE + Serial)
   - Prevent double-connection issues

---

## Related Files

### Core Device Management
- `lib/src/controllers/connection_manager.dart` - Centralized connection orchestration
- `lib/src/controllers/device_controller.dart` - Discovery coordination
- `lib/src/controllers/de1_controller.dart` - DE1 machine management
- `lib/src/controllers/scale_controller.dart` - Scale management
- `lib/src/controllers/sensor_controller.dart` - Sensor management
- `lib/src/controllers/de1_state_manager.dart` - State orchestration

### Discovery Services
- `lib/src/services/blue_plus_discovery_service.dart` - BLE (Android/iOS/macOS/Linux)
- `lib/src/services/universal_ble_discovery_service.dart` - BLE (all platforms)
- `lib/src/services/serial/serial_service.dart` - Serial device factory
- `lib/src/services/serial/serial_service_desktop.dart` - Desktop serial
- `lib/src/services/serial/serial_service_android.dart` - Android USB OTG
- `lib/src/services/simulated_device_service.dart` - Testing mocks

### Device Implementations
- `lib/src/models/device/impl/de1/` - DE1 machines (BLE + Serial, unified interface in `unified_de1/`)
- `lib/src/models/device/impl/decent_scale/` - Decent Scale (BLE + Serial + WiFi)
- `lib/src/models/device/impl/acaia/` - Acaia scales (unified: IPS protocol for older ACAIA/PROCH, Pyxis protocol for Lunar/Pearl/Pyxis, auto-detected at connect time)
- `lib/src/models/device/impl/felicita/` - Felicita Arc scale
- `lib/src/models/device/impl/bookoo/` - Bookoo Miniscale
- `lib/src/models/device/impl/mock_de1/` - Mock DE1 for testing
- `lib/src/models/device/impl/mock_scale/` - Mock scale for testing

### UI Components
- `lib/src/permissions_feature/permissions_view.dart` - Initial scan and DE1 selection
- `lib/src/home_feature/tiles/status_tile.dart` - Connection status display
- `lib/src/sample_feature/sample_item_list_view.dart` - Device list debugging

---

## Post-Initialization Profile Synchronization

See
[`device-notes/de1.md`](device-notes/de1.md#post-initialization-profile-synchronization).

## Glossary

- **BLE:** Bluetooth Low Energy, wireless protocol for IoT devices
- **Transport:** Abstraction layer for device communication (BLE, Serial, etc.)
- **Discovery Service:** Component that scans for and creates device instances
- **Device Controller:** Central coordinator for all discovery services
- **Device-Specific Controller:** Manages lifecycle of a specific device type (DE1, Scale, Sensor)
- **ConnectionManager:** Centralized orchestrator for device connection policy
- **ConnectionStatus:** State object with phase, found devices, and ambiguity info
- **Device Stream:** RxDart BehaviorSubject broadcasting list of discovered devices
- **State Manager:** Orchestrator for machine state changes and related behaviors
- **UUID:** Universally Unique Identifier, used to identify BLE services/devices
- **Service Mapping:** Dictionary mapping UUIDs to device factory functions
