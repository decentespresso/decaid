# Host-owned BLE drivers and plugin Scale

Status: archived; implementation, automated verification, and the current Felicita-only hardware acceptance gate are complete. Bookoo hardware remains an optional follow-up.

## Baseline

- Issue: https://github.com/decentespresso/decaid/issues/809
- Reviewed revision: 2026-09-07T12:02:20Z; no comments.
- Starting commit: bc717af2089798b32dfd21ffc1227a808d4b38d2.
- Worktree: E:/projects/decaid-issue-809.
- Branch: odev/issue-809-plugin-ble-scale.
- Assignment: issue-809-pr-implementation-prompt.md, including amendments A-D.
- Publishing, merging, and closing the issue are not authorized.

The original checkout predates the Sensor and network transport prerequisites
and has unrelated local changes. The user authorized an isolated worktree from
updated origin/main. Those changes are not part of this implementation.

## Ownership and API Decisions

The existing discovery service remains the sole scanner. Advertisement evidence
is evaluated before native matching, including its empty-name gate. Evidence is
owned by a discovery generation and physical ID, with source, observation time,
and explicit field completeness. Complete observations replace older evidence;
incomplete system metadata cannot erase a complete advertisement in the same
generation.
Complete observations outrank incomplete ones regardless of source; equally
complete observations use observation time. A complete absent name is negative
evidence, while unavailable name metadata remains indeterminate.
Never merge observations across generations to manufacture a match.

Matchers return match, noMatch, or indeterminate. AND predicates short-circuit
on a proven false; service lists retain any-of semantics. Two definite matches
conflict; unresolved competitors defer that device; all definite negatives permit
native matching. The normal scan deadline terminates unresolved ownership with
diagnostics. Registry changes invalidate unconnected candidates. Connection
admission checks registry generation and physical ownership again. Remembered
native connections must pass arbitration too; plugin quick-connect remains absent.

Physical identity is the normalized platform BLE ID. Binding identity is the
host-owned tuple (plugin ID, driver ID, physical ID). Public IDs use
plugin:<pluginId>:<driverId>:<normalizedPhysicalBleId> and are never parsed for
authorization. Session identity adds plugin generation and a fresh attempt ID.
Capacity is reserved before native connect and held through unresolved teardown.
One active binding per plugin generation is production policy, not singleton state.

host.devices.bindDriver(driverId, {create}) registers a factory, not an instance.
It requires a declared BLE driver and transport.ble. Registration cannot await
hardware. Initial registry readiness settles after the existing loader watchdog
has completed, failed, or disabled each initial plugin load.

host.devices.register(definition, handlers) remains the plugin-created path.
Declared Scale drivers use the same transport-independent adapter as BLE Scale
bindings and do not require BLE permission. Existing Sensor callers remain valid.
Scale handler names are connect, disconnect, tare, startTimer, stopTimer,
resetTimer, sleepDisplay, and wakeDisplay, gated by declared capabilities.

Each connect invocation receives session-bound publish/reportDisconnected methods.
Persistent binding metadata cannot redirect old callbacks into the current session.
The host validates session authority, including direct bridge calls. Existing
Sensor registration semantics are preserved; new BLE and Scale paths require
explicit session authority. Normal commands and publications reject after retirement.

## Retirement and Native Safety

Internal states: connecting -> initializing -> ready -> retiring -> revoked ->
closed. Public ConnectionState values do not change. Failure may retire before
ready. Retired sessions never reactivate.

Deliberate disconnect fences normal calls and notifications first. A live runtime
and link may receive a bounded disconnect invocation with a separate cleanup-only
GATT capability. It is scoped to that invocation and session, never an ambient
permission flag. Completion, deadline, permission loss, or link loss revokes it.
Then native subscriptions/resources are cleaned up through the existing transport.
Terminal callbacks occur at most once while the runtime is valid, after revocation.

