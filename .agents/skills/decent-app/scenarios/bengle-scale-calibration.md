# Scenario: Bengle scale calibration

Exercises the current-firmware scale-calibration surface on a `MockBengle`:
capability discovery, packed state decode, `zero`/`latch`/`abort` commands,
and validation. Quick tare is deliberately NOT exposed here — Decaid has the
integrated-scale tare path. Commands 4/5 (explicit left/right latches) are
retired in current firmware and never surface.

The real firmware procedure for `latch` (platform removed, known mass on
either isolated load cell; auto-detects the cell; run once per cell — the
second distinct-cell latch solves and persists) is documented in the API
spec; the mock accepts the command and reports an in-progress state.

## Preconditions

```bash
scripts/sb-dev.sh start --connect-machine MockBengle --connect-scale MockScale
```

## Steps

### 1. Capability discovery

```bash
curl -sf http://localhost:8080/api/v1/machine/capabilities | jq -e '.capabilities | index("scaleCalibration") != null'
```

Exit 0 → `scaleCalibration` present.

### 2. Read the idle state

```bash
curl -sf http://localhost:8080/api/v1/machine/scaleCalibration | jq -e '.step == "idle" and .status == "none" and .detectedCell == "none"'
```

Exit 0 → decoded idle state.

### 3. Start a precision zero

```bash
curl -sf -X PUT http://localhost:8080/api/v1/machine/scaleCalibration \
  -H 'Content-Type: application/json' \
  -d '{"command": "zero"}' | jq
```

Expect `202` with `{"status": "accepted", "state": {"step": "zeroing", ...}}`.

### 4. Latch with a known weight (fractional grams allowed)

```bash
curl -sf -X PUT http://localhost:8080/api/v1/machine/scaleCalibration \
  -H 'Content-Type: application/json' \
  -d '{"command": "latch", "weightGrams": 45.5}' | jq
```

Expect `202` with `{"status": "accepted", "state": {"step": "calLatch", ...}}`.

### 5. Abort

```bash
curl -sf -X PUT http://localhost:8080/api/v1/machine/scaleCalibration \
  -H 'Content-Type: application/json' \
  -d '{"command": "abort"}' | jq
```

Expect `202` with the state back at `step: "idle"`.

### 6. Reject invalid input

```bash
curl -s -X PUT http://localhost:8080/api/v1/machine/scaleCalibration \
  -H 'Content-Type: application/json' \
  -d '{"command": "left"}' -o /dev/null -w '%{http_code}\n'
curl -s -X PUT http://localhost:8080/api/v1/machine/scaleCalibration \
  -H 'Content-Type: application/json' \
  -d '{"command": "latch"}' -o /dev/null -w '%{http_code}\n'
curl -s -X PUT http://localhost:8080/api/v1/machine/scaleCalibration \
  -H 'Content-Type: application/json' \
  -d '{"command": "latch", "weightGrams": 20000}' -o /dev/null -w '%{http_code}\n'
```

Expected: `400` for all three (unknown command / missing weight / weight out
of the 1..10000 g range).

### 7. Plain DE1 returns 404

```bash
scripts/sb-dev.sh stop
scripts/sb-dev.sh start --connect-machine MockDe1 --connect-scale MockScale
curl -s http://localhost:8080/api/v1/machine/scaleCalibration -o /dev/null -w '%{http_code}\n'
curl -s -X PUT http://localhost:8080/api/v1/machine/scaleCalibration \
  -H 'Content-Type: application/json' -d '{"command": "zero"}' -o /dev/null -w '%{http_code}\n'
```

Expected: `404` for both.

## Postconditions

```bash
scripts/sb-dev.sh stop
```
