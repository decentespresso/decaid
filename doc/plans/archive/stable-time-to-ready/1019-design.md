# #1019 Stable time-to-ready estimates

## Refinement and decisions

The producer currently publishes a two-point derivative and suppresses all upward corrections. Replace that with a recent-window regression and confidence gating; preserve the timeToReady event shape and existing skin consumer. Product changes stay in assets/plugins/time-to-ready.reaplugin/. No skins, streamline-js, host API, hardware writes, or new settings.

Require at least eight samples spanning five seconds. Retain thirty seconds of history by elapsed time rather than a fixed twenty samples so dense Bengle-like cadences can qualify. Fit a least-squares slope and reject trends not clearly positive or whose propagated slope/residual uncertainty exceeds three seconds of countdown uncertainty. Confidence is assessed against the unclamped estimate; the existing five-minute display cap remains unchanged. Drop the monotonic guard rather than masking rising estimates. Reset the trend on sleeping/new heating sessions or stale/discontinuous observations to avoid borrowing confidence from another session.

The supervisor approved synthetic replays in place of unavailable recorded traces, and defines the acceptance band as at most three seconds of upward correction after first publication. No recorded heating trace exists in the repo; AC4 is satisfied by synthetic replays and real-device validation is outstanding. Targets are DE1 and Bengle, neither physically exercised. Every fixture labels ramp/cadence numbers as synthetic stress assumptions, not verified machine behaviour. Parametric coverage spans DE1-like 0.1–0.3 °C/s and Bengle-like 0.3–0.8 °C/s with 0.5–2 s cadence, including sensor jitter and noisy cold starts. These ranges come from the supervisor's stress-test decision, not telemetry or published rates.

## Verification plan

1. Add Node VM replay regressions matching the existing settings_feedback_test.cjs pattern; demonstrate failure with the existing producer.
2. Implement the minimal regression/confidence gate and verify positive stable ramps, irregular/dense cadence, noisy/flat/cooling trends, unbiased upward corrections, reached state, and session resets.
3. Independently run focused Node tests, dart format lib test (revert unrelated churn), flutter analyze, and full flutter test. Establish any environment/baseline failures by stashing changes and repeating at HEAD. Mid-run orchestration narrowed the final gate to Node syntax/tests, analyze, non-mutating format check and diff check because other lanes were running full suites. A full suite had already completed with two unrelated shot-upload failures, reproduced with the focused file at stashed HEAD; do not repeat the full suite.
4. Update doc/Plugins.md for indeterminate semantics; fill the PR template locally without publishing. Archive this design rationale before commit. Independent read-only review checks criteria and test false positives.
