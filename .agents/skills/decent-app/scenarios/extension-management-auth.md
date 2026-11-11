# Scenario: plugin and skin management authorization (`extensions:manage`)

Verifies the gate from decaid#1031 by hand: the routes that install, replace,
configure, enable, disable or remove plugins and skins (and change the default
skin or the skin server) need `Authorization: Bearer <token>` with the
`extensions:manage` scope; reading routes stay open; `POST /api/v1/settings`
needs the token only when it changes the skin; a plugin holding
`manage.extensions` reaches the routes through `host.localApi`, and a plugin
without it fails both through `host.localApi` and through plain `fetch`.

The full route table and the 403 case (a valid token of another scope) are
covered by `test/webserver/extension_management_auth_test.dart`; this scenario
checks the running app end to end.

## Preconditions

No installed plugins named `ext-auth-manager` or `ext-auth-plain`. Nothing else
holds port 8080. Requires jq and openssl.

```bash
TOKEN="$(openssl rand -hex 32)"
scripts/sb-dev.sh start --platform macos --connect-machine MockDe1 \
  --app-arg "--extensions-token=$TOKEN"
BASE=http://localhost:8080
AUTH="Authorization: Bearer $TOKEN"
code() { curl -s -o /dev/null -w '%{http_code}\n' "$@"; }
```

The token must be at least 32 characters; a shorter one is ignored and logged.
Check that it was accepted:

```bash
scripts/sb-dev.sh logs -n 400 | grep -c 'extensions-token ignored'   # 0
```

## Fixtures

Two plugins share one script. Each exposes a `probe` endpoint that tries one
management action twice, once through `host.localApi` and once through `fetch`
to the local API, and reports both outcomes along with whether the request it
received carried an `Authorization` header.
`?target=<id>&action=<enable|disable>` names the action.

```bash
mkdir -p /tmp/ext-auth
cat > /tmp/ext-auth/plugin.js <<'JS'
function createPlugin(host) {
  "use strict";
  function outcome(promise) {
    return promise.then(
      function (res) { return { status: res.status }; },
      function (err) {
        var name = err && err.name ? err.name + ": " : "";
        return { error: name + (err && err.message ? err.message : String(err)) };
      }
    );
  }
  return {
    id: "PLUGIN_ID",
    onLoad: function () {},
    onUnload: function () {},
    onEvent: function () {},
    __httpRequestHandler: function (request) {
      var path = "/api/v1/plugins/" + request.query.target + "/" + request.query.action;
      var sawAuthorization = Object.keys(request.headers || {}).some(function (k) {
        return k.toLowerCase() === "authorization";
      });
      return Promise.all([
        outcome(host.localApi(path, { method: "POST" })),
        outcome(fetch("http://localhost:8080" + path, { method: "POST" }))
      ]).then(function (results) {
        return { status: 200, headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ localApi: results[0], fetch: results[1],
            sawAuthorization: sawAuthorization }) };
      });
    }
  };
}
JS
source_json() {
  jq -n --arg id "$1" --argjson permissions "$2" --rawfile plugin /tmp/ext-auth/plugin.js '{
    manifest: {id: $id, name: $id, author: "decent-app scenarios", description: "",
      version: "1.0.0", apiVersion: 1, permissions: $permissions, settings: {},
      api: [{id: "probe", type: "http", data: {}}]},
    plugin: ($plugin | gsub("PLUGIN_ID"; $id))}'
}
source_json ext-auth-manager '["api","manage.extensions"]' > /tmp/ext-auth/manager.json
source_json ext-auth-plain '["api"]' > /tmp/ext-auth/plain.json
```

## 1. A gated route needs the right bearer

Installing through the source route is gated. Without a bearer, with a wrong one
and with the right one:

```bash
put_plain() {
  code -X PUT "$BASE/api/v1/plugins/ext-auth-plain/source" "$@" \
    -H 'content-type: application/json' --data-binary @/tmp/ext-auth/plain.json
}
put_plain                                      # 401
put_plain -H 'Authorization: Bearer wrong'     # 401
put_plain -H "$AUTH"                           # 200
```

The response bodies and the challenge header:

```bash
curl -s -X POST "$BASE/api/v1/plugins/ext-auth-plain/enable" | jq -c .
# {"error":"Missing or malformed bearer token"}
curl -s -X POST "$BASE/api/v1/plugins/ext-auth-plain/enable" \
  -H 'Authorization: Bearer wrong' | jq -c .
# {"error":"Invalid token"}
curl -s -D - -o /dev/null -X POST "$BASE/api/v1/plugins/ext-auth-plain/enable" \
  | grep -i '^www-authenticate'
# www-authenticate: Bearer
```

Install and load both fixtures:

