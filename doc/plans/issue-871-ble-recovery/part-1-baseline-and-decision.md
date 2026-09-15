# Issue #871 BLE recovery — part 1: baseline, evidence, and decision gate

Tracking issue: https://github.com/decentespresso/decaid/issues/875
Parent: https://github.com/decentespresso/decaid/issues/871
Date recorded: 2026-09-15

This document freezes the evidence and comparison contract for the first work
package of #871. It deliberately separates the observed field incidents from
hypotheses about their cause. It is not an implementation approval for the
native admission candidate and it is not affected-device validation.

## 1. Immutable version matrix

| Evidence / build | Decaid revision | `universal_ble` | Android / hardware | Scale / power policy | What is established |
| --- | --- | --- | --- | --- | --- |
| #868 field report | `75a1b66c` (build 2772) | historical dependency resolved by that build; do not substitute a later fork revision when reconstructing this run | Android 10, `treble_arm64_bvS-userdebug 10 QQ3A.200805.001 eng.crossg.20210808.170014 test-keys`; affected Teclast-class tablet | Original full-height Decent Scale, reported original FW marker `0x02` -> 1.1. At that revision `displayOff` fell back to BLE disconnect when HDS SoftSleep was unavailable. | Original-scale protocol negotiation succeeded; valid notifications were received; a later native `Connection Timeout` occurred on the scale without the old periodic-maintenance-write signature; recovery was followed by a DE1 timeout and later connection failures/133. |
| #874 field report | `662f0cfc` (build 2774) | historical dependency resolved by that build | Same reported Android 10 ROM class as #868 | Original full-height scale, FW 1.1; old `displayOff` fallback still intentionally disconnected the BLE link | The scale was identified correctly and streamed for roughly 30 minutes. The observed drop at sleep was application-requested by the old power policy, not evidence of a native transport timeout. |
| Current protocol/power baseline for A/B | PR #867 head `e10199045796f4107d63386b83ef92ff7b11edc9` at this recording | `16bbfbce197eb5913c6b16578363f7dc943e605d` (`universal_ble` 2.2.6 fork pin, confirmed in `pubspec.lock`) | Original-scale affected device still requires re-validation; HDS 3.1.14-custom has a successful hardware pass recorded in #867 | `ScalePowerMode.displayOff` sends shared `0A 00` and preserves a healthy original/unknown/pre-modern-HDS BLE connection. Explicit disconnect mode is separate. | This is the application baseline that must be identical in A and B. Do not compare the native candidate against the older disconnect-on-display-off policy. |
| Decaid `main` from which this diagnostic PR branches | `0de2d025ae4e0c63fbae3333300985cc8db4ab21` | `16bbfbce197eb5913c6b16578363f7dc943e605d` | n/a | #867 is not merged into this base | This PR can add neutral diagnostics/documentation without pinning the candidate or entangling the scale protocol branch. |
| Native admission candidate | `tadelv/universal_ble` PR #25 head `ac8427a466f122a072756639a4a850ef4cafef51` at this recording | candidate relative to fork base `16bbfbce197eb5913c6b16578363f7dc943e605d` | Android implementation candidate; affected hardware not yet validated | Must be paired with the exact same #867 application/power behavior as baseline A | Candidate serializes unresolved direct native connection establishment. Its reported standalone Kotlin scenarios are useful regression evidence, not proof of the field root cause or Android hardware success. |

`dart_js` remains unchanged. No evidence in #868 or #874 implicates the JS engine,
so no `tadelv/dart_js` work is part of this decision.

## 2. Separately attributed field timelines

The original field attachments are linked from the issues but are not committed
to this repository. The timelines below therefore include only events that are
already preserved in #871/#867/#874 metadata. Exact relative timestamps and
native object identities remain an evidence gap until the raw support bundle or
logcat is attached to #875.

### 2.1 #868 — residual transport/recovery incident

Source build: `75a1b66c`, Android 10 build 2772.

Established ordering:

1. Original Decent Scale connects.
2. Status evidence identifies original firmware marker `0x02` / FW 1.1.
3. HDS `0x22` capability probe receives no valid response; HDS-only SoftSleep is
   withheld.
4. The scale streams valid notifications.
5. Later, the scale transport publishes `Connection Timeout`.
6. There is no preceding DecentScale periodic maintenance/status write failure
   in the cited PR-build sequence.
7. Scale rediscovery/reconnect starts; #871 records a reconnect after roughly
   20 seconds.
