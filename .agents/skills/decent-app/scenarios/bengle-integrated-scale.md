# Scenario: Bengle integrated scale end-to-end

Verifies that when a Bengle is the connected machine, the integrated scale is auto-attached as a virtual scale (no external scale connection needed), capability discovery advertises all Bengle surfaces, the `/api/v1/scale/*` REST surface and `/ws/v1/scale/snapshot` stream both flow through the integrated scale, and Bengle firmware stops an espresso shot autonomously when the integrated scale weight reaches the configured target.

## Preconditions

```bash
scripts/sb-dev.sh start --connect-machine MockBengle
```

No `--connect-scale` flag. On Bengle the integrated scale always wins — external scale scanning is skipped, and `preferredScaleId` is ignored. See `doc/DeviceManagement.md` → "Bengle integrated scale".

## Steps

### 1. Capability discovery lists all Bengle surfaces

```bash
curl -sf http://localhost:8080/api/v1/machine/capabilities | jq .
```

Expected:

```json
{ "capabilities": ["cupWarmer", "integratedScale", "ledStrip", "stopAtWeight"] }
```

Quick assertions:

```bash
curl -sf http://localhost:8080/api/v1/machine/capabilities \
  | jq -e '.capabilities | contains(["cupWarmer", "integratedScale", "ledStrip", "stopAtWeight"])'
```

Exit 0 means all four identifiers are present.

### 2. Scale snapshot stream is alive without an external scale

```bash
websocat --no-async-stdio -n -U -t --max-messages-rev 5 \
  ws://localhost:8080/ws/v1/scale/snapshot | jq -c .
```

Expected: snapshot frames with `weight`, `weightFlow`, etc. — the virtual `BengleVirtualScale` is feeding `ScaleController`. No `{"status":"disconnected"}` frames.

### 3. Tare zeroes the integrated scale

```bash
curl -s -X PUT http://localhost:8080/api/v1/scale/tare
```

Expected: `200 OK`, empty body.

Re-sample the snapshot and confirm weight is ~0 (MockBengle resets `_tareOffset` to the current accumulated weight, so the next emission reads near zero):

```bash
websocat --no-async-stdio -n -U -t --max-messages-rev 1 \
  ws://localhost:8080/ws/v1/scale/snapshot | jq '.weight'
```

Expected: a value within ~±0.1 g of zero.

### 4. Run a shot — Bengle firmware stops at the profile target weight

Upload the bundled flow profile (target weight = 36 g):

```bash
curl -sf -X POST http://localhost:8080/api/v1/machine/profile \
  -H 'Content-Type: application/json' \
  --data @assets/defaultProfiles/Flow_profile_for_straight_espresso.json
```

Set the matching workflow target that `BengleSawBridge` writes to firmware:

```bash
curl -sf -X PUT http://localhost:8080/api/v1/workflow \
  -H 'Content-Type: application/json' \
  --data '{"context":{"targetYield":36}}'
```

Tare, then start the espresso shot:

```bash
curl -s -X PUT http://localhost:8080/api/v1/scale/tare
curl -sX PUT http://localhost:8080/api/v1/machine/state/espresso
```

Watch the machine snapshot stream. `BengleSawBridge` reflects the workflow's 36 g target into the firmware SAW register. `MockBengle` models the firmware by integrating flow into weight and returning the machine to `idle` when that target is reached. `ShotSequencer` observes the machine transition instead of issuing a competing app-side stop:

```bash
websocat --no-async-stdio -n -U -t --max-messages-rev 200 \
  ws://localhost:8080/ws/v1/machine/snapshot | jq -c '{state, substate}'
```

Expected sequence ends with `state == "idle"` once the integrated scale reaches approximately 36 g. The transition originates from `MockBengle`, matching firmware-autonomous SAW.

### 5. No external scale connection ever happened

```bash
curl -sf http://localhost:8080/api/v1/devices | jq '.[] | select(.type=="scale") | {name, state}'
```

Expected: empty (no external scale was scanned for or connected). The integrated scale exposes itself via `/api/v1/scale/*` and `/ws/v1/scale/snapshot` without appearing as a discoverable device.

## Postconditions

```bash
scripts/sb-dev.sh stop
```

## Notes

- **Why no `--connect-scale`?** On Bengle, `ConnectionManager` skips the external-scale phase entirely (see `doc/DeviceManagement.md`). Passing `--connect-scale MockScale` will be ignored / overridden by the integrated-scale auto-attach.
- **Profile and workflow targets are set separately.** The bundled `Flow_profile_for_straight_espresso.json` ships with `target_weight: 36`. Uploading it configures the machine profile; the `/api/v1/workflow` update sets the firmware SAW target for this run.
- **Stop is firmware-autonomous SAW.** Decaid writes `WorkflowContext.targetYield` to `EndOfShotWeight`; Bengle owns the stop decision and the resulting machine state propagates back to Decaid. `MockBengle` models that ownership in simulation.
