# Test speed without reduced coverage

## Decisions

Run the full PR suite with four standard Flutter test workers. Keep analysis,
native-library setup, failure propagation, captured machine events, and the
existing active-time gate. Do not change test selection or add retries.

Remove real-time waits from the Bengle integrated-scale and milk-probe suites,
flow-driven MockScale tests, and shot-settings timeout tests. Preserve production
durations, tick cadence, curve assertions, timeout errors, and write serialization.
Add checks for emitted sample count, no premature steam stop, and timer cleanup.
Production code remains unchanged.

Direct `fake_async` conversion stalls RxDart seed delivery and awaited stream
cancellation. `FakeTime` keeps microtasks live while controlling timers and the
existing injectable clock. Advancing in 10ms steps gives stream feedback a chance
to stop the simulator between ticks. Its regression tests cover seed delivery,
cancellation, feedback, clock progression, partial intervals, and async startup.
This helper serves coarse simulation and timeout tests, not native I/O timing.

Extend the existing timing summary with loading totals and loading-file rankings.
Keep loading separate from the slow-suite gate and visible test counts. Report
missing timings as unavailable. Do not introduce a wall-clock gate before measuring
runner variance; a flaky performance check would undermine reliability.

## Alternatives

Leave experimental engine testing disabled until repeated Linux runs establish
native-plugin compatibility. Add sharding only if four workers leave PR latency
above the agreed target; it adds workflow complexity and runner usage.

Do not shorten only test waits or simulation tick intervals. The weight model
integrates timestamp deltas, so that would change the tested trajectory.

## Local Evidence

Windows, Ryzen 7 5800X3D, Flutter 3.44.8 / Dart 3.12.2, 2026-10-06:

| Run | Test execution | Passed | Failed | Skipped |
| --- | ---: | ---: | ---: | ---: |
| Original suite, two workers, cold compilation | 421.099 s | 4447 | 1 | 2 |
| Optimized suite, four workers, warm compilation | 206.750 s | 4449 | 1 | 2 |
| Optimized suite, two workers, warm compilation | 329.238 s | 4449 | 1 | 2 |

Four workers reduced warm local test execution time by 37.2% compared with two
workers. Do not attribute the entire cold-to-warm difference to these changes.

The four changed suites consumed 41.962 s of active test time before optimization
and 0.482 s afterwards. The two added passing tests exercise `FakeTime`.

The full-suite failure predates these changes: the expected path in
`test/unit/services/export/archive_export_delivery_test.dart:35` mixes Windows and
POSIX separators. Full analysis also reports six warnings in pre-existing,
untracked `doc/reliability-audit/checks/` files. Preserve those unrelated files.

The 22 focused tests pass in normal order and with randomized ordering seed
20261006 at four workers. All 12 Python timing-parser tests pass, and the existing
20000ms slow-suite gate passes against the four-worker events. Analysis of `test/`
reports no issues. The read-only `dart format --output=none lib test` scan identifies
11 pre-existing formatting differences; the changed Dart files are formatted.

Raw machine events and stderr remain under ignored `build/test-results/`.
These benchmark runs do not establish GitHub Linux runner performance or
compatibility with a different Flutter SDK. No app deployment or hardware
operation was performed.

## Draft PR Verification

The scoped changes were transferred to a clean worktree based on `main` at
`94501c45`, preserving its newer scale reconnect test and excluding unrelated
original-checkout edits. Verification used Flutter 3.47.5 / Dart 3.13.4 on Windows:

- Full four-worker suite: 4579 passed, 0 failed, 2 skipped; 163.408s test execution
  and 166.571s command wall time. The older checkout's assertion failure did not
  recur. Its unrelated audit files are not present in this clean worktree.
- All 23 focused tests pass normally and shuffled with seed 20261006.
- All 12 timing-parser tests pass; the 20000ms active-time gate passes.
- Full analysis reports no issues. All 900 Dart files pass the read-only formatting
  scan without changes; no dependency or lockfile change was needed.

The four changed suites total 1.693s of active time here, including the newer
real-time reconnect test. Different source revisions and SDKs make this run
verification evidence, not a direct comparison with the original benchmark.
Raw events and stderr are in ignored `build/test-results/pr-main-j4.*`.
