# Simulated Device Notes

## Modes

Simulated devices are selected with `--dart-define=simulate=<value>` or from
the settings UI:

| Value | Devices |
|-------|---------|
| `1` | `MockDe1`, `MockScale`, `MockBengle`, `MockSensor` |
| `machine` | `MockDe1` |
| `scale` | `MockScale` |
| `bengle` | `MockBengle` |
| `sensor` | `MockSensor` |
| `replay` | `MockReplayDe1` |

Values can be comma-separated. Prefer explicit values in tests and CI because
`simulate=1` exposes both `MockDe1` and `MockBengle`, leaving selection to
`ConnectionManager` policy.

## Replay simulator

`MockReplayDe1` replays recorded shots at 10 Hz. It selects a bundled recording
by normalized profile title, falling back to a generic shot. It implements
`BengleInterface`, so the connection manager exposes its integrated weight
through `BengleVirtualScale`; there is no separate scale device.

Replay is opt-in and is not included by `simulate=1`. Debug routes list, force,
and clear a recording:

- `GET /api/v1/debug/replay/shots`
- `POST /api/v1/debug/replay/shot/{id}`
- `DELETE /api/v1/debug/replay/shot`

`skipStep` seeks to the next recorded frame. Without a positive target, the
shot ends at the recording's original endpoint.

## Profile matching and corpus generation

`SimulatedShotLibrary.forProfileTitle` matches the complete normalized title,
then an unambiguous final path segment. Full-title matches always win.

`test/tools/generate_simulation_assets_test.dart`, run with
`REGEN_SIM_ASSETS=1`, converts `tool/simulation_sources/**/*.shot` into
`assets/simulations/`:

- Resample to 10 Hz.
- Rebuild `profileFrame` from `espresso_state_change`.
- Extend recordings with a steady-state tail for stop-at-weight.
- Add a placeholder profile step so `ShotRecord.fromJson` round-trips.

Rebuild with:

```sh
REGEN_SIM_ASSETS=1 flutter test test/tools/generate_simulation_assets_test.dart
```

## Test behavior

Use `TestScale` instead of `MockScale` in widget tests because `MockScale` owns
a periodic timer that conflicts with `pumpAndSettle()`.

Hardware settle delays belong at the device implementation boundary as
injectable immutable durations. Production keeps hardware-safe defaults;
tests that only need initialization inject zero durations.

Mock machines advance a fixed 100 ms of model time per tick. Shortening the
injectable wall-clock tick interval accelerates tests without changing the
trajectory; scale wall waits by the same factor. Keep real durations for tests
that explicitly validate elapsed-time behavior.

## Simulated shot execution

`MockDe1` and `MockBengle` follow profile targets with simplified response
dynamics. Pressure steps model flow limiters, flow steps model pressure
limiters, and each shot samples bounded puck resistance. This is an
approximation, not firmware control-loop emulation. See
[`mock-shot-fidelity.md`](../plans/archive/mock-shot-simulator/mock-shot-fidelity.md).
