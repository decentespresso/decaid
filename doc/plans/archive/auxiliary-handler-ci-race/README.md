# Pending auxiliary cancellation tests

PR #956 CI run 37613331333, attempt 1, failed the pending WebSocket reservation
assertion and reached the 30-second timeout. A rerun passed on the same commit.
The test used a 30ms sleep and left its fake connect blocked after assertion
failure. The timing assumption predates #966; the full-suite CI trigger remains
unresolved.

## Synchronization

Wait for discovery, socket readiness and connect start. Register fake-connect
release during teardown. Attach response listeners before sending commands and
start response timeouts when the responses can occur.

Send the target disconnect and a connect for a guaranteed-missing sentinel ID
on the second WebSocket. Its per-socket command queue processes them in order,
so the sentinel's error response confirms completion of the preceding disconnect.
The target stays reserved until `releaseConnect()` and late-connect cleanup;
assert the final connect returns `conflict` and clears the reservation.

Use the existing socket queue rather than a registry-change count or a test-only
registry subclass. Production behavior, security limits and CI workers stay
unchanged. No API/spec or domain documentation updates are needed.

## Verification

Based on PR head `efda1e3c`, Windows 11, Flutter 3.47.5 / Dart 3.13.4:

- `dart format lib test`: 918 files, 0 changed.
- Auxiliary handler suite, four workers, seed 20261007: 11 passed.
- `flutter analyze --no-pub`: no issues found.
- Full four-worker suite: 4772 passed, 0 failed, 2 skipped; exit 0, no error
  events, empty stderr. The existing 20000ms active-time gate passed.
- Affected WS test: 1000 passed, 0 failed, 0 skipped, no retries; exit 0,
  no error events, empty stderr. Each wrapper uses fresh per-file fixtures,
  with a four-suite barrier before fixture setup. Events verify four overlapping
  affected executions, including setup and teardown; normal timeouts stay unchanged.
- Negative control omitting the target disconnect: expected `conflict`, got
  `connected`. The committed test passes.

Test SHA-256:
`1421e6799d1befe6193eabed3f758598c4670a8791fdfd3e74065fb36137101b`

Stress event SHA-256:
`f842023a85abcd554205c9044e035b9736526da56409910c2c8df19ad9f1081e`

Raw events, stderr, negative control, wrappers and validator remain in ignored
build/test-results/socket-barrier/. These local runs do not rule out flakes on
other workloads or replace Linux CI. Earlier records remain in Git history at
`e24fab9b` and `043b9f9c`; their raw local artifacts stay unchanged.
