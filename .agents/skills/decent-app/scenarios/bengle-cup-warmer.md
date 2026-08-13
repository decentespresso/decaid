# Scenario: Bengle cup-warmer + preheat + capability discovery

Verifies the Bengle cup-warmer surface end-to-end: capability discovery,
setpoint + manual enable (CupWarmerMode), live mat temperature, and the
firmware-owned scheduled pre-warm. `{ "temperature": 45 }` keeps its
historical meaning (set 45 °C AND make the manual cup warmer operate);
`{ "enabled": false }` disables manual heating without destroying the
persisted setpoint.

## Preconditions

```bash
scripts/sb-dev.sh start --connect-machine MockBengle --connect-scale MockScale
```

## Steps

### 1. Capability discovery

```bash
curl -sf http://localhost:8080/api/v1/machine/capabilities | jq -e '.capabilities | index("cupWarmer") != null'
curl -sf http://localhost:8080/api/v1/machine/capabilities | jq -e '.capabilities | index("preheat") != null'
curl -sf http://localhost:8080/api/v1/machine/capabilities | jq -e '.capabilities | index("wakeSchedule") != null'
```

Exit 0 → `cupWarmer`, `preheat` and `wakeSchedule` present.

### 2. Read initial state (off, no reading)

```bash
curl -sf http://localhost:8080/api/v1/machine/cupWarmer | jq -e '.temperature == 0 and .enabled == false and .currentTemperature == null'
```

Exit 0 → off, manual heating disabled, no valid NTC reading.

### 3. Set a setpoint (enables manual heating, back-compat)

```bash
curl -sf -X PUT http://localhost:8080/api/v1/machine/cupWarmer \
  -H 'Content-Type: application/json' \
  -d '{"temperature": 60}' \
  -o /dev/null -w '%{http_code}\n'
```

Expected: `200`.

### 4. Confirm the new state

```bash
curl -sf http://localhost:8080/api/v1/machine/cupWarmer | jq -e '.temperature == 60 and .enabled == true'
curl -sf http://localhost:8080/api/v1/machine/cupWarmer | jq -e '.currentTemperature == 42.0'
```

Exit 0 → setpoint stored, manual heating enabled, MockBengle simulates a
live NTC reading while enabled.

### 5. Disable manual heating without destroying the setpoint

```bash
curl -sf -X PUT http://localhost:8080/api/v1/machine/cupWarmer \
  -H 'Content-Type: application/json' \
  -d '{"enabled": false}' \
  -o /dev/null -w '%{http_code}\n'
curl -sf http://localhost:8080/api/v1/machine/cupWarmer | jq -e '.temperature == 60 and .enabled == false and .currentTemperature == null'
```

Exit 0 → setpoint survives; manual heating off (scheduled pre-warm still
has a target to use).

### 6. Set scheduled pre-warm

```bash
curl -sf -X PUT http://localhost:8080/api/v1/machine/cupWarmer/preheat \
  -H 'Content-Type: application/json' \
  -d '{"enabled": true, "leadMinutes": 45}' \
  -o /dev/null -w '%{http_code}\n'
curl -sf http://localhost:8080/api/v1/machine/cupWarmer/preheat | jq -e '.enabled == true and .leadMinutes == 45'
```

Exit 0 → pre-warm persisted (firmware owns all timing; the app stores
nothing).

### 7. Reject invalid input

```bash
curl -s -X PUT http://localhost:8080/api/v1/machine/cupWarmer \
  -H 'Content-Type: application/json' \
  -d '{"temperature": 100}' \
  -o /dev/null -w '%{http_code}\n'
curl -s -X PUT http://localhost:8080/api/v1/machine/cupWarmer/preheat \
  -H 'Content-Type: application/json' \
  -d '{"leadMinutes": 121}' \
  -o /dev/null -w '%{http_code}\n'
```

Expected: `400` for both (out-of-range setpoint / lead minutes rejected
before reaching the device).

### 8. Plain DE1 returns 404 / empty capabilities

Restart the app with a plain MockDe1:

```bash
scripts/sb-dev.sh stop
scripts/sb-dev.sh start --connect-machine MockDe1 --connect-scale MockScale
curl -sf http://localhost:8080/api/v1/machine/capabilities | jq -e '.capabilities == []'
curl -s http://localhost:8080/api/v1/machine/cupWarmer -o /dev/null -w '%{http_code}\n'
curl -s http://localhost:8080/api/v1/machine/cupWarmer/preheat -o /dev/null -w '%{http_code}\n'
```

Expected: empty `capabilities`; both endpoints return `404`.

## Postconditions

```bash
scripts/sb-dev.sh stop
```
