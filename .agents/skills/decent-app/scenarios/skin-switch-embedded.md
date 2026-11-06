# Scenario: embedded skin switching (`decentApp.switchSkin`)

Manual end-to-end check of the embedded-only skin switch hook: A -> B -> A inside
the app, port adoption, rejection cases, single-flight behaviour, external-browser
no-op, and failure-to-serve rollback. No espresso hardware is needed.

Fixture skins: `test/fixtures/skins/switch-test-a` and
`test/fixtures/skins/switch-test-b`. Each page prints its skin id, origin and
port, whether `switchSkin` and the host flag are present, and the return value of
every call.

## Preconditions

```bash
scripts/sb-dev.sh start --connect-machine MockDe1
BASE=http://localhost:8080
```

Nothing else may hold ports 3000, 4001 or 8080 — a packaged Decaid running on the
same machine does, and the dev instance then fails to bind.

## Install the fixtures

Either copy the directories into the app's skin directory and restart the app:

```bash
# macOS (sandboxed app container)
SKINS="$HOME/Library/Containers/net.tadel.reaprime/Data/Library/Application Support/net.tadel.reaprime/web-ui"
cp -R test/fixtures/skins/switch-test-a test/fixtures/skins/switch-test-b "$SKINS/"
scripts/sb-dev.sh restart --connect-machine MockDe1
```

or install them over REST from a local HTTP server, which also works for Android:

```bash
( cd test/fixtures/skins && zip -qr /tmp/switch-test-a.zip switch-test-a \
    && zip -qr /tmp/switch-test-b.zip switch-test-b )
( cd /tmp && python3 -m http.server 8099 >/dev/null 2>&1 & echo $! > /tmp/fixture-server.pid )

for skin in a b; do
  curl -sf -X POST "$BASE/api/v1/webui/skins/install/url" \
    -H 'content-type: application/json' \
    -d "{\"url\": \"http://localhost:8099/switch-test-$skin.zip\"}" | jq .
done

kill "$(cat /tmp/fixture-server.pid)"
```

Confirm both are installed:

```bash
curl -sf "$BASE/api/v1/webui/skins" | jq '[.[] | select(.id | startswith("switch-test")) | .id]'
# ["switch-test-a", "switch-test-b"]
```

## Open skin A in the embedded view

```bash
curl -sf -X PUT "$BASE/api/v1/webui/skins/default" \
  -H 'content-type: application/json' -d '{"skinId": "switch-test-a"}' | jq .
curl -sf -X POST "$BASE/api/v1/webui/server/stop" | jq .
curl -sf -X POST "$BASE/api/v1/webui/server/start" | jq .
curl -sf "$BASE/api/v1/webui/server/status" | jq '{isServing, port}'
```

In the app, open the skin from the dashboard. The page must show `SKIN A`, the
served port from the status call, `switchSkin: present, host flag set (embedded)`.

## A -> B -> A

Press **Switch to B**. Expect, with no sleep and no system browser:

- the app stays in the embedded view and shows `SKIN B`;
- the `host` line shows a different port than skin A did;
- `curl -sf "$BASE/api/v1/webui/server/status" | jq '{port}'` matches that port;
- `curl -sf "$BASE/api/v1/webui/skins/default" | jq .id` is `switch-test-b`.

Press **Switch to A** on skin B and check the same three facts in reverse. The
log line `switchSkin("switch-test-a") returned true` appears before the page is
replaced.

## Rejection and single-flight cases

| Action | Expected |
|---|---|
| **Switch to missing id** | Page stays on the current skin, snackbar `Skin not installed: switch-test-missing`, server status port unchanged, default skin unchanged |
| **Switch to <current> (same skin)** | Nothing happens: no reload, no snackbar, port unchanged |
| **Rapid double switch** | Exactly one switch takes effect (the first id), snackbar `A skin switch is already in progress`, no duplicate restart in the log, server status port matches the skin that is displayed |

## External browser is a no-op

```bash
open "http://localhost:3000"   # macOS; or browse to <device-ip>:3000
```

The same page in a normal browser must show
`switchSkin: present, host flag absent (external browser)`. Pressing **Switch to
B** logs `switchSkin("switch-test-b") returned false`, the page does not change,
and the embedded view and server stay on the current skin. Use the REST calls in
the previous section to switch skins from a browser.

## Failure to serve and rollback

With skin A displayed, make skin B unservable and request it:

```bash
mv "$SKINS/switch-test-b" "$SKINS/switch-test-b.hidden"
```

Press **Switch to B**. Expect: skin A still displayed and still interactive, a
snackbar `Could not switch to switch-test-b — kept the previous skin`, the server
status port back on skin A's port, and `webui/skins/default` still
`switch-test-a`. Then restore and confirm a later switch still works:

```bash
mv "$SKINS/switch-test-b.hidden" "$SKINS/switch-test-b"
```

Press **Switch to B** again; it must succeed.

## Android

Run the same steps on an Android target (`scripts/sb-dev.sh start --platform
<device-id> --adb-forward`), installing the fixtures over REST. The embedded
WebView path differs from desktop, so desktop results do not stand in for it.
Report the Android run separately.

## Postconditions

```bash
curl -sf -X PUT "$BASE/api/v1/webui/skins/default" \
  -H 'content-type: application/json' -d '{"skinId": "streamline.js"}' | jq .
scripts/sb-dev.sh stop
rm -rf "$SKINS/switch-test-a" "$SKINS/switch-test-b"
```
