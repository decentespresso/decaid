# REST recipes

Hitting Decent's REST API from a shell with `curl` and `jq`. The **authoritative** endpoint reference is `assets/api/rest_v1.yml` (OpenAPI 3.0) — never guess paths or payload shapes, read the spec. This file is only a pocket reference for the common moves.

## Base URL

Default is `http://localhost:8080`. `sb-dev` honours `SB_HOST` and `SB_PORT` for its own health checks; use them to build URLs in scripts:

```bash
BASE="http://${SB_HOST:-localhost}:${SB_PORT:-8080}"
curl -sf "$BASE/api/v1/devices" | jq .
```

All examples below use `-sf` (silent + fail-on-HTTP-error) so scripts bail on non-2xx.

## One example per verb

GET machine snapshot:

```bash
curl -sf http://localhost:8080/api/v1/machine/state | jq .
```

PUT a state change (path param, no body):

```bash
curl -sf -X PUT http://localhost:8080/api/v1/machine/state/idle
```

POST JSON body (partial patch, only keys you send are applied):

```bash
curl -sf -X POST http://localhost:8080/api/v1/machine/settings \
  -H 'content-type: application/json' \
  -d '{"tankTemp": 20}'
```

GET a list + `jq` filter — names of every connected device:

```bash
curl -sf http://localhost:8080/api/v1/devices \
  | jq -r '.[] | select(.state == "connected") | .name'
```

## Gotchas that aren't in the spec

- **`/api/v1/machine/state` returns 500 until a DE1 is connected.** `De1Handler.withDe1()` wraps `connectedDe1()` in a try/catch and serves `jsonError` (HTTP 500) on failure, so don't use it for liveness. `sb-dev wait_ready` polls `/api/v1/devices` instead — do the same.
- **`POST /api/v1/machine/profile` takes the full profile object,** not a patch — the handler does `Profile.fromJson(json)` and any missing required field throws. Run `sb-dev status` first to confirm a machine is actually connected; otherwise you'll get a 500 from `withDe1`.
- **`/api/v1/machine/settings` keys are terse.** The POST handler reads `tankTemp`, `flushTemp`, `flushFlow`, `steamFlow`, `hotWaterFlow`, etc. — not the long `tankTemperature` style. Check `lib/src/services/webserver/de1handler.dart` for the exact set.
- **Don't blindly `GET /api/v1/shots`.** History can be large. Use `/api/v1/shots/ids`, `/api/v1/shots/latest`, or `/api/v1/shots/{id}` and page / filter. The list response already omits measurements for performance; full records are only in the single-shot endpoint.

## Quick machine-connected check

`scripts/sb-dev.sh status` already curls `/api/v1/devices` and pretty-prints the result — fastest way to answer "is a machine up" without memorising payload shapes.

## Inspect application logs

`GET /api/v1/logs` returns plain text from the live log and rotated log files. It defaults to the most recent 1024 KB in newest-first order. Use `kb` to choose a tail window (maximum 4096 KB) and `order=asc` when chronology matters.

Download the full available window before filtering it. Use `localhost` when Decent runs on the same machine; otherwise replace it with the tablet's LAN hostname or IP address (for example, `de1tablet.home` or `192.168.1.42`):

```bash
BASE=http://localhost:8080
curl -sf "$BASE/api/v1/logs?kb=4096&order=asc" -o /tmp/decaid.log
rg -ni 'error|warning|severe|exception|failed' /tmp/decaid.log
```

Use narrower searches for the subsystem or device under investigation, and inspect surrounding lines rather than relying only on the error-level search:

```bash
rg -ni 'bengle|tap|scan|sensor' /tmp/decaid.log
```

For a quick look at only the newest entries, omit `order=asc` and request a smaller window:

```bash
curl -sf "$BASE/api/v1/logs?kb=128"
```

## When REST isn't enough

Live telemetry (shot frames, scale weights, snapshot stream) is WebSocket-only. See `websocket.md`.
