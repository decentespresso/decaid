# Pending auxiliary cancellation test synchronization

PR #956 run 37613331333 attempt 1 failed its pending WebSocket reservation
assertion, then hung until the 30-second test timeout. A rerun passed on the same
commit. The test assumed 30ms was enough for real socket I/O and did not release
its blocked fake connection after an assertion failure.

The timing assumption predates #966's four-worker change, but an old assumption
can become a new CI regression when concurrency increases. These results do not
establish two-worker versus four-worker causation or dismiss the regression.

## Decision

Wait for discovery, socket readiness, connect start, pending cancellation, and
the final connect response. Register fake-connect release before socket teardown
so an assertion failure cannot leave ConnectionManager shutdown waiting for
tracked connection work. Harden the equivalent pending REST case at the same
fixture boundary. Keep production behavior, security limits, and CI workers intact.

## Initial 1000-Execution Stress Check

Only `WS disconnect cancels pending auxiliary connect after scanner removal`
was selected. A thousand ignored wrapper files imported the then-current hardened
test. Each had ordinary per-file isolation and an outer setup barrier releasing
batches of four before original fixture setup. Real loopback WebSockets, original
assertions, and the normal timeout were retained. Event intervals include setup
and teardown.

The completed run had 1000 passes, 0 failures, 0 skips, 0 error events, empty
stderr, and runner exit code 0. Raw events verified four overlapping affected
executions, not just four loading workers. Wall time was 570.841 seconds.
This used Windows 11, Flutter 3.44.8 / Dart 3.12.2, and ordering seed 20261007
on the earlier local checkout, not this PR base or a Linux CI runner.

Preliminary harness evidence was retained separately: same-isolate rapid repeats
hit the unchanged 32-upgrades/client/second admission limit; a fresh-isolate run
passed 1000 times but overlapped loading rather than affected executions. Neither
was counted as the completed concurrent result. No retries occurred in that run.

Affected test SHA-256 before the response-timeout review:
`5f99b7454edf8b44e484fa25e4aad614539e7d0e98becb6f679d6744752446c0`

Raw final event SHA-256:
`4342a969030a907e453eeb0bf23ee035cfaa38bc6e3aeafd238b9968d2ef733a`

Raw events, stderr, wrappers, and a validator remain in the original checkout's
ignored build/test-results/auxiliary-handler-stress-1000/. This is empirical
Windows evidence, not a guarantee that a flake can never occur.

## Initial PR-Base Verification

The isolated PR worktree starts from main commit
`49561b4ec76242a949f8590cf0eae19be7bb941a`. At PR commit `0a841956`, its affected
test had the SHA-256 listed above. The following checks used Windows 11 and Flutter 3.47.5 /
Dart 3.13.4:

- `dart format lib test`: 916 files, 0 changed.
- Focused auxiliary handler suite, four workers, seed 20261007: 11 passed.
- `flutter analyze --no-pub`: no issues found.
- `flutter test --no-pub --machine --concurrency=4`: 4741 passed, 0 failed,
  2 skipped; runner exit code 0, no error events, empty stderr.
- Full-suite machine duration: 173288ms. The existing 20000ms active-time
  gate passed.
- `git diff --check`: clean.

Raw full-suite events and stderr remain in this worktree's ignored
build/test-results/pr-full-events.json and pr-full-stderr.log. These checks
cover the initial PR fix; the 1000-execution result above covers the earlier
checkout. Neither replaces Linux CI verification. The updated timeout placement
has separate verification below.

## Response Timeout Review

On 8 October 2026, move the five-second connect-response timeout to the await
after `releaseConnect()`. Keep the listener attached before sending connect so
it cannot miss a fast response. The response deadline must not include the
interval when the fake connection deliberately prevents a response.

A controlled local copy pauses for six seconds after cancellation but before
release. The initial PR code fails with the five-second response timeout; the
updated code passes the same case. Both retain the original test timeout and
assertions. The pause is not part of the committed test.

