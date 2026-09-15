# #871 part 4/5 — Decaid BLE recovery integration

Issue: #876  
Parent: #871  
Decision/evidence gate: #875  
Native admission/lifecycle work: `tadelv/universal_ble#26`, `#27` / draft PRs `#25`, `#28`

This document records the Decaid-side integration contract for the provisional
native admission/lifecycle solution. It is intentionally narrower than a new
BLE scheduler: Decaid keeps policy, retry and scan ownership; the Android
plugin owns native direct-connect admission and exact GATT lifecycle state.

## Current draft status

The branch is stacked on the current #867 head so the accepted scale-power
baseline remains in force while this work is developed:

- `displayOff` keeps a healthy original / unknown / pre-modern-HDS scale link;
- explicit disconnect remains a real disconnect;
- this issue must not re-introduce reconnect churn to implement recovery.

The first safe Decaid slice is in place: exact attempt ownership is modeled by
`ConnectionAttemptOwner`, and `De1Controller` / `ScaleController` fence late
connect completions with their existing connection generations. A first
`ConnectionManager` retirement prototype was deliberately removed from the
draft after the existing shutdown regression exposed a sequencing bug: it
started cleanup while the source connect was still pending. The required
manager ordering is therefore explicit: invalidate immediately, then await the
exact source, then perform owned cleanup, and release the lease last.

The `universal_ble` dependency is **not repinned yet**. The current reviewed
`#28` head is `84c5406872d6fbef5ddae57dea0c7dfdfe12d759`, but its Android unit-test
job currently fails three regressions:

1. `NotificationLifecycleTest.staleDisconnectCannotRemoveCurrentGatt`
2. `UniversalBlePluginTest.mixedCaseDisconnectKeepsConnectDisconnectDelay`
3. `UniversalBlePluginTest.connectedCallbackCancelsPendingReconnect`

Pinning a known-red head would turn an upstream recovery regression into the
Decaid baseline. The final part-4 commit must instead pin the exact reviewed,
green `#28` head in both `pubspec.yaml` and `pubspec.lock` and preserve all
unrelated pins, especially `flutter_js`.

## Entry-point inventory

### ConnectionManager

`ConnectionManager` is the host policy/retry owner. Relevant entry points are:

- remembered-machine quick connect (`_tryQuickConnectMachine`);
- preferred-device early connect through `ScanOrchestrator` /
  `EarlyConnectWatcher`;
- explicit machine / scale connect (`connectMachine`, `connectScale`);
- machine recovery timer and scale recovery/watch paths;
- shutdown, adapter recovery and user scan cancellation.

The existing `_isConnectingMachine` / `_isConnectingScale` booleans prevent
same-role overlap only while the caller is still awaiting the operation. They
do not by themselves make an abandoned `Future` safe.

The existing regression `shutdown waits for a timed-out machine connect to
actually finish` is also a lifecycle contract: caller-visible timeout may
return first, but shutdown must not disconnect/tear down that candidate until
the source connect has actually settled.

### Quick connect

`UniversalBleDiscoveryService._connectWithRetry` currently wraps
`device.onConnect()` in a 10 s `Future.timeout` on non-Linux platforms. The
Android transport below it calls `UniversalBle.connect(... timeout: 20 s)`.
That means the outer quick-connect timeout can return first while the source
future and native attempt are still alive.

The quick-connect retry is host policy. It must remain a single retry owner:
waiting for native admission is not a connect failure and must not consume a
retry/backoff slot.

### Direct machine / scale connect

`ConnectionManager._connectMachine` and `_connectScale` wrap controller
connect futures in `_connectTimeout` (normally 30 s). Dart `Future.timeout`
does not cancel the source future. A source that finishes later can therefore
still reach controller adoption unless adoption is fenced by the exact
attempt that timed out.

`De1Controller` and `ScaleController` now have a connection-generation fence
around their awaited connect/readiness boundary. Invalidating that generation
prevents a late completion from adopting the candidate or clearing a newer
controller generation. The manager still needs to bind that invalidation to
the exact host attempt lease.

### Background ScaleWatch

`ScaleWatch` already has a useful generation fence. `disarm()` increments the
generation and its sighting/connect continuation checks that generation before
re-arming. Preserve that ownership model instead of introducing a second
background scheduler.

### Scan ownership

Burst/watch ownership is tracked in `UniversalBleDiscoveryService`, including
pause/resume around burst scans. One hazardous edge remains:
`_stopScanForConnect()` directly calls `UniversalBle.stopScan()` when the
owner is not `burst`. If the owner is `watch`, the native scan can stop while
Decaid still records the watch as active. The integration must transition the
watch owner/phase through the existing deactivation path and must not leave a
dead watch marked active or restart an overlapping scan.

This must be coordinated with upper `ScaleWatch` state: deactivating only the
lower watch would leave the upper watcher armed with no native scan. The fix
therefore needs an explicit pause/resume or ownership hand-off, not a bare
`stopScan()` replacement.

### Plugin-owned BLE sessions

Plugin BLE sessions have their own authorization/session lifecycle. They must
not be pulled behind a new app-global mutex. Native admission in
`universal_ble` is the platform coordination boundary; Decaid only fences its
own policy attempts and candidate adoption.

## Ownership rule

A connect attempt is identified by normalized device id plus a monotonic
attempt generation. Cancellation invalidates that exact generation but keeps
its ownership slot reserved until the source operation settles and cleanup is
safe.

