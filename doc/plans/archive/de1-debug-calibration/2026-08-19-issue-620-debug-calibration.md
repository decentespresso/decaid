# Native DE1 calibration debug controls

**Issue:** [decentespresso/decaid#620](https://github.com/decentespresso/decaid/issues/620)
**Branch:** `odev/issue-620-debug-calibration`
**Scope:** Native debug UI only. The typed calibration API from #613 remains the sole device boundary.

## Findings

- `De1Interface` already exposes typed current/factory reads and writes for flow, pressure, and temperature.
- Writes are corrections described by the reported and measured pair. Initialize both write fields from the current calibration value so an unchanged write is a no-op and editing the measured field performs the documented absolute-set recipe.
- `De1DebugView` already uses cards, Shad inputs/buttons, snackbars for status, and dialogs for failures.
- Issue #620 has no acceptance label, so any prepared PR remains gated on maintainer acceptance.

## Plan

1. Add widget tests that pin all-target current/factory reads, write arguments, authoritative post-write refresh, invalid input handling, and device failures.
2. Add one calibration card to the native debug view, backed directly by `De1Interface`.
3. Keep one row per typed target with current/factory display and numeric reported/measured inputs.
4. Use the existing snackbar/dialog conventions for validation, success, and device errors.
5. Format changed Dart files, run focused tests, analyze, run the full suite, then archive this design note and prepare the local draft PR.

## Non-goals

- Physical calibration guidance.
- Raw A012 or BLE handling.
- REST or WebSocket changes.
- New controller, service, or persistence layer.