Retest the updated code on the isolated PR worktree with Windows 11,
Flutter 3.47.5 / Dart 3.13.4:

- `dart format lib test`: 916 files, 1 formatted.
- Focused auxiliary handler suite, four workers, seed 20261007: 11 passed.
- `flutter analyze --no-pub`: no issues found.
- Full four-worker suite: 4741 passed, 0 failed, 2 skipped; exit 0, no error
  events, empty stderr. Machine duration 161530ms; existing 20000ms active-time
  gate passed.
- Updated affected WS test: 1000 passed, 0 failed, 0 skipped, no retries or
  error events, empty stderr, exit 0. Fresh wrapper suites use a four-suite
  `setUpAll` barrier before original fixtures. Events verify four overlapping
  affected executions, including fixture setup and teardown. Keep the normal
  timeout and security limits. Machine duration 314181ms; wall time 317.170s.

Updated test SHA-256:
`2680cdf61432af14dc7ac25f3b585e52374b999e800a5cb5656c235664b03abe`

Updated stress event SHA-256:
`c9d71fc69783a600afedcdeb442675310ebcfa1ed9451d82f08aa132c2d47626`

Raw events, stderr, stalled copies, wrappers, and validation results remain in
this worktree's ignored build/test-results/response-timeout/. The older stress
record above refers to the previous test version, not this updated source.

## Targeted Cancellation Review

On 8 October 2026, review 5452257460 identifies that `changes.skip(1).first`
accepts an unrelated registry notification as cancellation. Registry events
carry a version rather than a device ID.

The suggested `!isReserved(id)` predicate cannot complete before fake-connect
release. `_cancelPending()` marks the pending operation cancelled but retains
its reservation until `onConnect()` settles and connection cleanup finishes.
The WebSocket disconnect command also has no success response to await.

Use a test-only registry subclass through the existing constructor injection.
It delegates disconnect to the real registry and emits the device ID after a
successful result. Filter for the target ID before releasing the fake connect.
Start the five-second cancellation timeout after sending the target command.
Assert that cancellation keeps the reservation until late-connect cleanup.
The observer closes its stream during disposal. Production code stays unchanged.

The affected test connects and disconnects an unrelated scale before sending
the target command. Its cancellation wait must remain pending. Test-first
verification with the original wait fails this assertion with `Expected: false`
and `Actual: true`; teardown also reports `Bad state: No element` after that
failure. The targeted wait passes the same regression and the existing checks.

Current verification uses Windows 11, Flutter 3.47.5 / Dart 3.13.4:

- `dart format lib test`: 916 files, 1 formatted.
- Focused auxiliary handler suite, four workers, seed 20261007: 11 passed.
- `flutter analyze --no-pub`: no issues found, 81.6 seconds.
- Full four-worker suite: 4741 passed, 0 failed, 2 skipped; exit 0, no error
  events, empty stderr. Machine duration 159896ms; wall time 163.094s.
  The existing 20000ms active-time gate passed.
- Current affected WS test: 1000 passed, 0 failed, 0 skipped, no retries;
  exit 0, no error events, empty stderr. Fresh wrapper suites use a four-suite
  `setUpAll` barrier before original fixtures. Machine events verify four
  overlapping affected executions, including setup and teardown. Machine
  duration 360584ms; wall time 366.790s. Keep normal timeouts and security limits.

Current test SHA-256:
`5fbdd2dd341b77695949d240529590018487ee69cc440a88efb29fad31878636`

Current full-suite event SHA-256:
`d3e401eb12702c5792d73027610d889e916f04b7d29265262dc3f8e57fcbc085`

Current stress event SHA-256:
`23c6cd5f933b8560731466a4c61245c9d85d49bda78ef91a4a29c430ba49269b`

Raw events, stderr, the failing test-first source, wrappers and validator remain
in this worktree's ignored build/test-results/cancellation-state/. The previous
sections describe earlier test versions.

No API/spec, device-flow, plugin, skin, profile, or migration documentation changes
are needed because this change affects only test synchronization and cleanup.
