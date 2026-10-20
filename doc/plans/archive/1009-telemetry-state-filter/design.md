# #1009: telemetry state and handled-input exclusions

## Verified boundary and decisions

The lane map matches the base: `StatusPublisher.emitError` is the only writer to
its named logger and its only SEVERE call supplies a state message, never an
exception or stack. There is no legitimate unexpected exception-only call in
that logger today. Exclude its exception-free records at the existing
`shouldForwardToTelemetry` boundary; retain eligibility for real exceptions from
that logger and from BLE/transport/parsing loggers.

`DataManagementPage._importLegacyShots` catches and displays import failures,
logging them as `DataManagement` with the original exception and stack.
`ShotImporter` uses `FormatException` for invalid JSON and invalid export shape.
Exclude `FormatException` only from `DataManagement`, not globally: format errors
in transport or persisted data can be genuine defects. Do not match message text
or rename loggers. No Crashlytics reason/context is needed: existing forwarding
and the queue already retain exception and stack identity for real failures.

Keep the main listener unchanged: it scrubs and appends to LogBuffer before
checking telemetry eligibility. Keep queue capacity, send-failure handling,
throttle, consent, Firebase initialization, and anonymization unchanged.
No endpoint, device flow, UI, or schema changes are needed. No blocking decisions.

## Verification design and outcome

The boundary fixture composes the real logger, StatusPublisher, anonymizer,
LogBuffer, filter, and queue using the existing main-listener ordering. It does
not launch the app or initialize Firebase. Before the fix, state reports and
handled invalid JSON reached the send callback; the three exclusion tests failed.
After the fix, all 62 focused telemetry tests pass. Real exception/stack identity,
queue overflow and recovery after send failures were already correct at base;
the new preservation tests pin those properties rather than claim new behavior.
Existing anonymization tests remain unchanged.

`dart format lib test` and the format check report no remaining changes;
`flutter analyze` reports no issues; the full Flutter suite passes 5143 tests
with one skipped. External plugins use the repository's pinned fetch scripts;
ignored bundled-skin fixtures match CI. Only an initial `pubspec.lock` SDK update
needed reverting. The product fix is under ten lines, authored directly and
submitted for independent read-only review.

## Scope and risks

Logger-based rules must track their named producers if future code changes the
meaning of those loggers. Tests must ensure StatusPublisher exceptions and
non-DataManagement FormatExceptions remain eligible. Integration tests exercise
the existing filter/log-buffer/queue composition without Firebase; live
Crashlytics attribution is not verified and is intentionally out of scope.
The lane brief and repo AGENTS.md override generic publication/planning defaults:
no push or PR edits, and archive the design note before committing.
