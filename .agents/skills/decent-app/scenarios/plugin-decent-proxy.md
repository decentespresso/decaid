# Scenario: Plugin Decent-account proxy bridge (`host.decentProxy`)

Verifies the plugin path of the account proxy (#298): a plugin that declares the
`proxy.decent_api` manifest permission can reach `DecentProxyService` via the Dart
bridge, and a plugin that does **not** declare it is rejected before dispatch (and
the attempt is logged). Credentials never appear in plugin-visible data.

Because plugins can only be driven from the JS runtime (the install-from-URL REST
route is a stub), this scenario **side-loads two tiny fixture plugins** that each
expose an HTTP endpoint which calls `host.decentProxy(...)` and returns the outcome
— making the gate curl-observable.

The discriminator is network-independent: in simulate mode no Decent account is
linked, so a *granted* plugin reaches the service and gets
`DecentAccountNotLinkedException` (gate **passed**), while a *denied* plugin gets
`Plugin permission required: proxy.decent_api` (gate **rejected**).

## Preconditions

Fixture plugins live under `AppDirectories.plugins`, which is scanned at boot.
Resolve the current path from the app instead of assuming an OS-specific location:

```bash
PLUGINS_DIR="$(
  flutter run -d macos --dart-entrypoint-args=--print-storage-paths \
    | sed -n 's/^plugins: //p'
)"
[[ -n "$PLUGINS_DIR" ]] || { echo "Could not resolve plugins path" >&2; exit 1; }
mkdir -p "$PLUGINS_DIR/proxy-smoke-granted" "$PLUGINS_DIR/proxy-smoke-denied"
```

Write the **granted** fixture (declares `proxy.decent_api`):

```bash
cat > "$PLUGINS_DIR/proxy-smoke-granted/manifest.json" <<'JSON'
{
  "id": "proxy-smoke-granted",
  "name": "Proxy Smoke (granted)",
  "author": "decent-app scenarios",
  "description": "Calls host.decentProxy with proxy.decent_api declared.",
  "version": "1.0.0",
  "apiVersion": 1,
  "permissions": ["log", "proxy.decent_api"],
  "settings": {},
  "api": [ { "id": "probe", "type": "http", "data": {} } ]
}
JSON

cat > "$PLUGINS_DIR/proxy-smoke-granted/plugin.js" <<'JS'
function createPlugin(host) {
  "use strict";
  return {
    id: "proxy-smoke-granted",
    onLoad: function () { host.log("proxy-smoke-granted loaded"); },
    onUnload: function () {},
    onEvent: function () {},
    __httpRequestHandler: function (request) {
      if (request.endpoint === "probe") {
        return host.decentProxy("support/api/sn", {})
          .then(function (res) {
            return { status: 200, headers: { "Content-Type": "application/json" },
              body: JSON.stringify({ gate: "passed", upstreamStatus: res.status }) };
          })
          .catch(function (err) {
            var msg = (err && err.message) ? err.message : String(err);
            var denied = msg.toLowerCase().indexOf("permission") !== -1;
            return { status: 200, headers: { "Content-Type": "application/json" },
              body: JSON.stringify({ gate: denied ? "denied" : "passed", error: msg }) };
          });
      }
      return { status: 404, headers: {}, body: "Not found" };
    }
  };
}
JS
```

Write the **denied** fixture — identical except the id and the omitted permission:

```bash
sed 's/proxy-smoke-granted/proxy-smoke-denied/g' \
  "$PLUGINS_DIR/proxy-smoke-granted/plugin.js" > "$PLUGINS_DIR/proxy-smoke-denied/plugin.js"

cat > "$PLUGINS_DIR/proxy-smoke-denied/manifest.json" <<'JSON'
{
  "id": "proxy-smoke-denied",
  "name": "Proxy Smoke (denied)",
  "author": "decent-app scenarios",
  "description": "Calls host.decentProxy WITHOUT proxy.decent_api declared.",
  "version": "1.0.0",
  "apiVersion": 1,
  "permissions": ["log"],
  "settings": {},
  "api": [ { "id": "probe", "type": "http", "data": {} } ]
}
JSON
```

Start (the boot scan picks up the fixtures — drop the files **before** start):

```bash
scripts/sb-dev.sh start --platform macos --connect-machine MockDe1
```

## Steps

```bash
# Both fixtures are scanned but not yet loaded
curl -s http://localhost:8080/api/v1/plugins \
  | jq -c '.[] | select(.id|startswith("proxy-smoke")) | {id,loaded}'

# Enable (loads them into the JS runtime)
curl -sf -X POST http://localhost:8080/api/v1/plugins/proxy-smoke-granted/enable >/dev/null
curl -sf -X POST http://localhost:8080/api/v1/plugins/proxy-smoke-denied/enable  >/dev/null

# Probe each plugin's HTTP endpoint — the handler calls host.decentProxy()
granted=$(curl -s http://localhost:8080/api/v1/plugins/proxy-smoke-granted/probe)
denied=$(curl -s  http://localhost:8080/api/v1/plugins/proxy-smoke-denied/probe)
echo "granted: $granted"
echo "denied:  $denied"
```

Expected:

```text
granted: {"gate":"passed","error":"DecentAccountNotLinkedException: no account linked"}
denied:  {"gate":"denied","error":"Bad state: Plugin permission required: proxy.decent_api"}
```

One-shot assertion:

```bash
echo "$granted" | jq -e '.gate=="passed"' >/dev/null || { echo FAIL granted; exit 1; }
echo "$denied"  | jq -e '.gate=="denied"' >/dev/null || { echo FAIL denied;  exit 1; }
echo OK
```

The rejection is also logged (the `attempt is logged` acceptance criterion):

```bash
scripts/sb-dev.sh logs -n 200 | grep "attempted Decent proxy access without permission"
# -> WARNING PluginManager - Plugin proxy-smoke-denied attempted Decent proxy access without permission
```

No credentials appear in any plugin-visible response (only `gate` / `error` / `upstreamStatus`).

## Postconditions

```bash
scripts/sb-dev.sh stop
rm -rf "$PLUGINS_DIR/proxy-smoke-granted" "$PLUGINS_DIR/proxy-smoke-denied"
```
