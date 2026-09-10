# Bengle puck estimator as a Sensor, not MachineSnapshot fields

## Why

The Bengle `0xA014` frame carries the firmware's fused puck-hydraulic observer:
resistance (R1/R2), compliance, confidence, Qout lag, absolute volume, and an
optional Rev-2 R1-collapse detector tail. The port originally folded a subset of
these into `MachineSnapshot` as `fusedR1`, `fusedR2`, `fusedC`, `fusedConf`,
`vAbs`, `estLag`, `estFlags` plus four detector fields.

Upstream rejected that shape. Reviewing the port's own PR #601, commit
`633f6f68` ("route A013 into existing machine/scale/sensor abstractions")
revised it in place:

> MachineSnapshot stays pure machine telemetry (weight/weightFlow/milkTemperature
> removed; steamTemperature retained).

`0xA013` weight was rerouted to `ScaleSnapshot` via `IntegratedScaleCapability`,
and milk temperature to `BengleMilkProbe` — a `Sensor`. `rest_v1.yml` states the
rule directly: "milk-probe scaffolding lives in `/sensors`, not here."

Adding eleven more observer fields to `MachineSnapshot` would re-litigate a
decision the maintainer has already made once against this port, and would keep
the port permanently unmergeable on this surface.

## Decision

Expose the fused estimator as a `Sensor`, following the `BengleMilkProbe`
precedent exactly.

`MachineSnapshot` is unchanged: no new fields, no API-spec changes to the
machine snapshot schema.

## Shape

1. `PuckEstimatorCapability` — a mixin on `UnifiedDe1`, alongside the existing
   `IntegratedScaleCapability` / `CupWarmerCapability` / etc. Decodes the
   transport's raw `0xA014` stream into `BengleEstSample` and drops
   undecodable frames (including the zero-length seed, which is why the seed is
   zero-length rather than 16 zero bytes).

2. `BengleInterface.puckEstimator` — a `Stream<BengleEstSample>`, the semantic
   member the sensor consumes. Mirrors `probeTemperature` / `probeAttached`.

3. `BenglePuckEstimator implements Sensor` — device id
   `<machineDeviceId>-puckestimator`, declaring one `DataChannel` per observer
   output with its unit, and emitting a keyed map per frame.

4. `BenglePuckEstimatorBridge` — registers the sensor with `SensorController`
   on the first decoded frame and unregisters on machine change or disconnect.
   Registration is data-driven rather than connection-driven because `0xA014`
   is serial/CDC only: a BLE-connected Bengle, an older firmware, or a plain
   DE1 never emits `[T]` and so must never show a phantom sensor.

## What this buys

Consumers read the estimator from `GET /api/v1/sensors`, its manifest at
`/api/v1/sensors/<id>`, and a live stream at `ws/v1/sensors/<id>/snapshot` —
all existing, already-specified surfaces. No new endpoints.

The sensor can expose the *whole* decoded frame, including `lagConf`,
`sigmaQ`, `lastPauseTau` and `rev`, which the `MachineSnapshot` fold dropped.

## Cost

Skins that read fused fields off the machine-snapshot websocket must move to the
sensor snapshot channel. Accepted deliberately: correctness of the abstraction
over continuity of the current bench build.

## Not in scope

`puckResistance`, `loadImpedance` and `hydraulicPower`
(`feat/derived-chart-channels`) stay as `MachineSnapshot` getters. They are pure
functions of `pressure` and `flow`, both of which upstream deliberately kept on
`MachineSnapshot`. They are derived machine telemetry, not observer output, and
so are unaffected by the rule above.
