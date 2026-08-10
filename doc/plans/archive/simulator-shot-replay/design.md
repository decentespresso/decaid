# Simulator: replay a historical shot instead of synthetic data

> **Update (post-review):** the original PR (#586) made replay the *default*
> simulator and was closed — the maintainer wants the default simulator to stay
> synthetic/profile-driven so `simulate=1` keeps exercising profile steps,
> limiters, and the shot-control path. The replay engine below is retained but
> is now an opt-in extension: off by default, toggled by the
> `replay-simulator.reaplugin` plugin (Extensions list). The plugin emits
> `setEnabled` on load/unload; `main.dart` flips
> `SimulatedDeviceService.setReplayHistoricalShots`, which `MockDe1` reads live
> at each shot start. See `doc/AI_BUILD_NOTES.md` and `doc/Plugins.md` for the
> current wiring. The rest of this document describes the replay engine itself,
> which is unchanged.

Source: Basecamp todo 10181321154 (John Todo / Impact: medium):
> decaid espresso machine shot simulator should do same as de1app does: use a
> historical espresso shot and replay it, instead of creating synthetic fake data.

## Why

Today `MockDe1` synthesizes telemetry with a parametric puck-physics model
(`_simulateWithProfile`). It is plausible but not real: curves never match a
genuine pull, and the shape is the same every time for a given profile. de1app's
simulate mode instead replays a real recorded shot, so charts, DYE, plugins and
the shot-upload pipeline all see authentic data. We want the same in decaid.

## Reference behaviour (de1app)

On a desktop with no machine paired, de1app:

- gates simulation on `espresso_simulation_active` (no BLE address, not iOS/Android);
- on shot start loads a **random** real `.shot` from the bundled `simulations/`
  directory (`open_random_simulation_file`), keyed by the `espresso_elapsed`
  vector, and adopts that shot's profile;
- each ~5 Hz tick maps wall-clock elapsed time onto `espresso_elapsed` to find the
  nearest recorded sample, copies its pressure/flow/temp/weight/goals into the live
  `::de1(...)` sensor globals, and fires the same `on_shotvalue_available` callback
  the real BLE path uses;
- forces the machine Idle when the recorded samples run out.

Two flags matter: `use_simulated_data` (replay a real shot vs. random jitter) and
`do_realtime_espresso_simulation` (advance by wall clock, because the recorded
samples are irregularly spaced ~4 Hz against a 5 Hz clock).

## What already exists in decaid (so this is small)

- `TclShotParser` (`lib/src/import/parsers/tcl_shot_parser.dart`) parses a de1app
  `.shot` into a `ShotRecord` -> `List<ShotSnapshot>` -> per-index `MachineSnapshot`,
  timestamped from `espresso_elapsed`. This is exactly the frame `MockDe1` emits.
- `MockDe1` already streams `MachineSnapshot` on a 100 ms timer.
- `MockScale.attachMachine` integrates the machine's `flow` through
  `SimulatedShotWeightModel`. During replay the flow is the *recorded* flow, so the
  simulated scale weight tracks the recorded shot with no scale change required.

## Design

### 1. Bundled source shots, converted to decaid JSON

The replay corpus is de1app's three `simulations/simulated_{1,2,3}.shot`, converted
into decaid's native historical-shot JSON (`ShotRecord.toJson`) and shipped as
assets under `assets/simulations/` with a `manifest.json`. Conversion runs through
decaid's own `TclShotParser`, guaranteeing the JSON round-trips via
`ShotRecord.fromJson`. Source `.shot` files are committed under
`tool/simulation_sources/` so the conversion is reproducible in CI.

### 2. `ShotReplayer` (pure, unit-tested)

Constructed from a `ShotRecord`. Precomputes each measurement's elapsed seconds
(`measurement.machine.timestamp - first.timestamp`). Given wall-clock elapsed
seconds `t`:

- `frameAt(t)` -> the `MachineSnapshot` at the first index whose elapsed > `t`
  (clamped to the last), with state forced to `espresso/pouring` (or `idle` past
  the end), mirroring de1app's index walk;
- `isFinished(t)` -> `t >= lastElapsed`.

No Flutter, no timers: trivially testable.

### 3. `SimulatedShotLibrary` (asset loader, DI)

Loads `assets/simulations/manifest.json` + the referenced JSON via `rootBundle`
into `List<ShotRecord>` once (`ensureLoaded`). `pickRandom(Random)` returns a shot
or null when empty. Injected into `MockDe1` by constructor (no service locator).

### 4. `MockDe1` wiring

- Constructor gains `SimulatedShotLibrary? replayLibrary` and
  `bool replayHistoricalShots = true` (the `use_simulated_data` analogue).
- On `requestState(espresso)`: if replay is enabled and the library has a shot,
  pick one, build a `ShotReplayer`, set `_replaying = true`.
- In `_simulateEspresso`: when `_replaying`, emit `replayer.frameAt(shotTime/1000)`;
  when `replayer.isFinished`, drop to idle (mirrors de1app forcing Idle).
- When replay is disabled or no shot is available, fall through to the existing
  synthetic model unchanged (safety net for empty/failed asset loads and for the
  unit tests that assert synthetic curves).

### 5. Service + assets

- `SimulatedDeviceService` constructs the library, `await ensureLoaded()`, and
  passes it to `MockDe1`.
- `pubspec.yaml` registers `assets/simulations/`.

## Decisions

- **Random pick among the three** at each shot start, matching de1app.
- **Synthetic model kept as fallback** behind `replayHistoricalShots` (default on).
- **Weight** rides the existing flow-integration scale (recorded flow drives it);
  feeding recorded `espresso_weight` directly is a possible later refinement.

## Test plan (test-first)

1. `ShotReplayer`: index mapping at t=0, mid, past-end; `isFinished`.
2. `SimulatedShotLibrary`: bundled assets load, `pickRandom` non-null, measurements
   present; round-trips `fromJson`.
3. `MockDe1` replay: with an injected library, `requestState(espresso)` then pump
   the timer -> emitted pressure/flow follow the recorded curve; end -> idle.
4. Update `mock_de1_realism_test` / `mock_de1_flow_pressure_test` to target the
   synthetic **fallback** (replay disabled).
5. `dart format`, `flutter analyze`, full `flutter test`, `--dart-define=simulate=1`
   smoke run.

## Docs to touch

`doc/AI_BUILD_NOTES.md` (simulate replay behaviour), `doc/AI_TESTING_NOTES.md`
(fallback path for synthetic-curve tests).
