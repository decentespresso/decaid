## Summary

- Added the opt-in `examples/plugins/felicita-arc.reaplugin/` driver beside Bookoo using the existing host-owned BLE Scale binding.
- Parent reviewed the implementation and requested corrections to callback error propagation, readiness rejection ownership and native-compatible sign parsing. Worker used `openai-codex/gpt-5.6-luna` at medium effort.
- Software is ready for controlled hardware testing, not final merge acceptance.

## Linked Issue

Refs #809 and PR #823. Felicita testing does not satisfy the issue's explicit Bookoo hardware gate.

## Verification

- Worker focused Felicita tests: 8 passed (`/tmp/felicita-focused.log`).
- Parent independently ran Felicita plus shared Scale timing tests: 12 passed (`/tmp/felicita-parent-review-tests.log`).
- Parent additionally executed a temporary Node VM check against the actual plugin source: host sample token forwarding, stale/fatal publication error propagation, fresh publication after rejection, same-factory reconnect with battery reset, disconnect before readiness, and timer cleanup all passed. This is supplemental execution evidence, not a committed regression suite.
- Worker `flutter analyze`: no issues (`/tmp/felicita-analyze.log`).
- Worker ran `dart format lib test`; unrelated existing Bookoo formatting changes were excluded from the final diff. `git diff --check` passed.
- Worker full `flutter test`: 4045 passed, one skipped, one failed (`/tmp/felicita-full.log`). The Bookoo generation-reload assertion also failed in the worker's pre-change baseline (`/tmp/felicita-baseline.log`). This was the state at the original review checkpoint; later reconnect work fixed the notification loss and made the full suite clean.
- Tests use synthetic packets derived from the native implementation, not captured hardware fixtures. There is no automated native-versus-JS Felicita parity run or full discovery/API/restart scenario specific to Felicita. Command write failure is not evidence of fatal publication handling; the latter was checked separately by the parent's JS probe for callback propagation, with teardown remaining host-owned.
- No hardware deployment, tablet operation, commit, push or PR mutation was performed during this original review checkpoint.

## Follow-up verification — 2026-09-10

- Felicita hardware testing on Android confirmed actionable GATT-133 error handling and successful Retry without rescanning.
- Continuous weight notifications and tare plus timer start, stop and reset all worked after reconnect.
- Scale Debug now activates `ScaleSnapshotHandoff` after successful connection; a widget regression test covers failed connect, Retry and post-success activation.
- Explicit disconnect completed confirmed native teardown and turned off the physical connection indicator without delaying navigation.
- Focused tests: 45 passed. `flutter analyze`: no issues. Serialized full suite: 4051 passed, one skipped. `git diff --check`: clean.
- No commit, push or PR mutation was performed. This Felicita run still does not satisfy the linked issue's separate Bookoo hardware gate.

## Impact

- Native Felicita, native Bookoo and the Bookoo example remain unchanged; this example is not bundled or automatically enabled.
- An enabled matching plugin intentionally takes ownership on subsequent discovery; existing active connections are not hot-swapped. Native and plugin public IDs differ.
- No endpoint, API schema, storage or migration changes. Plugin documentation links the additional reference example.
- Retains native sign behavior: only byte 45 is negative. Battery outside raw 129..158 is unknown initially or retains the last valid reading.
- The two-second watchdog remains provisional. Hardware acceptance must establish notification cadence and verify weight, tare, all timer commands, sleep/disconnect, reconnect and restart preference behavior on the Android tablet. Model/firmware and platform must be recorded separately from automated evidence.

## Contributor Responsibility

- [x] I have reviewed and understand all changes in this local change set and take responsibility for this review, including correctness, security, behavior, licensing and provenance of the AI-assisted work. This is local review evidence, not a submission or assertion that outstanding full-suite/hardware gates passed.
