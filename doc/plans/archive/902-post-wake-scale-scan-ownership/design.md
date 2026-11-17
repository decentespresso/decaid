# Issue #902 — Post-wake preferred-scale scan ownership design

## Problem

Failure report: a preferred BLE scale that is switched on while the machine
wakes is not rediscovered for a long time, so the retry loop appears dead. A
later full scan finds the scale and it connects immediately, which places the
defect in scan ownership rather than in the Decent Scale protocol.

The sequence that produces it:

1. the preferred BLE scale disconnects;
2. Decaid arms the persistent Android `ScaleWatch`, which owns scale
   reacquisition;
3. the machine wakes, so the deferred scale scan intentionally starts no burst
   and relies on that watch;
4. a client scan (`GET /api/v1/devices/scan`, `{"command":"scan"}` on
   `/ws/v1/devices`) takes the normal explicit-scan path;
5. the explicit path must pause and stop the persistent watch before it starts
   its low-latency burst, and restarts the watch afterwards.

A client scanning at the wrong moment therefore churns the single Android BLE
scan owner exactly while the watch is reacquiring the preferred scale. Repeated
client scans around wake multiply the churn, and the scale is not rediscovered
until the client happens to scan when the watch is idle.

Prior art exists in Streamline.js (`fix(scale): stop auto-scan around machine
sleep and wake`), but the reported machine already ran that fix, so the skin is
not assumed to be the remaining cause. Decaid itself must make scan ownership
observable and robust against clients that scan at the wrong time.

## Invariant

Decaid, not the skin, owns the arbitration between client-requested explicit
scans and its own preferred-scale reacquisition. During the existing post-wake
reacquisition window, an external explicit scan must not tear down or preempt
the background preferred-scale watch. Native in-app scan controls
(`ConnectionManager.scanAndConnect()`, used by the launcher and retry UI) stay
full explicit scans: they are a deliberate operator action, not client churn,
so the lease never converts one into discovery-only work.

## Smallest safe design

Reuse the existing scan queueing primitives. Do not add a second scheduler, a
global scanner/GATT mutex, or BLE-wide serialization.

1. One entry point. REST and the devices WebSocket call
   `ConnectionManager.requestExternalScan({connect, scanOnly})` instead of
   calling `scanAndConnect()` / `scanForDevices()` directly. The manager is the
   single place that arbitrates client intent against recovery, and every
   explicit request is logged at INFO with its source, `connect`, `quick`,
   current phase, whether connection work is active, and its disposition
   (started / queued / coalesced / superseding/stopping).

2. A narrow lease. On a sleeping-to-awake machine transition, when the
   preferred scale is disconnected, a preferred scale is configured, and the
   background watch is the selected reacquisition mechanism, the watch is
   protected for the existing three-second wake window
   (`deferredScaleScanDelay`).

3. Deferral and coalescing. While the lease is active, an external scan is not
   run. It is stored as one pending intent: repeated requests collapse into the
   same completer, so repeated client requests cannot create a queue of bursts.
   A request that asks for the full connection policy upgrades a pending
   discovery-only intent, so the deferred run performs connection policy.

4. Drop and single run. A scale reconnect, a machine disconnect, or shutdown
   drops the lease-deferred intent. The lease owns that drop: an explicit scan
   queued behind in-flight connection work outside the lease keeps the normal
   drain path in `_runConnectImpl`. Otherwise exactly one deferred scan runs
   when the window closes, and after any connection work that is still in
   flight. Machine recovery keeps its existing priority: it is never deferred
   by this scale lease.

5. Native supersede. A full `scanAndConnect()` arriving while the lease holds a
   deferred discovery-only intent supersedes it: the pending client intent is
   completed as dropped and the native call runs its scan immediately. Without
   this, the native retry UI would receive the lease-deferred discovery-only
   future and never perform connection policy. Coalescing still applies when
   the pending intent is already a full explicit scan, because then the queued
   future is the same work.

6. Diagnostics without a second source of truth. `UniversalBleDiscoveryService`
   logs the `watch -> burst -> watch` transitions from its existing scan
   owner/phase state, so an ordinary support log reconstructs the timeline.

## Alternatives rejected

- A global scanner/GATT mutex or global BLE serialization: wider blast radius
  than the defect, and it would serialize unrelated machine and scale traffic.
- An unconditional post-wake burst scan: reverses the earlier fix that stopped
  Decaid competing with its own persistent watch.
- A separate parallel queue for lease-deferred client intent: two queue states
  for the same concept. Upgrading the existing explicit-scan queue is smaller
  and keeps the drain path in `_runConnectImpl` as the only place that consumes
  explicit scan intent.
- Changing the Decent Scale protocol, capabilities, or power-mode behavior: the
  defect is scheduling, not negotiation.

## Verification

Deterministic `ConnectionManager` tests cover the healthy wake path (no burst),
one deferred client scan, coalescing of repeats, drop on scale reconnect,
single deferred run at lease expiry, the native supersede, a queued explicit
scan surviving a machine disconnect outside the lease, the no-preferred-scale /
no-watch cases, and machine-recovery precedence. REST and devices-WS handler
tests cover the deferred path as seen by clients: a waiting request is held
until the deferred scan runs, a `quick` request returns immediately, a
`connect=true` request runs the full policy after the window, and a deferred
scan failure is reported to a waiting WebSocket client while a quick one keeps
it out of the socket.

## Hardware follow-up

Code completion can prove the arbitration deterministically; it cannot prove
BLE behavior on a real radio. Closing the issue still needs the reporter's
scenario on real hardware: a preferred BLE scale powered on while the machine
wakes recovers without a client scan, and a client that scans repeatedly
immediately after wake no longer prevents that recovery. The
`.agents/skills/decent-app/scenarios/device-scan-connection-policy.md` scenario
carries the simulator checks and the hardware extension.