A Dart timeout or completed disconnect request is not native teardown confirmation.
Per-device exclusion persists until the native lifecycle/queue recovery permits
reuse; other devices remain independent. Late work cannot mutate a replacement
session. No additional scheduler, protocol retry, or uncertain-command replay.

GATT UUIDs normalize to canonical lowercase 128-bit strings. Payloads remain
base64. Enforce encoded size before decoding and decoded size after native reads.
Limits: 8 subscriptions, 16 pending operations, 16 KiB read/write payload,
256 queued notification events, 64 KiB queued notification bytes per binding.
Overflow fails that session rather than losing protocol data silently.
Subscription instances have distinct identities; old unsubscribe cannot cancel
a replacement. Forwarding is installed before native subscription can emit.

## Scale Readiness and Timing

Scale readiness requires successful initialization AND an accepted finite signed
weight. A bounded first-sample handoff survives ScaleController activation and
feeds the estimators once. Battery is nullable; capabilities validate optional
battery, flow, and timer telemetry. Missing optional commands report
unsupported_operation; automatic callers gate support without hiding link errors.
Disconnect-to-sleep uses deliberate host intent and existing wake/recovery policy.

Timing acceptance uses deterministic estimator fixtures and identical native and
full-JS traces through ScaleController under a controlled clock/scheduler. Compare
order, output, freshness, stop decisions, and delivery latency under normal cadence,
delayed dispatch, bursts, asynchronous publication, and backlog recovery. Felicita
hardware cadence supplies the required live-device evidence; Bookoo observations are
an optional follow-up. Do not retune estimators or widen tolerances.

If publication ingress fails, add bounded session-owned notification provenance
captured before JS dispatch, passed as a notification callback argument and
returned with publication. JS cannot supply authoritative timestamps. Reject
foreign, expired, duplicate, or out-of-order provenance; retain a documented host
ingress fallback for non-BLE/synthetic samples. Document clock-change behavior.

## Contract Amendments and Current-Code Conflicts

- A replaces the issue's contradictory cleanup order with retirement followed by
  invocation-scoped cleanup and revocation before terminal notification.
- B replaces missing-field negative matching with explicit uncertainty. The
  public #809 matcher contract was updated on 2026-09-07 to include this approved
  amendment; complete negative evidence still produces noMatch.
- C extends the public registration path, not just a Dart Scale constructor.
- D makes publication-ingress timestamps provisional pending timing evidence.
- Existing Sensor publish/reportDisconnected handles are generation-owned but
  not connection-session-owned. Reusing those handles for Scale/BLE is unsafe.
- Existing native transport disconnect and dispose need auditing for confirmed
  teardown; completion alone cannot be used as a physical ownership release.
- Existing discovery imports universal_ble outside services/ble. Do not extend
  that exception with plugin imports; new plugin code uses domain transport types.

## Requirement-to-Test Map

All rows are pending until executable tests and results are recorded.

| Requirement | Required test boundary |
|---|---|
| Declarations, permissions, UUIDs, capabilities | Manifest table tests and direct native bridge denial |
| Tri-state arbitration, both observation orders, conflicts/deadline | Discovery with fake advertisement/system evidence |
| Startup failure/timeout, registry churn during selection | Loader + registry + real selection integration |
| Physical ownership, capacity >1, stable public ID | Injected transport binding tests |
| GATT errors, acknowledgement, no replay, resource bounds | Direct bridge + fake native operations |
| Subscribe setup/replacement/old unsubscribe/overflow | Deterministic notification scheduling |
| Hanging/throwing cleanup, loss/revocation/repeated disconnect | Session lifecycle failure injection |
| Late completion and reconnect fencing | Two sessions sharing a physical ID |
| BLE Sensor proof | Advertisement -> real JS bridge -> Sensor inventory/API |
| Non-BLE Scale proof, commands, reload | Public register -> real JS bridge -> Scale REST/WS |
| First-sample readiness, invalid data, unknown battery | Adapter + activated ScaleController |
| Timing, stale data, provenance, clock changes, stop decisions | Identical native/JS traces through estimators |
| Sleep/wake versus protocol failure | ScaleController + ConnectionManager recovery |
| Bookoo parsing and exact commands | Shared native/JS byte fixture expectations |
| Plugin precedence, disabled fallback, failed handshake | Discovery/selection with native Bookoo retained |
| Restart preferences, no silent native repoint | Remembered quick-connect miss -> discovery/policy |
| Isolation and repeated lifecycle leak checks | Two devices + test-owned resource counters |
| Hardware behavior | Felicita plugin connection/readiness, live weight, commands, disconnect/reconnect, restart/reselection, and cadence |

