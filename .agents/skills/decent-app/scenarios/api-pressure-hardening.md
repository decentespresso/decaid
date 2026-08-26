# Scenario: API pressure hardening

Finite simulate-mode check for chatty workflow clients, admission rejection,
machine telemetry, and the direct idle path.

## Preconditions

```bash
scripts/sb-dev.sh start --connect-machine MockDe1
BASE=http://localhost:8080
WS=ws://localhost:8080
```

Confirm the simulated machine is connected:

```bash
curl -sf "$BASE/api/v1/devices" \
  | jq -e '.[] | select(.name == "MockDe1" and .state == "connected")'
```

## Finite pressure burst

Keep the machine snapshot stream open while 500 workflow mutations run with
at most 64 concurrent clients. The idle request is made during the burst and
retried only when generic API admission rejects it.

```bash
rm -f /tmp/decaid-pressure-status /tmp/decaid-pressure-snapshot.jsonl
websocat "$WS/ws/v1/machine/snapshot" \
  > /tmp/decaid-pressure-snapshot.jsonl &
WS_PID=$!

(
  for i in $(seq 1 500); do
    case $((i % 3)) in
      0) field=steamSettings; key=duration; value=$((10 + i % 40)) ;;
      1) field=hotWaterData; key=volume; value=$((50 + i % 150)) ;;
      2) field=rinseData; key=flow; value=$((2 + i % 8)) ;;
    esac

    (
      code=$(curl -s -o /dev/null -w '%{http_code}' \
        -X PUT "$BASE/api/v1/workflow" \
        -H 'content-type: application/json' \
        -d "{\"$field\":{\"$key\":$value}}")
      printf '%s %s %s %s\n' "$i" "$field" "$value" "$code" \
        >> /tmp/decaid-pressure-status
      if ((i % 25 == 0)); then
        curl -sf "$BASE/api/v1/machine/state" >/dev/null || true
      fi
    ) &

    while (( $(jobs -rp | wc -l) >= 64 )); do
      wait -n || true
    done

    if ((i == 100)); then
      idle_ok=false
      for attempt in $(seq 1 20); do
        if curl -sf -X PUT "$BASE/api/v1/machine/state/idle" >/dev/null; then
          idle_ok=true
          break
        fi
        sleep 1
      done
      test "$idle_ok" = true
    fi
  done
  wait
)
```

The run is finite. Successful and rejected requests must account for all 500
attempts; overload may return `429` or `503`.

```bash
awk '$4 == 200 {ok++} $4 == 429 {limited++} $4 == 503 {busy++}
     END {print "ok=" ok+0, "429=" limited+0, "503=" busy+0;
          exit (ok+limited+busy == 500 ? 0 : 1)}' \
  /tmp/decaid-pressure-status
```

## Final admitted state

Send one deterministic final mutation after pressure has drained. Retry on
admission rejection, then prove all three fields reached the workflow.

```bash
final_ok=false
for attempt in $(seq 1 20); do
  if curl -sf -X PUT "$BASE/api/v1/workflow" \
    -H 'content-type: application/json' \
    -d '{"steamSettings":{"duration":47},"hotWaterData":{"volume":121},"rinseData":{"flow":3.25}}' \
    >/dev/null; then
    final_ok=true
    break
  fi
  sleep 1
done
test "$final_ok" = true

curl -sf "$BASE/api/v1/workflow" | jq -e '
  .steamSettings.duration == 47 and
  .hotWaterData.volume == 121 and
  .rinseData.flow == 3.25'
curl -sf "$BASE/api/v1/machine/state" | jq -e '.state.state == "idle"'
curl -sf "$BASE/api/v1/devices" \
  | jq -e '.[] | select(.name == "MockDe1" and .state == "connected")'
test "$(wc -l < /tmp/decaid-pressure-snapshot.jsonl)" -gt 0
```

## Postconditions

```bash
kill "$WS_PID" 2>/dev/null || true
scripts/sb-dev.sh logs --filter error -n 50
scripts/sb-dev.sh stop
```

For an optional longer manual run, raise the finite loop count while keeping
the concurrency cap. Do not turn it into an endless soak or a normal CI job.