8. Shortly afterward the DE1 transport also publishes `Connection Timeout`.
9. Subsequent scale/machine connection attempts encounter Android connection
   failures including GATT 133 / unknown-error reporting.

What this does **not** establish:

- whether the first scale timeout was caused by the app, peripheral, controller,
  Android host stack, notification starvation, or a native operation already in
  flight;
- whether two `connectGatt` calls overlapped at the moment of the later 133;
- whether a stale native GATT client survived teardown;
- whether a Dart queue generation was faulted at either native link timeout;
- exact owned-client count or callback/close ordering.

Therefore #868 supports a residual multi-device recovery problem, but it is not
proof that cross-device connection concurrency caused the initial link loss.

### 2.2 #874 — power-policy correction, not the same failure

Source build: `662f0cfc`, Android 10 build 2774.

Preserved evidence in PR #867 says:

1. The real original full-height scale is correctly identified as FW 1.1.
2. It streams for approximately 30 minutes.
3. Machine sleep enters `ScalePowerMode.displayOff`.
4. The then-current policy logs `Decent scale: disconnecting for sleep
   (SoftSleep unavailable)` and deliberately tears down the scale link.

That event is not equivalent to the unexplained #868 native timeout. #874
instead exposed an incorrect product policy: lack of HDS SoftSleep capability
must not turn display-off into BLE disconnect. Current #867 corrects that by
sending shared `0A 00` and preserving a healthy link.

Consequence for #871: the historical acceptance step "displayOff -> original
scale disconnect -> reconnect on wake" is obsolete. Baseline and candidate must
both exercise display-off/wake without intentional reconnect churn, while
explicit disconnect power mode is tested separately.

## 3. Architecture facts relevant to the hypotheses

These facts are directly visible in the current trees and are not field-cause
claims:

- Decaid configures `universal_ble` with per-device Dart command queues.
- `BleLifecycleGate` serializes lifecycle work by normalized device ID, not
  globally across all BLE peripherals.
- `EarlyConnectWatcher` can start the preferred machine and preferred scale
  connection futures independently during the same discovery run.
- The fork candidate documents that `UniversalBle.connect()` is a direct native
  connection path rather than a queued GATT read/write operation.
- The Android fork already has per-device connect/disconnect cooldown handling;
  the candidate adds a separate admission owner for unresolved direct connects.

These facts make cross-device native establishment/recovery concurrency a
credible recovery hazard. They do not show that Android must never receive
concurrent connection requests, nor that concurrency explains the first #868
link timeout.

## 4. Diagnostic boundary in this PR

The existing diagnostic skin already exports `/api/v1/diagnostics/ble`, device
WebSocket events, machine snapshots, scan/watch ownership and advertisement
statistics. This PR extends the read-only BLE snapshot with:

- `diagnosticsVersion: 2`;
- a UTC wall-clock timestamp plus a Dart `Stopwatch` monotonic millisecond value
  for ordering and deltas within the running process/isolate. The monotonic
  origin is deliberately unspecified and must not be assumed to share Android
  `elapsedRealtime`'s epoch; use UTC wall time to correlate with native logcat;
- one bounded logical snapshot per currently cached device: id, name, device
  type, transport, object instance identity, logical connection state and
  available firmware/battery information;
- preferred machine as well as preferred scale identity;
- the current connection error and transport conditions.

Each device-state sample is bounded to 250 ms. A silent or failed state stream
must not make field diagnostics hang or trigger BLE work.

The following evidence is intentionally **not fabricated in Decaid** and remains
owned by the fork/native work package (#27): native request/admission/callback/
close timestamps, native numeric status, native client identity/owned-client
count and teardown confirmation. Per-device queue-generation/active-operation
metadata must be exported at the BLE boundary if it is needed for the final
field bundle; a webserver handler must not reach around that boundary to import
third-party BLE implementation details.

For field correlation, capture the exported diagnostic report and native
`UniversalBle` logcat together. A Dart-only support bundle must not be described
as proof of native GATT disposal.

## 5. A/B comparison contract

### Baseline A

- Decaid application behavior: current #867 revision (or a later revision with
  identical scale-power semantics).
- `universal_ble`: `16bbfbce197eb5913c6b16578363f7dc943e605d`.
- Original scale: affected full-height scale, FW 1.1.
- `displayOff`: shared `0A 00`, no intentional BLE disconnect.

### Candidate B

Identical to A except for the reviewed immutable `tadelv/universal_ble` commit
produced by work packages #26/#27. Do not combine the comparison with another
scale protocol, retry, timeout or power-policy change.

