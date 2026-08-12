# Simulator: replay a historical shot, matched to the selected profile

Source: John Todo 10181321154 ("decaid espresso machine shot simulator should do
the same as de1app: use a historical espresso shot and replay it") plus Vid's
review note (make replay its own device) and the follow-up: pick a recording
made with the currently selected profile when possible.

## Why

The synthetic puck-physics simulator (`MockDe1`) never looks like a real pull
and is identical every run. de1app instead replays a real recorded shot. We want
the same in decaid, and — since the app always has a selected profile — to
replay a shot actually made with that profile when we have one.

## Design (as shipped)

Replay is a single standalone simulated device (a `BengleInterface` machine with
an integrated scale), so `MockDe1`/`MockScale` stay the single-responsibility
puck simulator (Vid's point):

- **`ShotReplayer`** (`impl/replay/shot_replayer.dart`) — pure playback engine:
  maps wall-clock elapsed → the recorded `MachineSnapshot`/weight; idle past the
  end. No Flutter, trivially testable.
- **`MockReplayDe1`** (`impl/replay/mock_replay_de1.dart`) — a single standalone
  device (per review), `implements BengleInterface` so it is both machine and
  integrated scale. It does NOT extend `MockDe1`: it *composes* one, delegates
  the De1Interface surface to it, and falls back to it for steam / hot water /
  flush. On espresso start it asks
  `SimulatedShotLibrary.pickForProfile(currentProfile)` for a recording and
  streams it at 10 Hz; end-of-data → idle. Its integrated scale
  (`weightSnapshot`) reports the recording's real weight and the connection
  manager auto-wraps it as a `BengleVirtualScale`.
- **Target weight** uses the autonomous SAW path: the `ShotSequencer` bypasses
  its own SAW for `BengleInterface`, the `BengleSawBridge` pushes the workflow's
  target yield via `setStopAtWeightTarget`, and the device stops itself when the
  recorded weight reaches it — exactly like `MockBengle`.
- **`SimulatedShotLibrary`** — loads `assets/simulations/manifest.json`
  (`fallback` pool + `profiles[]` mapping profile title → shot). `forProfileTitle`
  does a normalized-title lookup; `pickForProfile` returns the match or a random
  fallback.
- **Wiring** — new `SimulatedDevicesTypes.replay`; `SimulatedDeviceService`
  creates the single device; `simulate=replay` / settings toggle.

## The corpus

- Fallback pool: de1app's three sample shots.
- Profile-matched: real public shots from **visualizer.coffee**, one per bundled
  profile for which a public shot existed (14 of 71 at build time — the popular
  Decent defaults; the long tail has no public shots, so replay falls back).
  Each was downloaded, reconstructed into a `.shot`
  (`tool/simulation_sources/profiles/<bundled-stem>.shot`, `timeframe` →
  `espresso_elapsed`, missing vectors zero-filled), then run through the existing
  `TclShotParser` → 10 Hz resample → decaid-JSON pipeline. `manifest.json` keys
  each by the bundled profile's canonical title.

## Decisions / caveats

- Match key is the bundled profile title (normalized: lowercased, punctuation →
  spaces, plus the last `/`-segment so `author/Name` and `category/Name` match).
- `MockReplayDe1` composes a `MockDe1` and delegates the De1Interface surface to
  it (DRY without modifying `MockDe1`), rather than extending it or extracting a
  shared mixin.
- The injected single "Replay" profile step (so the JSON round-trips) is a
  placeholder; the real advanced_shot frames are not reconstructed. Fine for a
  simulator — replay drives telemetry from samples, not the profile.
- Coverage is "whenever possible": unmatched profiles replay a generic fallback.

## Honoring the profile's target weight (from PR #590)

PR #590 (merged) argued replay "discards the selected profile and target-weight
dynamics." Replay answers both:

- **Selected profile** — it plays a recording made with the current profile.
- **Target weight** — because `MockReplayDe1` is a `BengleInterface`, the
  workflow target yield flows through the `BengleSawBridge` to the device's
  autonomous stop-at-weight, and the `ShotSequencer` bypasses its own SAW for
  `BengleInterface` (no double stop). Because recordings begin at the pour, the
  device first emits a brief `preparingForShot` phase (weight 0) so the
  sequencer starts the shot lifecycle; once the espresso stages begin it exposes
  the recording's weight unchanged, and tare requests are swallowed. Covered by
  `test/integration/replay_saw_bridge_test.dart`.
- **Enough data for any target** — each recording is extrapolated to ~2.5 min in
  the generator (`_extendTo`): the recorded head stays 10 Hz, then a 1 Hz tail
  holds the end-state pressure/flow/temperature and keeps weight rising at the
  final pour rate. So a target yield past the recorded shot's final weight still
  has data to stop on. Assets are written compact to keep the bundle small.

Per-shot variation (#590's bounded puck-resistance jitter) is inherently a
synthetic concern and does not apply to replaying real recordings.

## Opt-in and recording selection

- **Opt-in only.** `simulate=1` expands to the default profile-driven simulator
  set (`_defaultSimulatedDevices`); replay is never implicitly enabled — it
  requires explicit `simulate=replay`.
- **Deterministic selection.** Normally the recording is chosen by profile match
  (else random fallback). The `debug/` API can list the bundled recordings by a
  stable id, force one for subsequent pulls, and clear the override (session-
  only): `GET /api/v1/debug/replay/shots`, `POST /api/v1/debug/replay/shot/{id}`,
  `DELETE /api/v1/debug/replay/shot`. The normal machine-state API still
  starts/stops the shot.
