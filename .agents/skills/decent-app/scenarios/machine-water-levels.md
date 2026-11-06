# Scenario: machine water levels read

Verifies `GET /api/v1/machine/waterLevels` answers the payload `/ws/v1/machine/waterLevels` sends, and the
machine-read error when no machine is connected.

`MockDe1` reports `{"currentLevel": 50.0, "refillLevel": 5.0}` once a second and ignores
`POST /api/v1/machine/waterLevels`, so this scenario covers the read path only. The first GET after connect
can take up to a second while the mock sends its first report.

## Preconditions

```bash
scripts/sb-dev.sh start --connect-machine MockDe1 --connect-scale MockScale
```

## Steps

1. The REST read matches the mock's report:

   ```bash
   curl -sf http://localhost:8080/api/v1/machine/waterLevels \
     | jq -e '.currentLevel == 50 and .refillLevel == 5'
   ```

   Exit 0 means the read returned the mock's levels.

2. The socket sends the same shape. Use a persistent client (see AGENTS.md):

   ```bash
   timeout 3 websocat ws://localhost:8080/ws/v1/machine/waterLevels | head -1 | jq .
   ```

   Expected: `{"currentLevel": 50.0, "refillLevel": 5.0}`.

3. With no machine connected, the read fails like the other machine reads. Disconnect `MockDe1` through the
   simulate-only debug route and send the GET straight away: `ConnectionManager` re-adopts the preferred
   machine about 5 seconds after an unexpected disconnect.

   ```bash
   curl -sf -X POST http://localhost:8080/api/v1/debug/machine/disconnect | jq .
   curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8080/api/v1/machine/waterLevels
   ```

   Expected: `{"status": "disconnected"}`, then `500`.

## Postconditions

```bash
scripts/sb-dev.sh stop
```
