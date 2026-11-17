# Scenario: update-check capability refusals

End-to-end check of `/ws/v1/update` `{"command":"check"}` on a build that does
not own its own app updates. `canCheck` is `!isMacOS && !externallyManaged`, and
each clause refuses the command on its own with a direct `{"error", "url"}` reply
instead of polling GitHub.

The refusal is the point: a check that cannot run must say so, rather than settle
back to `idle` and read as "up to date".

**The two clauses are tested separately and on different hosts, because either
one alone is enough to refuse.** Running the ownership case on macOS proves
nothing about ownership: the platform clause refuses first, so the recipe still
passes with `!externallyManaged` deleted. Part A therefore requires a non-macOS
host and Part B requires macOS. Run the part your host supports; the other is
not skippable-but-fine, it is simply not runnable there.

## Part A — the ownership clause (`externallyManaged`)

**Host: Linux or Windows. Not macOS.**

```bash
[ "$(uname -s)" != "Darwin" ] || { echo "Part A cannot run on macOS"; exit 1; }
```

### Preconditions

An externally managed build is App Store / TestFlight, built with `APP_STORE=true`.

```bash
scripts/sb-dev.sh start --connect-machine MockDe1 --connect-scale MockScale \
  --dart-define APP_STORE=true
BASE=http://localhost:8080
WS=ws://localhost:8080
```

### The connect frame reports no update and no install

```bash
websocat -n1 "$WS/ws/v1/update" \
  | jq '{phase, latestVersion, installable, releaseUrl, error}'
# {"phase":"idle","latestVersion":null,"installable":false,
#  "releaseUrl":"https://github.com/decentespresso/decaid/releases","error":null}
```

An externally managed build never reports an available update, so `releaseUrl`
is the releases page rather than a release tag.

### check is refused, and says why

The seeded snapshot arrives first, then the command reply:

```bash
websocat --no-async-stdio -n -t --max-messages-rev 2 "$WS/ws/v1/update" <<'CMD' | tail -n1 | jq .
{"command":"check"}
CMD
# {"error":"App update checks are not supported on this build",
#  "url":"https://github.com/decentespresso/decaid/releases"}
```

One-shot assertion:

```bash
websocat --no-async-stdio -n -t --max-messages-rev 2 "$WS/ws/v1/update" <<'CMD' | tail -n1 \
  | jq -e '(.error | contains("not supported")) and (.url | contains("releases"))'
{"command":"check"}
CMD
```

Exit 0 means the refusal reached the client.

**What this catches.** Delete `&& !externallyManaged` from `canCheck` and this
assertion fails on a non-macOS host: the command is accepted, `requestCheck()`
reaches the `externallyManaged` branch of `checkForUpdate()`, and the client gets
a state frame carrying `"phase":"idle"` — indistinguishable from a real
"checked, you are up to date". A hang or a frame carrying `phase` is the
regression.

### Control: an ordinary build on the same host still polls

```bash
scripts/sb-dev.sh stop
scripts/sb-dev.sh start --connect-machine MockDe1 --connect-scale MockScale
```

```bash
websocat --no-async-stdio -n -t --max-messages-rev 2 "$WS/ws/v1/update" <<'CMD' | tail -n1 | jq .
{"command":"check"}
CMD
```

Expect a state frame with `"phase":"checking"` — not an `{"error", "url"}`
reply. This is what proves the refusal above came from `APP_STORE=true` and not
from the host. Whatever follows depends on the network and on what is published:
`available`, `idle`, or `error` with `"error":"Update check failed: ..."`.
A state frame carries `phase` and `currentVersion`; a command refusal carries
only `error` and `url`.

### REST is unchanged

`GET /api/v1/update` exposes no capability field, so it returns the same snapshot
on a managed build as anywhere else:

```bash
curl -sf "$BASE/api/v1/update" | jq '{phase, latestVersion, installable}'
# {"phase":"idle","latestVersion":null,"installable":false}
```

### Postconditions

```bash
scripts/sb-dev.sh stop
```

## Part B — the platform clause (`isMacOS`)

**Host: macOS.** Sparkle owns app updates there, so an ordinary build refuses the
command for a reason that has nothing to do with `APP_STORE`.

```bash
[ "$(uname -s)" = "Darwin" ] || { echo "Part B only runs on macOS"; exit 1; }
scripts/sb-dev.sh start --platform macos --connect-machine MockDe1 --connect-scale MockScale
WS=ws://localhost:8080
```

No `APP_STORE` define: this is an ordinary build.

```bash
websocat --no-async-stdio -n -t --max-messages-rev 2 "$WS/ws/v1/update" <<'CMD' | tail -n1 \
  | jq -e '(.error | contains("not supported")) and (.url | contains("releases"))'
{"command":"check"}
CMD
```

**What this catches.** Delete `!_isMacOS` from `canCheck` and this fails: the
command is accepted and `checkForUpdate()` returns at its macOS branch without
emitting anything, so the client waits for a reply that never comes.

```bash
scripts/sb-dev.sh stop
```
