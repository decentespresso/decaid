# Simulator profile fidelity

## Problem

Historical-shot replay ignores the selected profile and makes target-weight behavior incidental to the recording. The existing simulator follows the selected profile and uses the normal scale and ShotSequencer path, but every pull has the same puck response and step limiters are ignored.

## Design

- **Profile-aware synthetic simulation over replay.** Replay assets would decouple the simulator from the currently loaded profile, so target-weight and limiter behavior would stop reflecting what the skin author is editing. Keeping the synthetic loop on the existing profile, scale, and ShotSequencer paths means simulated shots exercise the same stop-at-weight and step-exit logic as hardware, with no new asset pipeline.
- **Limiters are an approximation.** Pressure steps model flow limiters and flow steps model pressure limiters with a progressive response across each limiter's range of action. This approximates the observable machine response to limiter settings without emulating firmware control loops; exact tuning is not a goal.
- **Bounded puck-resistance variation.** Each shot samples one puck-resistance multiplier from a fixed-seed random sequence, so repeated pulls differ without making test runs nondeterministic. Variation is bounded to keep pressures plausible within the selected profile.
- **Scope.** Keep profiles, scale behavior, target weight, and shot persistence on their existing production paths. No replay assets, asset loaders, simulator settings, or duplicate stop-at-weight logic. The synthetic fallback for profile-less unit tests stays unchanged.

## Boundaries

- Keep profiles, scale behavior, target weight, and shot persistence on their existing production paths.
- Do not add replay assets, asset loaders, simulator settings, or duplicate stop-at-weight logic.
- Keep the synthetic fallback for profile-less unit tests unchanged.