### Measurements

For every recovery episode retain:

- peripheral availability/fresh advertisement evidence;
- app request time, admission/native start time when available, native terminal
  callback, protocol-ready time;
- native status/error class;
- attempts per device;
- logical peer state and current connection conditions;
- healthy-peer notification gaps;
- native client create/close/owned counts when candidate diagnostics are
  available.

Report prevention and recovery separately:

1. **initial dropout rate** during healthy dual-device operation;
2. **recovery correctness/latency** after a real loss or injected native fault.

A candidate that only improves recovery must not be reported as preventing the
initial timeout.

## 6. Targets fixed before affected-device validation

These thresholds are selected before seeing candidate hardware results:

- If both peripherals are actually available, both must regain protocol
  readiness within **120 seconds** after a recovery episode.
- At most **3 new native connection attempts per device** are allowed after the
  device becomes available in one recovery episode.
- A healthy peer must have **zero application-initiated teardown** solely to
  repair the other device.
- For healthy-peer notification continuity, compute baseline A's p95 valid
  inter-notification interval from the healthy pre-fault segment. The failure
  threshold is `max(5 seconds, 10 x baseline p95 interval)`. Keep raw gaps and
  p95/max values in the report; do not tune the threshold after candidate data
  is observed.
- After quiescence there must be **no progressive growth** in native owned GATT
  clients, pending admission tasks or logical listeners across repeated cycles.
- A cancelled/expired connection attempt may produce **zero late adoption or
  late replacement teardown**.

The final test budget is owned by #877. Its current proposed matrix (8-hour dual
soak, 50 display-off cycles, 20 each scale-only loss, machine-only loss and dual
loss covering both orders) is appropriate unless #875 records a reason to
change it before execution.

## 7. Decision record

### Preferred implementation boundary

**Proceed with the narrow native direct-connect admission/lifecycle candidate in
`tadelv/universal_ble` as the preferred recovery-hardening solution to evaluate,
subject to #26/#27 integration review and affected-device A/B validation.**

Reasoning:

1. It closes a concrete ownership gap at the layer that allocates native GATT
   clients: independent app connection paths can otherwise reach native
   establishment without a cross-device admission owner.
2. It does not require a global steady-state GATT mutex; established DE1 and
   scale reads/writes/notifications remain independent.
3. It gives cancellation, stale-callback and teardown ownership one native
   authority instead of duplicating a scheduler in ConnectionManager.
4. An existing draft (#25) already exercises the core state-machine idea and is
   constrained to the fork Decaid actually pins.
5. The approach does not require speculative adapter resets, bond removal,
   cache refresh, protocol heartbeats or `dart_js` changes.

### Important limit of this decision

This is a decision about the **preferred recovery boundary**, not a root-cause
finding for the first #868 timeout. If current #867 display-off semantics remove
the residual field problem and no unexplained transport failure can be
reproduced, there is no requirement to merge a speculative native change. If a
failure reproduces while establishment is already serialized, the evidence must
redirect #26/#27/#876 rather than forcing the FIFO theory.

### Alternatives not selected as the default

- **Global Dart GATT command queue/mutex:** rejected. Current queues are
  intentionally per device, and steady-state peer traffic must remain
  independent.
- **ConnectionManager-only global connect lock:** not preferred. It would leave
  other host/native entry points and teardown ownership split across layers.
- **Automatic adapter reset / Bluetooth toggle / bond removal / cache reset on
  133:** rejected without separate evidence; 133 alone is not proof of adapter
  poisoning.
- **Another Decent Scale protocol workaround:** rejected for this incident. #867
  already separated original/HDS protocol behavior, and #874's power-policy
  correction must be held constant in A/B.

## 8. Open evidence gates before #875 can be considered complete

- Attach/import the raw #868 and #874 support artifacts or an equivalent
  timestamped excerpt so exact event offsets can be independently reviewed.
- Capture a baseline A run on the affected original-scale Android device using
  current #867 display-off semantics.
- Capture native logcat or equivalent bounded native diagnostics so connection
  admission, callbacks and GATT close are not inferred from Dart state alone.
- Re-run the candidate's deterministic/native Android tests on the final fork
  commit selected by #26/#27; historical reported results do not carry forward
  automatically.
- Execute the A/B hardware matrix under #877 before claiming the selected
  recovery implementation fixes the field incident.

Until those gates are satisfied, this PR should remain draft and #875/#871
should remain open.
