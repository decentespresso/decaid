## Summary

- Use four standard Flutter test workers in PR CI without changing suite selection.
- Virtualize simulation and shot-settings timeout waits with a test-only helper
  that preserves RxDart delivery and awaited cleanup. Keep production code and
  timing constants unchanged.
- Report aggregate loading and test time separately, with regression checks for
  the parser and virtual-time helper.

## Linked Issue

N/A: automated repository-maintenance work.

## Verification

- Reverified from `main` at `94501c45` on Windows with Flutter 3.47.5 / Dart 3.13.4.
- Full `flutter test --no-pub --machine --concurrency=4`: 4579 passed, 0 failed,
  2 skipped; 163.408s test execution, 166.571s command wall time.
- All 23 focused tests pass normally and shuffled with seed 20261006 at four
  workers, including the newer reconnect test from main and both helper tests.
- `python tool/ci/summarize_flutter_tests_test.py`: 12 tests pass.
- The existing `--max-active-ms 20000` gate passes against four-worker events.
- `flutter analyze --no-pub`: no issues. Changed Dart files are formatted;
  `dart format --output=none lib test`: 900 files, 0 changes.
- Earlier warm-cache benchmark on the original checkout, Flutter 3.44.8:
  two workers 329.238s, four workers 206.750s, a 37.2% reduction. The four changed
  suites' aggregate active time fell from 41.962s to 0.482s. Both optimized runs
  had identical counts and the same pre-existing Windows assertion failure.
  See `design.md` for the original baseline and its limitations. Do not compare
  the newer-main run directly with those older-base timings.
- These are local Windows measurements, not Linux CI results. Raw current-main
  events and stderr remain in ignored `build/test-results/pr-main-j4.*`.
  No app deployment or hardware operation.

## Impact

No production behavior, security, dependency, schema, API/spec, skin, plugin,
profile, or device-flow change. Update testing notes and archive the design rationale.
Preserve unrelated local changes. Leave experimental testing and sharding disabled.

## Contributor Responsibility

AI-assisted development is allowed. The submitter remains responsible for the submitted work.

- [ ] I have reviewed and understand all changes in this PR and take responsibility for their correctness, security, behavior, licensing, and provenance, including any AI-assisted or AI-generated work. <!-- contributor-responsibility -->

Left unchecked for the submitting maintainer's personal review before marking
the draft ready for review.
