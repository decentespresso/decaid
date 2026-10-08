# PR 936 Review

## Summary

- Reviewed all nine changed files at `bc9982f6829aba556cb959e7e9b0b031c7114728`,
  their settings and skin callers, navigation, lifecycle and the pinned Android
  plugin implementation. No additional confirmed changed-code defects found.
- Fixed a P2 persistence race in `SettingsController.setFeatureFlag`: selecting
  TLHC followed by HC during a pending save dropped the HC request because
  memory still contained the previous value. Duplicate pending selections also
  performed redundant writes.
- Serialize feature-flag saves and evaluate unchanged values when each request
  runs. Update memory only after persistence succeeds. Recover the internal
  queue after failures while returning the original error to the caller.
- Added six regression checks, including the visible Android selector, and
  documented ordered pending selections in `doc/Skins.md`.
- Rebased the original PR commits onto upstream main
  `5efc99aaee480cf2c7c064925c3545ed1b0a3b05`. Resolved both conflicts while
  retaining composition diagnostics and upstream camera permissions, request
  invalidation, chooser restrictions and Apple termination handling.
- Added a combined HC/TLHC/HC recreation regression for camera callbacks,
  microphone denial, renderer-exit callbacks and file-access restrictions.
  Moved the unchanged exit-guide function into `skin_exit_instructions.dart`
  and re-exported it from `skin_view.dart`, keeping SkinView at 800 lines.

## Linked Issue

Related #901. Review fixes for upstream PR #936.

## Verification

- Test-first: five checks failed on the original PR, including the visible
  selector expecting HC but showing TLHC. The queued-retry check already passed.
- Initial focused skin and settings checks: 59 passed. The new tests cover
  reversal for every feature flag, duplicate pending selections, retry after a
  failed save and the selector's persisted final choice.
- Before integration, `dart format lib test`: 882 files, no remaining changes.
  `flutter analyze --no-pub`: no issues. Flutter 3.47.5 / Dart 3.13.4.
- Before integration, full suite: 4,430 passed, 2 skipped, 1 failed in 145
  seconds. The sole failure was the unchanged Windows path-separator expectation at
  `test/unit/services/export/archive_export_delivery_test.dart:35`. Expected
  `.../archive.zip`, actual `...\archive.zip`. No verification-only source or
  test overlay was used to hide this failure. Upstream main fixed this test;
  it passes in the final rebased run.
- Earlier full runs had missing QuickJS test-library setup and a stale test
  asset bundle. Corrected process-local library lookup and rebuilt the Flutter
  debug bundle; the final run includes the bundled skin manifest successfully.
  Dependencies and external plugin versions remain unchanged.
- Checked Android-target widget renderings at 360x800 and 1280x800 with bundled
  fonts. Both labels and menu options fit. These are Windows-hosted widget
  renderings, not native Android composition acceptance.
- Final rebased focused checks: 138 passed. `dart format lib test`: 925 files,
  zero changes. `flutter analyze --no-pub`: no issues.
- Final rebased full suite: 4,790 passed, 2 skipped, zero failed; completion
  reported success in 104 seconds, with exit code 0 and empty stderr.
  Inspected all raw error events and non-JSON diagnostics. The two Shelf
  invalid-UTF-8 messages are expected rejection tests asserting HTTP 400.
- Raw final events and screenshots are local ignored artifacts under
  `build/pr936-verification/`; the final run is
  `rebased-final-full-tests.jsonl`. Inspected the complete raw branch diff,
  local fixes and new tests. `git diff --check` is clean, and the index has no
  unresolved entries.

## Impact

- Last requested feature-flag value wins after successful ordered persistence;
  errors do not poison later requests. Existing HC defaults, other platform
  behavior and WebView file-access restrictions remain unchanged.
- No API/spec, database schema or dependency changes. Preserved the original
  dirty checkout by using a separate worktree.
- The local branch is `odev/pr-936-review-fixes`. Original PR commits were
  rebased to `a58f8f56` and `44bba8b1`; the review fixes follow in a separate
  commit. The user authorized publication to the existing PR branch,
  `ODevStudio/decaid:odev/audit-901-webview-composition`. The rebased update
  uses a force-with-lease against the reviewed original PR head,
  `bc9982f6829aba556cb959e7e9b0b031c7114728`, to protect newer remote changes.
- No Android device was connected. Native keyboard, screen-reader, overlay,
  background/resume and Teclast performance acceptance remain unverified here.
  The plugin still does not expose the actual compositor or fallback path.

## Contributor Responsibility

- [x] I have reviewed and understand all changes in this local review and take
  responsibility for their correctness, security, behavior, licensing and
  provenance, including AI-assisted work. <!-- contributor-responsibility -->
