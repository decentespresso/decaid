# #1009: telemetry state and handled-input exclusions

## Verified boundary and decisions

`StatusPublisher.emitError` is the only writer to its named logger and its only
SEVERE call supplies a state message, never an exception or stack. Exclude its
exception-free records at the existing `shouldForwardToTelemetry` boundary;
retain eligibility for real exceptions from that logger and BLE/transport/parsing
loggers. The review revision leaves this rule unchanged.

`DataManagement` is shared by legacy-shot import, full-backup import/export, log
and shot export, and De1App scan/import. Logger identity plus plain
`FormatException` is therefore not sufficient evidence of handled input. Only
`DataManagement` records carrying the existing `UserFacingFormatException` are
excluded. Plain `FormatException`s and other unexpected errors remain eligible,
with the existing original-error/stack forwarding. No message matching, logger
renaming, new exception type or Crashlytics reason/context is needed.

`ShotImporter.importJson` owns the decode-and-dispatch decision formerly in the
page. It decodes once, then imports an object or array. Malformed JSON, invalid
top-level shapes, non-object members, missing/invalid required export fields and
`FormatException`s from constructing a `ShotRecord` become user-facing errors.
The existing strict single/bulk entry points share these helpers.

Conversion catches surround only JSON decoding and synchronous shot construction,
never the storage loop. Each validated shot is constructed before `storeShot`;
storage/database/application exceptions propagate unchanged. Incremental writes
and `finally { if (count > 0) controller.notifyShotsChanged(); }` remain intact,
including when a later item fails validation or storage. Non-format internal
errors are not broadly reclassified as user input.

### De1App decision and follow-up

Leave `DataManagementPage`'s De1App catch unchanged: it surrounds the whole import,
not a proven parsing-only boundary. `De1appImporter` already catches per-file
JSON/parser failures, logs warnings and collects import errors; storage and other
orchestration operations can also fail. Converting all escaping format failures
would recreate this bug. Follow up by auditing any escaping user-file format
failures and classifying them at their individual parser boundaries with tests.
Until then, an escaping plain De1App format failure remains eligible for telemetry,
so there is a residual noise risk. The PR draft records this explicitly.

## Verification design and outcome

The boundary fixture composes the real logger, ShotImporter, StatusPublisher,
anonymizer, LogBuffer, filter and queue using main's existing listener ordering.
It does not launch the app or initialize Firebase. The handled-input test now
uses the importer's file entry point rather than a bare `jsonDecode` fixture.

Before revision product edits, `flutter test test/services/telemetry
test/shot_importer_test.dart --reporter expanded` failed with `+71 -13: Some tests
failed.` The real importer returned plain `FormatException` rather than
`UserFacingFormatException`; an unexpected DataManagement format failure was
lost (`Expected: an object with length of <1>`, `Actual: []`). The direct filter
regression also failed (`Expected: true`, `Actual: <false>`). Importer shape,
malformed JSON and invalid-date construction tests failed the typed expectation.
Unrelated logger format errors, DataManagement StateError and storage format
failure identity were already GREEN; they pin preserved behavior, not new fixes.

After revision, the telemetry suite passes 65 tests and the importer suite passes
30 tests, including object/array dispatch, primitive and non-object inputs,
invalid required fields, partial imports and storage-error identity. Format check
reports 950 files with zero changes, analyze reports no issues, and the full
Flutter suite reports `02:33 +5160 ~1: All tests passed!` (one skipped).

## Scope and risks

Keep the main listener unchanged: it scrubs and appends to LogBuffer before
checking telemetry eligibility. Queue implementation/capacity/send-failure
handling, throttle, consent, Firebase initialization and anonymization are
unchanged. No endpoint, device-flow, UI presentation or schema contract changes
are needed. Api/Skins/Plugins/Profiles/DeviceManagement docs do not need updates.
Live Crashlytics attribution and device behavior are not verified, by lane policy.

The lane brief and repo AGENTS.md override generic publication/planning defaults:
no push or PR edits, and archive rationale before committing. This revision was
authored by the lead per its explicit nested-run Phase 1 instruction, with a
separate read-only reviewer rather than claiming independent author validation.
