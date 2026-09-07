# WebSocket recipes

Subscribing to Decent's live channels from a shell with `websocat`. The **authoritative** channel reference is `assets/api/websocket_v1.yml` (AsyncAPI 3.0) — every channel address, message shape, and bidi command lives there. Read the spec first; don't guess channel paths or payloads.

## Install

Primary tool: `websocat`.

```bash
brew install websocat                     # macOS
apt install websocat                      # Debian / Ubuntu
cargo install websocat                    # anywhere with rust
```

Fallback if websocat isn't available: `npm install -g wscat`. All examples below use websocat flags.

## One-shot snapshot — the default

Each shell call may be independent, so bounded reads are the safe default. Bound by message count (`--max-messages-rev N`) so websocat exits after receiving N messages.

```bash
websocat --no-async-stdio -n -U -t --max-messages-rev 5 \
  ws://localhost:8080/ws/v1/machine/snapshot | jq .
```

Flag breakdown (all four are needed for a clean agent-shell run):

- `--no-async-stdio` — forces blocking stdio. Required on macOS; without it, `-t` against piped/redirected stdout fails with `Invalid argument (os error 22)`.
- `-n` / `--no-close` — don't close the socket when our stdin hits EOF. Our stdin is a pipe or `/dev/null`, so EOF is immediate — without this we'd quit before the server sends anything.
- `-U` — inhibit our stdin→WebSocket direction entirely. Receive-only. Do NOT use this for bidirectional channels; see below.
- `-t` — websocket text mode. Required, and websocat will warn if omitted.
- `--max-messages-rev N` — stop after receiving N messages from the server. (`--max-messages` without `-rev` bounds what we *send*, not what we receive.)

Adding a safety-net timeout is optional but cheap if you want to guarantee the shell comes back. macOS ships without GNU `timeout`; install `coreutils` for `gtimeout`, or just trust `--max-messages-rev`:

```bash
gtimeout 5 websocat --no-async-stdio -n -U -t --max-messages-rev 5 \
  ws://localhost:8080/ws/v1/machine/snapshot | jq .
```

## Background subscription

For long-lived tailing across multiple Bash calls, persist the pid to a file (shell variables do not survive between calls):

```bash
websocat --no-async-stdio -n -U -t ws://localhost:8080/ws/v1/machine/snapshot \
  > /tmp/sb-stream.log 2>&1 &
echo $! > /tmp/sb-stream.pid
# … do other work in later Bash calls …
tail -n 50 /tmp/sb-stream.log
kill "$(cat /tmp/sb-stream.pid)" && rm /tmp/sb-stream.pid
```

Same flags as the one-shot form but without `--max-messages-rev` so the subscription runs until you kill it.

## Bidirectional channels

Several channels are bidirectional. Consult `assets/api/websocket_v1.yml` for the current channel and payload inventory. Drop `-U` when sending and bound by `--max-messages-rev` so the shell returns after the acknowledgement. This representative example starts a device scan:

```bash
echo '{"command": "scan", "connect": false, "quick": true}' \
  | websocat --no-async-stdio -n -t --max-messages-rev 1 \
      ws://localhost:8080/ws/v1/devices
```

The field is `command`, not `cmd`. `DevicesCommand.command` enum: `scan`, `connect`, `disconnect` (`connect` / `disconnect` also need `deviceId`).

## jq parsing

Extract a single field from the machine snapshot stream:

```bash
websocat --no-async-stdio -n -U -t --max-messages-rev 5 \
  ws://localhost:8080/ws/v1/machine/snapshot | jq -c '.pressure'
```

Filter events — only pouring substates:

```bash
websocat --no-async-stdio -n -U -t --max-messages-rev 50 \
  ws://localhost:8080/ws/v1/machine/snapshot \
  | jq -c 'select(.state.substate == "pouring")'
```

Tune `--max-messages-rev` to how long you expect the interesting substate to last; at ~2Hz, 50 messages is ~25s of stream.

## See also

- `lifecycle.md` — starting / restarting the flutter process before any of this works.
- `rest.md` — when the data you want is a single GET, not a stream.
