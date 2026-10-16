# Shot Upload Ownership

## Behavior

Validate the payload's original machine serial against the account's machine list before sending a shot. Pause a missing or HTTP 403 serial without marking its shots permanently rejected, and continue uploads for other serials. Preserve local history and capture-time identity.

Treat HTTP 401 as an account-wide authentication pause with a sign-in notice. Machine-list outages or invalid responses hold uploads with backoff, without claiming the machine is unlinked. Keep existing transient upload retries and permanent document rejection handling.

Refresh ownership on startup and account identity changes. Confirm a serial is linked before resuming it. Settings changes and manual upload do not bypass a known pause.

## Implementation

Change the source-of-truth shot-upload repository, not Decaid's generated plugin assets. Extend its existing status and emitted events with pause details. Add a narrow Decaid account-change event and native pause notice with an account/support action. Keep credentials in the existing authenticated proxy.

## Verification

Add regression tests before implementation for mixed ownership, 403 suppression, 401 suppression, outage recovery, account-change recovery, restart, and manual/replacement paths. Test native notice rendering and lifecycle cleanup, account event delivery, and proxy error codes. Run JavaScript checks, relevant Flutter tests, analysis, the full Flutter suite, and a local runtime smoke check where the lab permits it.

## Delivery

Prepare separate linked draft PRs for the uploader and native host support after
the user's publication request. A released plugin ZIP and a subsequent verified
Decaid pin update remain release work. Historical ownership authorization stays
a server policy; do not rewrite or delete shots to work around it.

## Evidence

### Isolated Draft Branch

On 2026-10-16, the host changes were ported onto upstream main `b9f9d055`
without unrelated workspace edits. Flutter 3.44.8 / Dart 3.12.2 resolved the exact
lockfile. Analysis found no issues; formatting changed none of the 11 affected
Dart files. The four focused regression files passed all 14 tests.

The full suite recorded 4,965 passed, two skipped, and seven failures. All seven
reproduced in the two affected scale suites on an unchanged checkout of the same
main revision (24 passed, seven failed). The local Windows QuickJS runtime rejects
BigInt literals: the failures are one parser-error mismatch, three
`resource_limit` mismatches, and three timeouts in `plugin_scale_api_test.dart`
and `plugin_scale_timing_test.dart`. These unrelated runtime checks were not
changed. The uploader's isolated main-based branch passed all 59 Node tests.

### Earlier Source And Device Checks

JavaScript: 59 tests passed. Focused Flutter checks: 176 tests passed. A local,
ignored smoke test loaded the source plugin in Decaid's native QuickJS runtime
with a mocked upstream and verified one 403 POST, no repeat for that serial,
continued uploads for another linked serial, and recovery after an account
refresh. A second native check covered the host auth-failure event preceding a
401 response and verified an immediate authentication notice. No real
credentials, customer records, hardware, or production requests
were used.

Full Flutter suite after the Android smoke correction: 4,474 passed, 2 skipped,
1 existing Windows path-separator
failure in `test/unit/services/export/archive_export_delivery_test.dart:35`.
Analysis of `lib` and `test` found no issues; repository-wide analysis reported
six existing warnings in the unrelated reliability-audit checks.

The native runtime's rejection tracker reported a cached pause thrown before the
first await as unhandled, despite later handling. Yielding one microtask before
the ownership guard eliminated that diagnostic; the native smoke check passed
without it afterward.

## Review Corrections

The Astra xhigh review found three recovery races. Stale GET and POST failures
now check the captured account generation before changing pause, consent,
rejection, or retry state. Accepted uploads remain recorded even if the account
changed while the request was pending.

Active live uploads and backlog scans preserve an immediate ownership check
when their generation changes. The backlog cursor resets to zero so an earlier
skipped shot does not wait for a later full-library pass.

The native Support-return callback invalidates uploader ownership before the
host refreshes its account cache. The plugin's existing lookup/backoff handles
a temporary host-refresh failure without another support visit or restart.
There is no second native retry mechanism.

Regression tests cover stale auth and consent failures, old HTTP 400/401/403
responses, host auth-failure event ordering, busy live uploads, long backlogs,
failed support refresh, and late successful uploads. Astra's focused re-review
found no remaining actionable defects in these fixes. Desktop browser-return
lifecycle behavior remains unverified; the later Android check is below.

The account lookup uses an awaited async request with try/catch/finally to avoid
native rejection-tracker diagnostics from an intermediate rejected promise in a
chained catch/finally. Both native smoke checks passed without that diagnostic.

The shared native proxy also guards its authentication-failure callback. It
captures the account's authentication generation before any await, compares the
credentials sent with current stored credentials, and rechecks the generation
after that read immediately before invalidation. This prevents an old HTTP 401
from invalidating a newer login, including one that reuses the same credentials.
The upstream response remains unchanged. Six real-account-service regressions
cover changed and same-credential logins, a change during credential rereading,
consent overlapping login, credential-only protection without the provider, and
current-account failure handling. Both delayed-login regressions failed before
the guard was added. Astra's focused native-guard review found no actionable
correctness or security defects.

## Live Tablet Check

On 2026-10-15, the user approved a plugin-only update in regular Decaid 0.8.8.
The local 0.2.4 candidate loaded successfully. A write-blocked temporary probe
verified the real account machine-list lookup and duplicate suppression for the
existing uploaded shot. All 75 shot metadata records, the complete uploaded
shot, account status, settings, recent upload history, and other plugin states
were preserved. No additional shot-upload POST occurred. Automatic upload stayed
off. The exact reviewed source replaced the probe afterward, and its diagnostic
endpoint was verified absent.

Native-host updates were not installed in regular Decaid because the configured
local signing keys differ from its signer. A subsequent isolated Decaid Test
build verified native notices, real Android browser return, and login recovery
using a fake account/backend. It found and corrected an update-banner priority
bug, with a failing-then-passing regression. See `tablet-verification.md` and
`host-smoke.md` for evidence; private snapshots remain ignored locally.