```bash
curl -sf -X PUT "$BASE/api/v1/plugins/ext-auth-manager/source" -H "$AUTH" \
  -H 'content-type: application/json' --data-binary @/tmp/ext-auth/manager.json >/dev/null
for p in manager plain; do
  curl -sf -X POST "$BASE/api/v1/plugins/ext-auth-$p/enable" -H "$AUTH" >/dev/null
done
curl -sf "$BASE/api/v1/plugins" | jq -c '.[] | select(.id|startswith("ext-auth")) | {id,loaded}'
# {"id":"ext-auth-manager","loaded":true}
# {"id":"ext-auth-plain","loaded":true}
```

A REST install by a token holder needs no native approval. Installing a plugin
that requests `manage.extensions` from the native screens asks "Allow <name> to
manage plugins and skins?" first.

## 2. Reading routes stay open

```bash
code "$BASE/api/v1/plugins"                                # 200
code "$BASE/api/v1/plugins/ext-auth-plain/settings"        # 200
code "$BASE/api/v1/webui/skins"                            # 200
code "$BASE/api/v1/webui/server/status"                    # 200
```

## 3. Settings: only skin selection needs the token

```bash
CURRENT=$(curl -sf "$BASE/api/v1/webui/skins/default" | jq -r .id)
code -X POST "$BASE/api/v1/settings" -H 'content-type: application/json' \
  -d "{\"defaultSkinId\": \"$CURRENT\"}"                                   # 401
code -X POST "$BASE/api/v1/settings" -H "$AUTH" -H 'content-type: application/json' \
  -d "{\"defaultSkinId\": \"$CURRENT\"}"                                   # 200
LOG_LEVEL=$(curl -sf "$BASE/api/v1/settings" | jq -r .logLevel)
code -X POST "$BASE/api/v1/settings" -H 'content-type: application/json' \
  -d "{\"logLevel\": \"$LOG_LEVEL\"}"                                      # 200
```

A refused request applies none of its fields, including other keys sent with
`defaultSkinId`. Re-sending the current values keeps the app as it was.

## 4. `host.localApi` works only with `manage.extensions`

The manager disables and re-enables the plain plugin:

```bash
curl -s "$BASE/api/v1/plugins/ext-auth-manager/probe?target=ext-auth-plain&action=disable" | jq -c .
# {"localApi":{"status":200},"fetch":{"status":401},"sawAuthorization":false}
curl -sf "$BASE/api/v1/plugins" | jq -c '.[] | select(.id=="ext-auth-plain") | .loaded'
# false
curl -s "$BASE/api/v1/plugins/ext-auth-manager/probe?target=ext-auth-plain&action=enable" | jq -c .localApi
# {"status":200}
```

The `fetch` half shows that the manager's authority is not attached to plain
requests, even to `localhost`.

The plain plugin tries the same against the manager and fails both ways:

```bash
curl -s "$BASE/api/v1/plugins/ext-auth-plain/probe?target=ext-auth-manager&action=disable" | jq -c .
# {"localApi":{"error":"PluginPermissionError: Plugin ext-auth-plain requires manifest permission manage.extensions"},"fetch":{"status":401},"sawAuthorization":false}
curl -sf "$BASE/api/v1/plugins" | jq -c '.[] | select(.id=="ext-auth-manager") | .loaded'
# true
```

## 5. The grant ends with the plugin's generation

Disable the manager, enable it again, and probe once more: the unloaded plugin
has no endpoint, and the new generation gets a new grant.

```bash
curl -sf -X POST "$BASE/api/v1/plugins/ext-auth-manager/disable" -H "$AUTH" >/dev/null
code "$BASE/api/v1/plugins/ext-auth-manager/probe?target=ext-auth-plain&action=enable"   # 404
curl -sf -X POST "$BASE/api/v1/plugins/ext-auth-manager/enable" -H "$AUTH" >/dev/null
curl -s "$BASE/api/v1/plugins/ext-auth-manager/probe?target=ext-auth-plain&action=enable" | jq -c .localApi
# {"status":200}
```

A `host.localApi` call in flight across an unload rejects with
`Plugin generation changed`; the full-pipeline tests cover that timing.

## 6. A recognised bearer never reaches plugin code

```bash
curl -s -H "$AUTH" \
  "$BASE/api/v1/plugins/ext-auth-plain/probe?target=ext-auth-manager&action=enable" \
  | jq -c .sawAuthorization
# false
curl -s -H 'Authorization: Bearer plugin-own-credential' \
  "$BASE/api/v1/plugins/ext-auth-plain/probe?target=ext-auth-manager&action=enable" \
  | jq -c .sawAuthorization
# true
```

Decaid strips the token it recognises; any other `Authorization` value reaches
the plugin unchanged, so plugins that check their own credentials keep working.

## Postconditions

```bash
for p in manager plain; do
  curl -sf -X DELETE "$BASE/api/v1/plugins/ext-auth-$p" -H "$AUTH" >/dev/null
done
curl -sf "$BASE/api/v1/plugins" | jq -c '[.[] | select(.id|startswith("ext-auth"))]'
# []
rm -rf /tmp/ext-auth
scripts/sb-dev.sh stop
```

The `--extensions-token` value ends with the process and is not persisted.