## Implementation Stages

1. Inspect existing boundaries; add deterministic regression tests and this design.
2. Declarations, runtime registry, readiness gate, evidence and candidate arbitration.
3. Session-bound GATT, retirement, unsubscribe, limits, shutdown, BLE Sensor proof.
4. Shared Scale adapter, public non-BLE registration, nullable battery, timing gate.
5. Bookoo JS reference, native coexistence, persistence and isolation tests.
6. Failure/interleaving audit, docs/specs, formatting, focused/full tests, analysis,
   API smoke tests, hardware evidence and local PR-template handoff.

This design is archived with its implementation evidence. Bookoo physical testing
is not required by PR #823's current acceptance gate.

## Evidence

The initial declaration/matcher/registry primitives and manifest schema have 27
passing focused tests (including existing manifest tests). They are not yet integrated
into discovery or the JS bridge. This is not evidence for the end-to-end paths.

Declaration limits also bound name predicates to 248 characters and service
lists to 64 entries. These are manifest validation limits, not GATT packet limits.

2026-09-07 local verification, starting commit plus uncommitted changes:

- dart format lib test: exit 0; unrelated formatter-only changes removed.
- flutter test --no-pub test/plugins/plugin_ble_matcher_test.dart
  test/plugins/plugin_ble_registry_test.dart
  test/plugins/plugin_manifest_permissions_test.dart
  test/plugins/plugin_settings_schema_spec_test.dart
  test/plugins/plugin_manager_transport_tls_test.dart --concurrency=1:
  exit 0, 31 passed (27 declaration/schema tests plus 4 existing TLS tests).
- flutter analyze --no-pub: exit 0, No issues found (17.9 seconds).
- Full suite after making QuickJS available: exit 1, 3903 passed, 1 skipped,
  3 failed. The log is .build/issue-809-tests.log. The failures were missing
  openssl in TLS setup, the existing inbound transport overflow test timing out,
  and the existing unresolved BLE queue disconnect timing assertion. All three
  failing cases passed in focused reruns after supplying openssl. This does not
  constitute a clean full-suite run.
- Windows test commands need process-local PATH entries for
  C:/Program Files/Git/usr/bin and
  E:/projects/decaid/build/windows/x64-replay/runner/Debug. The latter supplies
  quickjs_c_bridge.dll from an existing local build. No system PATH was changed.
- Existing public JS Sensor registration/connect/publication/command test:
  exit 0 after supplying the QuickJS DLL. This confirms the test environment,
  not the new BLE Sensor proof.
- External plugin fetch scripts passed checksum/extraction but stopped at missing
  jq. Their remaining manifest/version/API/permission and createPlugin checks
  were inspected using PowerShell JSON parsing and rg. Bundled skin artifacts
  were copied from the existing local build, without modifying the source checkout.

No hardware acceptance is claimed. Bookoo hardware availability has not been
established. At this checkpoint no PR had been created or branch pushed.

### Scale Bridge Checkpoint

2026-09-07, starting commit plus local changes:

- Public `host.devices.register()` now composes the transport-independent Scale
  adapter. A connect context owns publication and failure reporting for exactly
  one session. Existing Sensor registration retains its public contract.
- Direct bridge Scale registration validates actual registered command handlers
  against host-owned manifest capabilities, rather than trusting wrapper checks.
- Added a regression for disconnect immediately after starting initialization.
  It failed with a readiness timeout before the fix and now cancels promptly.
  Readiness futures are captured per attempt rather than looked up after a late
  initialization completion.
