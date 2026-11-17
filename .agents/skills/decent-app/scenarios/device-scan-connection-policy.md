# Scenario: device scan connection policy

Verifies that explicit REST and WebSocket scans preserve occupied machine and
scale slots, that omitted `connect` defaults to `true`, and that
`connect=false` remains discovery-only.

## Preconditions

```bash
scripts/sb-dev.sh start --connect-machine MockDe1 --connect-scale MockScale
BASE=http://localhost:8080
```

Wait for both simulated devices to report `connected`:

```bash
curl -sf "$BASE/api/v1/devices" | jq '[.[] | select(.state == "connected") | .id]'
```

Save the connected IDs:

```bash
BEFORE=$(curl -sf "$BASE/api/v1/devices" \
  | jq -c '[.[] | select(.state == "connected") | .id] | sort')
```

## REST default scan

```bash
curl -sf "$BASE/api/v1/devices/scan"
AFTER=$(curl -sf "$BASE/api/v1/devices" \
  | jq -c '[.[] | select(.state == "connected") | .id] | sort')
test "$AFTER" = "$BEFORE"
```

The request waits for a scan-first connection cycle. Both original IDs remain
connected and no replacement connection is attempted.

## REST discovery-only scan

```bash
curl -sf "$BASE/api/v1/devices/scan?connect=false"
AFTER=$(curl -sf "$BASE/api/v1/devices" \
  | jq -c '[.[] | select(.state == "connected") | .id] | sort')
test "$AFTER" = "$BEFORE"
```

The scan updates discovery results without changing either occupied slot.

## WebSocket default scan

```bash
printf '%s\n' '{"command":"scan","quick":false}' \
  | websocat -n1 "ws://localhost:8080/ws/v1/devices"
AFTER=$(curl -sf "$BASE/api/v1/devices" \
  | jq -c '[.[] | select(.state == "connected") | .id] | sort')
test "$AFTER" = "$BEFORE"
```

Omitting `connect` is equivalent to `connect=true`. `quick=false` waits for the
scan result; it does not change connection policy.

## WebSocket discovery-only scan

```bash
printf '%s\n' '{"command":"scan","connect":false,"quick":false}' \
  | websocat -n1 "ws://localhost:8080/ws/v1/devices"
AFTER=$(curl -sf "$BASE/api/v1/devices" \
  | jq -c '[.[] | select(.state == "connected") | .id] | sort')
test "$AFTER" = "$BEFORE"
```

## Post-wake preferred-scale recovery

The protected window is not reachable in the simulator: it only arms when a
connected machine transitions from sleeping to awake while the preferred BLE
scale is disconnected and background `ScaleWatch` is the selected
reacquisition mechanism. Deterministic coverage of the deferral lives in
`test/controllers/connection_manager_test.dart` and in the
`deferred scans during the post-wake scale lease` groups of
`test/devices_handler_test.dart` and `test/devices_ws_test.dart`.

Contract that those tests assert, and that a hardware run confirms from the
logs and from the device state:

- a REST or WebSocket scan issued inside the window, `connect=false`
  included, is deferred instead of started, and does not pause the background
  watch;
- repeated requests coalesce into one pending scan, and at most one scan runs
  once the window closes;
- the pending scan is dropped when the preferred scale reconnects first, the
  machine disconnects, the preferred scale is cleared, or Decaid shuts down;
- `quick=true` returns at once and never reports scan failures, whether the
  scan starts immediately or after the window;
- a native in-app scan control (launcher or retry UI) supersedes a deferred
  discovery-only request and still performs the full connection policy.

Support logs carry the arbitration: `Explicit scan source=REST|devices-WS ...`
reports phase, active connection work and disposition, the deferred run logs
`Post-wake lease ended; running one deferred client scan`, and superseding a
deferred discovery-only request logs `Explicit scan superseded the deferred
discovery-only client scan`.

## Postconditions

```bash
scripts/sb-dev.sh stop
```

## Real-hardware extension

Repeat the REST and WebSocket default scans with an attached DE1 and scale.
Confirm from the device LEDs, app status, and logs that neither BLE link drops
or reconnects. Ambiguous multi-device selection and Bengle integrated-scale
precedence require the corresponding physical devices and remain separate
hardware validation steps.

Then cover the post-wake window itself:

1. connect the DE1 and the preferred BLE scale, then power the scale off;
2. put the machine to sleep and wake it again;
3. immediately after wake, run the REST and WebSocket scans above - including
   repeated `connect=false` requests and one native scan from the app;
4. confirm the scale reconnects without a manual scan, that the watch was not
   paused by the client requests, and that the deferred scan ran at most once
   after the window.

`curl` and `websocat` steps are unchanged; only the timing and the scale power
state differ, so run them from the host while the phone or desktop app drives
the machine.
