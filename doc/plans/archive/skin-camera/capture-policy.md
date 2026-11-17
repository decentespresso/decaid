# Skin Camera Capture Policy

Address the two Android capture findings from the review of PR #939 at
`7c59e4b8`.

## Design

Require fresh confirmation and OS camera permission for native one-shot image
capture, independent of stored live-camera Ask/Allow/Deny. Keep origin,
active-route, lifecycle, generation and concurrency checks unchanged. Do not
change the stored live-camera decision when confirming capture.

Resolve image extension specifiers through the existing `mime` package. Accept
image-only extension/MIME combinations for capture; reject non-image, unknown
and mixed image/non-image requests. Preserve extension filters on ordinary file
selection rather than broaden a `.jpg`-only picker to all image formats.

## Verification

Regression-first tests reproduced ten failures before implementation. Added
six permission tests and ten widget cases for stored live-camera Deny, consent
changes during capture, OS denial, navigation invalidation, denied/cancelled
confirmation, image extensions, mixed MIME/extensions and file picker filters.

Focused camera, selector, navigation and bundled-asset coverage passed 107
tests. `dart format lib test` completed and `flutter analyze --no-pub` reported
no issues. The controlled full Windows suite passed 4,495 tests with two skips
and zero failures using `--concurrency=4` and the exclusive lab build lock.
Raw structured diagnostics contained zero error events; stderr was empty.
Inspected the expected malformed-URI server logs.

The full run used a temporary correction to the pre-existing Windows path
assertion in `archive_export_delivery_test.dart`. Restored and verified the
original file afterward; this change does not include that correction.

No dependency, API/spec, native Apple, Windows or Linux behavior changes in this
follow-up. Another tester must complete the existing Apple native-build and
real-device acceptance checklist before merge. Android physical capture-file
return and ordinary-picker delivery/cancellation remain manual acceptance gaps.