- Focused Scale, Sensor service, BLE session, and native recovery tests: exit 0,
  49 passed.
- Real JS Scale and existing JS Sensor lifecycle tests: exit 0, 17 passed.
- dart format lib test: exit 0; unrelated formatter-only changes removed.
- flutter analyze --no-pub: exit 0, No issues found (11.4 seconds).
- Full flutter test --no-pub with the process-local QuickJS/openssl PATH:
  exit 0, 3926 passed, 1 skipped (2 minutes 28 seconds).
  Raw log: .build/issue-809-tests-latest.log.
- Added a direct-bridge missing-handler rejection test after that full run.
  Focused plugin_manager_scale_test.dart: exit 0, 2 passed.

This is an implementation checkpoint, not issue acceptance. BLE registry/session
primitives still need wiring into discovery and the public GATT bridge. Scale
REST/WS integration evidence, automatic optional calls, deliberate sleep policy,
timing acceptance, Bookoo reference, preference/restart tests, and hardware
validation remain open. Keep the design active and use Refs #809.

### PR Review Corrections

Review baseline: 5767a253198cc3e59e52009a87a78fcc041dc59a.

- Retire all active manager connect invocation IDs for the registration before
  dispatching disconnect, not just invocations that reached the manager timeout.
  Cancel their watchdogs, settle pending callers, and reuse bounded disconnect
  cleanup to close invocation-owned transports. Late JS results cannot authorize
  more transport opens. The adapter still owns its readiness deadline.
- Clear the adapter disconnect future in finally and tolerate a previous cleanup
  error when reconnect waits for it. The original disconnect caller retains the error.
- Use the existing native resetSubscription path for replacement. Native reset
  retains its Dart listener, so tuple forwarding resolves the current logical ID;
  an old logical unsubscribe cannot remove the replacement.
- Regression tests first reproduced both reconnect failures, an authorized late
  JS WebSocket open, and notification -> notification without a disabled step.
  Focused Scale/manager/Sensor/BLE/native recovery suite: 67 passed, exit 0.
- Full flutter test --no-pub: 3931 passed, 1 skipped, exit 0 (2m34s).
  Raw log: .build/issue-809-review-tests.log.
- flutter analyze --no-pub: No issues found, exit 0 (12.8s).
- CI-compatible dart_style 3.1.13 formatting of lib and test: 806 files,
  zero remaining changes. git diff --check: exit 0.

These corrections do not complete the remaining integration or hardware gates.

### Evidence Completeness Corrections

2026-09-08, review baseline 154f798a:

- Name completeness now reaches matcher evaluation through registry evidence.
  Known absence is noMatch; unavailable metadata remains indeterminate.
- Cache replacement compares completeness before freshness, independently of
  source, and retains whole observations without merging fields.
- Matcher/registry tests: 18 passed, including both arrival orders, known absence,
  unavailable metadata, freshness, and existing generation/no-merging coverage.
- Full flutter test --no-pub: 3936 passed, 1 skipped, exit 0 (2m45s).
  Raw log: .build/issue-809-evidence-tests.log.
- flutter analyze --no-pub: No issues found, exit 0.
- CI-compatible formatting: 806 files, zero remaining changes; diff check clean.

Discovery integration and the other draft acceptance gaps remain open.

### Suspended Connect Bookkeeping

2026-09-08, review baseline 55193d20:

- Retirement removes the manager connect attempt immediately, denying subsequent
  claimed transport opens even if the JS Promise never settles.
- The transport retirement fence remains through bounded cleanup and transport
  closure, then finishDeviceConnect releases it in finally on success or failure.
- Real QuickJS regression repeats four never-settling connect/disconnect cycles
  for successful, throwing, and timed-out cleanup. Both tracking counts return
  to zero before the next attempt. The previous late-open regression also checks
  zero tracking counts before resuming its stale handler.