Consequences:

- a timed-out or cancelled attempt can never adopt a device later;
- an old cleanup cannot release or cancel a same-address replacement;
- duplicate requests for the same device coalesce/conflict while the retiring
  attempt still owns the slot;
- different device ids remain independent at the Decaid layer;
- repeated cancellation is idempotent and preserves the first owner/reason;
- no process-wide GATT mutex is introduced.

`ConnectionAttemptOwner` is the small primitive for this rule. The controller
local generation fences are in place. The remaining manager wiring must bind a
lease to each machine/scale source future, invalidate its controller generation
when cancellation wins, retain the lease after caller-visible timeout, await
that exact source, run owned cleanup only afterwards, and settle/release last.

## Timeout / cancellation chain

The final wiring should make each boundary explicit:

| Boundary | Owner | Required behavior |
| --- | --- | --- |
| UI/API call | Decaid | bounded result; cancellation invalidates only its attempt |
| remembered quick connect | Decaid | one host retry; no orphaned source future |
| admission wait | `universal_ble` | queued wait is not a GATT failure/retry |
| native connect | `universal_ble` | bounded exact attempt; cancel/timeout removes only that request |
| MTU/services/protocol readiness | transport/device | bounded operation; no late adoption after owner cancellation |
| teardown/close | `universal_ble` + owned Decaid cleanup | hold ownership until terminal close or explicit recovery-blocked state |

An outer deadline is not allowed to merely abandon a source `Future`. If a
caller-visible timeout wins, the exact Decaid lease is cancelled immediately;
a replacement for that device stays blocked until the source settles or the
lower layer reports a bounded terminal recovery state.

Cleanup must not race a source connect that is still pending. The required
retirement sequence is:

1. invalidate the exact lease/controller generation;
2. return the bounded caller-visible result when appropriate;
3. await the exact source future to settle;
4. perform cleanup belonging to that exact attempt;
5. release the lease last.

The retirement task itself must remain shutdown-owned so `shutdown()` cannot
complete while source or cleanup work is still outstanding.

## Retry policy

Decaid remains the retry-policy owner:

- quick connect: at most one retry for an actual native connect failure;
- unexpected machine disconnect: existing bounded exponential backoff;
- preferred scale recovery: existing watch first, legacy timer fallback;
- duplicate triggers while an attempt is active: coalesce/conflict, do not
  start another native attempt;
- admission wait/cancellation: never counted as a GATT failure;
- `RECOVERY_BLOCKED`: surface and stop retrying until the lower owner becomes
  terminal instead of creating a retry storm.

## Fault policy

| Fault | Decaid action |
| --- | --- |
| user cancels scan before connect starts | invalidate queued/early attempt; no later adoption |
| caller timeout while source still runs | cancel exact lease, return timeout, keep slot owned; cleanup only after source settlement |
| adapter off | invalidate BLE attempts, stop scans/watch, wait for powered-on recovery epoch |
| stale completion from older generation | discard; it cannot mutate controller preference/readiness |
| teardown failure / `RECOVERY_BLOCKED` | keep ownership, surface diagnostics, do not start same-device replacement |
| unexpected disconnect after healthy ready | existing machine/scale recovery policy owns retry |
| background watch stop for connect | transition both lower scan owner and upper watch state before native stop |
| shutdown | invalidate attempts first, await exact source + owned cleanup, then finish teardown |

## Implementation slices for this draft

- [x] Add exact-attempt ownership primitive and deterministic unit tests.
- [x] Fence `De1Controller` and `ScaleController` adoption with connection
  generations so stale completions cannot adopt or clear a newer generation.
- [ ] Bind `ConnectionManager` machine/scale attempts to exact leases and keep
  a timed-out lease owned until source -> cleanup -> release completes.
- [ ] Preserve the existing shutdown contract: no candidate cleanup while its
  source connect is still pending, and shutdown waits for retirement.
- [ ] Make user scan cancellation invalidate only scan-owned early attempts.
- [ ] Remove/replace the orphan-producing quick-connect outer timeout while
  retaining one host retry owner.
- [ ] Route watch-owned stop-for-connect through an explicit lower/upper watch
  ownership hand-off so the watch is not left falsely armed.
- [ ] Expose active/cancelled/retiring attempt diagnostics from the manager.
- [ ] Add regressions for cancel-while-queued, timeout-before-start,
  timeout-after-native-start, late success, replacement blocking, retry
  fairness, shutdown ordering, and scan/watch ownership.
- [ ] Once `universal_ble#28` is green, pin its exact immutable SHA in
  `pubspec.yaml` + `pubspec.lock` and run the focused Flutter/Android matrix.

## Merge gates

This draft is not mergeable until all of the following are true:

1. #875 has enough evidence to keep the native solution selected.
2. `tadelv/universal_ble#28` has a reviewed green head and the required Android
   helper/plugin tests pass on that exact head.
3. Decaid controller adoption, manager retirement, and quick-connect are
   cancellation-safe under an outer timeout without cleanup/source overlap.
4. existing shutdown ordering plus new late-success/replacement regressions
   pass.
5. burst/watch scan ownership regressions pass.
6. #867 scale-power behavior is unchanged.
7. the exact fork SHA is recorded in both dependency files and the Decaid
   Flutter/analyze/Android checks pass.

Final hardware acceptance remains part 5/5 (#877); this PR must not close the
parent #871 by itself.
