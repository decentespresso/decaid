# Shot Upload Review Fixes

## Scope

Address the supplied reviews of uploader `8717bb1` and host `0aa828c`, without
unrelated workspace edits or release/bundle changes. The user subsequently
requested publishing these follow-up commits to the same two draft PR branches.

## Decisions

- Scope pause notices and per-shot pause caches to an account generation.
- Bound pending-replacement reads independently of upload attempts and retain
  runtime continuation across passes. Stop scans on authentication pauses.
- Reject malformed nonempty machine-list rows using the requested serial-plus-SKU
  response shape, without inventing a numeric-only serial contract.
- Open Support in the external browser so iOS does not rely on dismissing an
  in-app Safari controller to deliver an app-resume event.
- Bind outbound authentication generation to the final post-consent credential
  snapshot. Abort changed or in-progress snapshots before sending. Keep 401
  credential rereads best-effort so storage errors cannot replace the response.

## Verification

Eight uploader regressions failed before implementation: account switches with
an empty or unavailable new machine list, plain-text response validation, a
large paused-replacement queue, and stopping reads on authentication failure.
The opaque-serial/unknown-SKU compatibility case passed before and after.

Five host regressions failed before implementation: the actual iOS launcher
policy, 401 after either a changed- or same-credential login during consent,
generation changes during the final credential read, and a secure-storage error
after receiving 401. The pre-existing incomplete-login test now requires zero
upstream requests instead of allowing an in-progress credential write to race.

All 68 uploader tests and 258 focused native tests passed afterward. Two
in-process QuickJS smoke checks passed against the updated uploader source and
host, including a repeated cached pause and account-refresh recovery, without
unhandled promise rejection diagnostics. The paused-shot fast path yields before
rejecting, matching the documented native-runtime constraint.

Repository-wide analysis found no issues. The complete Flutter suite recorded
4,970 passed, two skipped, and the same seven Windows BigInt scale-test failures
previously reproduced on unchanged main. Raw failure diagnostics were inspected;
no new failing tests appeared. No baseline scale/runtime behavior was changed.

Formatting changed none of the five affected Dart files after the final format.
A read-only repository-wide format scan reported 15 existing differences, left
untouched. Physical Android/iOS and desktop browser-return checks were not rerun;
the iOS regression verifies the production platform-interface launch option,
not a physical Safari session. Releases and bundle-pin updates remain separate
from these follow-up commits.
