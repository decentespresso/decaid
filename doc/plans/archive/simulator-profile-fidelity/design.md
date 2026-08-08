# Simulator profile fidelity

## Problem

Historical-shot replay ignores the selected profile and makes target-weight behavior incidental to the recording. The existing simulator follows the selected profile and uses the normal scale and ShotSequencer path, but every pull has the same puck response and step limiters are ignored.

## Plan

1. Add regression coverage for profile-step limiters, repeat-shot variation, and stop-at-weight through MockDe1, MockScale, and ShotSequencer.
2. Apply pressure-step flow limiters and flow-step pressure limiters in MockDe1.
3. Sample one bounded puck-resistance multiplier at each shot start from a fixed-seed random sequence so pulls vary while test runs remain deterministic.
4. Run formatting, focused tests, analysis, the full test suite, and a simulate-mode smoke test.

## Boundaries

- Keep profiles, scale behavior, target weight, and shot persistence on their existing production paths.
- Do not add replay assets, asset loaders, simulator settings, or duplicate stop-at-weight logic.
- Keep the synthetic fallback for profile-less unit tests unchanged.
