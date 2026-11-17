# Scenario: Bengle primary with an auxiliary scale

This exercises the runtime-only auxiliary scale API in simulation. The Bengle
integrated scale remains primary while `MockScale` is explicitly connected as
an auxiliary session.

## Start

```bash
scripts/sb-dev.sh start --connect-machine MockBengle
BASE=http://localhost:8080
WS=ws://localhost:8080
```

Confirm Bengle is primary and record the persisted preference:

```bash
curl -sf "$BASE/api/v1/devices" | jq .
PREFERRED=$(curl -sf "$BASE/api/v1/settings" | jq -c '.preferredScaleId // null')
PRIMARY=$(curl -sf "$BASE/api/v1/devices" | jq -r '.[] | select(.type == "scale" and .state == "connected" and .connectionRole == "primary") | .id' | head -n1)
test -n "$PRIMARY"
curl -sf -X PUT "$BASE/api/v1/scale/tare" >/dev/null
websocat --no-async-stdio -n -U -t --max-messages-rev 3 "$WS/ws/v1/scale/snapshot" | jq -s -e 'any(.[]; has("weightFlow"))'

curl -sf "$BASE/api/v1/devices/scan?connect=false" | jq -e \
  'any(.[]; .id == "MockScale" and .state == "discovered")'
curl -sf "$BASE/api/v1/devices" | jq -e \
  'any(.[]; .type == "scale" and .state == "connected" and .connectionRole == "primary")'
```

## Connect the external scale as auxiliary

```bash
curl -sf -X PUT "$BASE/api/v1/devices/connect" \
  -H 'content-type: application/json' \
  -d '{"deviceId":"MockScale","connectionRole":"auxiliary"}' | jq .
curl -sf "$BASE/api/v1/devices" | jq -e \
  '.[] | select(.id == "MockScale" and .state == "connected" and .connectionRole == "auxiliary")'
```

The same request is idempotent and must not replace Bengle:

```bash
curl -sf -X PUT "$BASE/api/v1/devices/connect" \
  -H 'content-type: application/json' \
  -d '{"deviceId":"MockScale","connectionRole":"auxiliary"}' | jq -e '.outcome == "alreadyConnected"'
test "$(curl -sf "$BASE/api/v1/settings" | jq -c '.preferredScaleId // null')" = "$PREFERRED"
```

## Addressed tare and raw snapshot

```bash
curl -sf -X PUT "$BASE/api/v1/scales/MockScale/tare" | jq -e '. == null'
websocat --no-async-stdio -n -U -t --max-messages-rev 2 \
  "$WS/ws/v1/scales/MockScale/snapshot" | jq -c .
```

The addressed stream emits a status frame and raw snapshot fields
`timestamp`, `weight`, `batteryLevel`, `timerValue`, and `flow`. The legacy
stream continues to expose `weightFlow` and remains attached to Bengle.

## Disconnect and cleanup

```bash
curl -sf -X PUT "$BASE/api/v1/devices/disconnect" \
  -H 'content-type: application/json' -d '{"deviceId":"MockScale"}' | jq .
curl -sf "$BASE/api/v1/devices" | jq -e \
  'all(.[] | select(.id == "MockScale") | .connectionRole == null or .state != "connected")'
curl -sf -X PUT "$BASE/api/v1/scale/tare" >/dev/null
scripts/sb-dev.sh stop
```

Expected: Bengle remains the connected primary throughout, auxiliary tare does
not affect shot state, disconnect releases the auxiliary reservation, and the
legacy primary tare/snapshot routes remain usable.