- Before the fix, each cleanup variant retained one attempt and one fence.
  Focused Scale/Sensor manager suite after the fix: 22 passed, exit 0.
- Full-suite rerun: 3939 passed, 1 skipped, exit 0 (2m23s), recorded in
  .build/issue-809-retirement-tests-rerun.log. The initial run had one WebUI
  port-3001 bind failure; that test passed alone before the clean full rerun.
- Analysis: No issues found. CI-compatible formatting and diff checks are clean.

### Disconnect Authority Boundary

2026-09-08, review baseline 657f3356:

- Removed the adapter's independent disconnect timeout. The manager bounds the
  handler and closes invocation-owned transports before its future settles;
  the adapter cannot publish disconnected or admit reconnect ahead of that future.
- Scale retirement also gathers owned transport invocation IDs from the transport
  records. A successfully completed connect no longer escapes host cleanup merely
  because its pending invocation record has already been removed. Sensor behavior
  and unrelated plugin-owned network transports remain unchanged.
- Real WebSocket regressions use the production five-second adapter and ten-second
  manager deadlines. Both suspended and successful first connects stay disconnecting
  past five seconds. Replacement waits for manager cleanup; old-context send then
  rejects, the server receives no frame, and only the replacement transport remains.
- Both regressions failed against the prior implementation. Focused Scale/Sensor
  manager and Scale adapter tests after the fix: 30 passed, exit 0.
- Direct adapter test invokers now model the manager's bounded disconnect result,
  rather than relying on a second adapter timeout to permit unsafe reconnect.
- Full suite: 3941 passed, 1 skipped, exit 0 (2m37s), recorded in
  .build/issue-809-disconnect-boundary-tests.log. Analysis and CI-compatible
  formatting are clean; diff check passed. Existing draft acceptance gaps remain.

### CI Runtime Gate

2026-09-08: CI run 34208704713 passed the assertions but rejected the Scale
manager suite's 21.212 seconds of active time against its 20-second limit.
PluginDeviceService now forwards an injectable Scale invocation deadline while
retaining the five-second production default. The two retirement regressions use
250 ms for the adapter and one second for the manager, checking at 300 ms that
reconnect remains blocked. This preserves production deadline ordering without
two ten-second waits; no timeout or assertion was removed from the regression.

Full local suite: 3941 passed, 1 skipped, zero failures. The CI active-time gate
passes for every file. Analysis and formatting are clean. Events are recorded in
.build/issue-809-runtime-gate-tests.json. Both fixed BLE-evidence review threads
were marked resolved. The externally changed PR draft status was left unchanged.

### Completed Connect With No Transports

The subsequent review's claimed late-open bypass is already denied manager-side:
hasDeviceConnectClaim with no matching active invocation fails before transport
dispatch. Removing the completed invocation revokes its open authority; retaining
an additional session record or transport fence is unnecessary for that denial.
The real bridge registration test now saves the first connect context, completes
connect and reconnect without any live transports, checks both bookkeeping counts
are zero, and verifies old-context open returns "Plugin device connect retired".
The fixture has network permission, so permission denial cannot mask the result.
Full verification: 3941 passed, 1 skipped; all suites pass the 20-second active-time
gate. Analysis and formatting are clean. Events: .build/issue-809-zero-transport-tests.json.

### Final PR #823 Acceptance

The current PR gate requires Felicita hardware verification rather than Bookoo
hardware. `doc/plans/archive/issue-809-felicita/hardware-evidence.md` records
connection and readiness, continuous weight delivery, tare and timer commands,
confirmed disconnect, reconnect and reselection after a power cycle, hot restart,
and notification cadence on Android. Those results satisfy the hardware gate;
Bookoo physical testing was not performed and is not claimed.

The final corrective software tree pins `tadelv/universal_ble` PR #24 at
`9c50e12fcc33b061fe37e7037c69e44e30d96c79`. Upstream checks are green. Decaid's
focused BLE/plugin set passed 395 tests; the serialized full suite passed 4110
with one skip; formatting, analysis, and diff checks are clean.
