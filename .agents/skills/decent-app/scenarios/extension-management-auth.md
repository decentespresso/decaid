# Scenario: extension management authorization in both modes (`extensions:manage`)

Verifies decaid#1191 by hand: the plugin and skin management routes are open by
default (compatibility mode, the pre-decaid#1031 contract, including LAN
clients, skins and plugins), and the decaid#1031 credential checks apply only
after the native **Settings → Security → "Require authorization for extension
management"** switch is turned **ON**. It also reproduces #1187 (DYE2's
tokenless `POST /api/v1/plugins/visualizer.reaplugin/settings`), covers the
Streamline-style enable/disable/settings/approve calls, manual update checks
with scheduling off, the localhost and LAN-bound transports, the separate
account-proxy scopes, and the native-only tamper surfaces.

The switch is a native Flutter action. There is no REST, import, sync,
command-line or plugin way to change it (section 5 proves that), so this
scenario **never flips it remotely**: the operator clicks it in the app window.
Sections 2 onward need that window.

**Never connects real hardware.** `scripts/sb-dev.sh` injects
`--dart-define=simulate=1` by default, which adds `MockDe1` and the other
simulated devices. Do not pass `--real`. Physical-machine checks are out of
scope for this scenario.

## Preconditions

- macOS or Linux desktop session with the Decaid window visible; the switch is
  in **Settings → Security**.
- No installed plugins named `ext-auth-manager` or `ext-auth-plain`. Nothing
  else holds port 8080. Requires jq and openssl.
- Simulated devices only (the default), no linked Decent account required.

```bash
TOKEN="$(openssl rand -hex 32)"
scripts/sb-dev.sh start --platform macos --connect-machine MockDe1 \
  --app-arg "--extensions-token=$TOKEN"
BASE=http://localhost:8080
AUTH="Authorization: Bearer $TOKEN"
code() { curl -s -o /dev/null -w '%{http_code}\n' "$@"; }
LAN_IP=$( (ipconfig getifaddr en0 || ipconfig getifaddr en1) 2>/dev/null \
  || hostname -I | awk '{print $1}'; )
```

The token must be at least 32 characters; a shorter one is ignored and logged.
Check that it was accepted:

```bash
scripts/sb-dev.sh logs -n 400 | grep -c 'extensions-token ignored'   # 0
```

In the app window, open **Settings → Security**. A fresh install and an upgrade
both start in **Compatibility mode (OFF)**, with the "Anyone can manage
extensions" warning card and the upgrade notice. Confirm that before continuing:
the shell steps in section 1 fail otherwise.

## Fixtures

Two plugins share one script. Each exposes a `probe` endpoint that tries one
management action twice, once through `host.localApi` and once through `fetch`
to the local API, and reports both outcomes along with whether the request it
received carried an `Authorization` header.
`?target=<id>&action=<enable|disable>` names the action.

```bash
mkdir -p /tmp/ext-mgmt
cat > /tmp/ext-mgmt/plugin.js <<'JS'
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
  jq -n --arg id "$1" --argjson permissions "$2" --rawfile plugin /tmp/ext-mgmt/plugin.js '{
    manifest: {id: $id, name: $id, author: "decent-app scenarios", description: "",
      version: "1.0.0", apiVersion: 1, permissions: $permissions,
      settings: {label: {type: "string", label: "Label", description: "", default: ""}},
      api: [{id: "probe", type: "http", data: {}}]},
    plugin: ($plugin | gsub("PLUGIN_ID"; $id))}'
}
source_json ext-auth-manager '["api","manage.extensions"]' > /tmp/ext-mgmt/manager.json
source_json ext-auth-plain '["api"]' > /tmp/ext-mgmt/plain.json
put_plain() {
  code -X PUT "$BASE/api/v1/plugins/ext-auth-plain/source" "$@" \
    -H 'content-type: application/json' --data-binary @/tmp/ext-mgmt/plain.json
}
```

Also record the state this scenario changes, so the postconditions can restore
it: the skin/log/automatic-update settings it touches, the visualizer
`Username` it overwrites, and the switch position. The visualizer `Password` is
secure storage and cannot be read back, so run this on a development device
whose Visualizer credentials are disposable; a real credential can only be
cleared here, not restored.

## 1. Compatibility mode (OFF, the default): the pre-#1031 contract

No credential, including from a client that still sends a stale or unknown one:

```bash
put_plain                                      # 200
put_plain -H 'Authorization: Bearer wrong'     # 200, the header is ignored
put_plain -H 'Authorization: BearerBasic x'    # 200, even a malformed header
code -X POST "$BASE/api/v1/plugins/ext-auth-plain/enable"      # 200
code -X POST "$BASE/api/v1/plugins/ext-auth-plain/disable"     # 200
code -X POST "$BASE/api/v1/plugins/ext-auth-plain/enable"      # 200
```

A tokenless caller reaches the real handler, not just a 200. Streamline's
workflow (enable, disable, settings, approve) works the same way, and business
validation still applies once the handler runs:

```bash
code -X POST "$BASE/api/v1/plugins/ext-auth-plain/settings" \
  -H 'content-type: application/json' -d '{"label":"streamline"}'   # 200
code -X POST "$BASE/api/v1/plugins/ext-auth-plain/settings" \
  -H 'content-type: application/json' -d '{"notInTheManifest":"x"}' # 400, not a credential error
code -X POST "$BASE/api/v1/plugins/ext-auth-manager/source" \
  -H 'content-type: application/json' --data-binary @/tmp/ext-mgmt/manager.json   # 200
code -X POST "$BASE/api/v1/plugins/ext-auth-manager/update/approve"  # 409: nothing pending, no credential error
```

The denied-approval case is the point: in protected mode the same call is 401
before the handler runs, here it reaches the handler and answers the business
error.

### #1187: DYE2 saves Visualizer settings without a token

DYE2's `saveVisualizerSettings()` posts to the bundled plugin's settings route
with no bearer:

```bash
code -X POST "$BASE/api/v1/plugins/visualizer.reaplugin/settings" \
  -H 'content-type: application/json' -d '{"Username":"scenario-user"}'   # 200
code -X POST "$BASE/api/v1/plugins/visualizer.reaplugin/settings" \
  -H 'content-type: application/json' -d '{"Password":"scenario-secret"}' # 200
curl -sf "$BASE/api/v1/plugins/visualizer.reaplugin/settings" | jq -c '{Username, Password}'
# {"Username":"scenario-user","Password":{"isSet":true}}
curl -sf "$BASE/api/v1/plugins/visualizer.reaplugin/settings" | grep -c scenario-secret  # 0
```

The secure value is stored and reported as `{"isSet":true}`, never echoed.

### Settings body gate and manual update checks while OFF

```bash
ORIG=$(curl -sf "$BASE/api/v1/settings" | jq -c '{defaultSkinId, automaticUpdateCheck, logLevel}')
VIS_ORIG=$(curl -sf "$BASE/api/v1/plugins/visualizer.reaplugin/settings" | jq -c '{Username}')
CURRENT=$(jq -r .defaultSkinId <<<"$ORIG")
AUTO=$(jq -r .automaticUpdateCheck <<<"$ORIG")
LOG_LEVEL=$(jq -r .logLevel <<<"$ORIG")
OTHER_LEVEL=$([ "$LOG_LEVEL" = FINE ] && echo INFO || echo FINE)
settings() { code -X POST "$BASE/api/v1/settings" -H 'content-type: application/json' "$@"; }
settings -d "{\"logLevel\": \"$OTHER_LEVEL\"}"                    # 200, ordinary key
OTHER_SKIN=$(curl -sf "$BASE/api/v1/webui/skins" | jq -r --arg c "$CURRENT" \
  '[.[] | select(.id != $c) | .id][0] // empty')
if [ -n "$OTHER_SKIN" ]; then
  settings -d "{\"defaultSkinId\": \"$OTHER_SKIN\"}"               # 200, no token
  settings -d "{\"defaultSkinId\": \"$CURRENT\"}"                  # 200, back
fi
settings -d "{\"logLevel\": \"$LOG_LEVEL\"}"                       # 200, restored
```

`webUiPath` is in the same group: open while OFF and 401 while ON (section 3).
This scenario does not point the skin server at a temporary folder, so it only
evers shows the refused side of that key.

Manual update checks answer with automatic scheduling off, and no credential:

```bash
settings -d '{"automaticUpdateCheck": false}'                            # 200
code -X POST "$BASE/api/v1/plugins/update"                               # 200
code -X POST "$BASE/api/v1/webui/skins/update"                           # 200
curl -sf -X POST "$BASE/api/v1/plugins/update" | jq -r .message
# Plugin update check complete
```

### Transports

The production listener binds `0.0.0.0`, i.e. IPv4 on every interface, so the
same-host LAN address is reachable while `[::1]` is not served by the app at all
(IPv6 `::1` is covered by the test suite's second listener; see
`test/webserver/extension_management_pipeline_test.dart`).

```bash
echo "$LAN_IP"                                                           # e.g. 192.168.12.100
code -X POST "http://$LAN_IP:8080/api/v1/plugins/ext-auth-plain/disable" # 200
code -X POST "http://$LAN_IP:8080/api/v1/plugins/ext-auth-plain/enable"  # 200
```

**Honesty note:** this is a *same-host LAN-bound* call (the client source is this
machine's own LAN address), not an independent second device. It proves the
policy is not loopback-conditional; it does not prove behaviour against another
machine.

### Account-proxy scopes stay separate

The account proxy has its own middleware and is unaffected by this setting:

```bash
code -X GET "$BASE/api/v1/account/proxy/support/api/beans"                    # 401
code -X GET "$BASE/api/v1/account/proxy/support/api/beans" -H "$AUTH"         # 403, extensions:manage is not account:proxy
curl -s -X GET "$BASE/api/v1/account/proxy/support/api/beans" -H "$AUTH" | jq -c .
# {"error":"Token is not scoped for account:proxy"}
```

A token with the `extensions:manage` scope on a management route works (section
3 repeats it with the switch on):

```bash
code -X POST "$BASE/api/v1/plugins/ext-auth-plain/disable" -H "$AUTH"    # 200
code -X POST "$BASE/api/v1/plugins/ext-auth-plain/enable" -H "$AUTH"     # 200
```

## 2. Turn the switch ON in the app

In the Decaid window: **Settings → Security → "Require authorization for
extension management"**, turn it on. The card changes to **Protected mode (ON)**
with the "What protected mode covers" text, and the OFF warning and upgrade
notice disappear. Nothing else is required: the value is persisted, and the next
request reads it. Do not look for a REST or CLI way to do this; there is none by
design, and section 5 shows those attempts cannot change it.

## 3. Protected mode (ON): the #1031 contract, with no exceptions

Every management call now needs the credential:

```bash
put_plain                                                       # 401
put_plain -H 'Authorization: Bearer wrong'                      # 401 Invalid token
put_plain -H "$AUTH"                                            # 200
code -X POST "$BASE/api/v1/plugins/ext-auth-plain/enable"       # 401
code -X POST "$BASE/api/v1/plugins/ext-auth-plain/enable" -H "$AUTH"        # 200
code -X POST "$BASE/api/v1/plugins/ext-auth-plain/update/approve"           # 401, no handler work
code -X POST "$BASE/api/v1/plugins/ext-auth-plain/update/approve" -H "$AUTH" # 409
code -X POST "$BASE/api/v1/plugins/ext-auth-plain/settings" \
  -H 'content-type: application/json' -d '{"label":"streamline"}'          # 401
code -X POST "$BASE/api/v1/plugins/ext-auth-plain/settings" -H "$AUTH" \
  -H 'content-type: application/json' -d '{"label":"streamline"}'          # 200
```

Bodies and the challenge header:

```bash
curl -s -X POST "$BASE/api/v1/plugins/ext-auth-plain/enable" | jq -c .
# {"error":"Missing or malformed bearer token"}
curl -s -X POST "$BASE/api/v1/plugins/ext-auth-plain/enable" -H 'Authorization: Bearer wrong' | jq -c .
# {"error":"Invalid token"}
curl -s -D - -o /dev/null -X POST "$BASE/api/v1/plugins/ext-auth-plain/enable" | grep -i '^www-authenticate'
# www-authenticate: Bearer
```

A forged forwarding header changes nothing, because the decision never uses one:

```bash
code -X POST "$BASE/api/v1/plugins/ext-auth-plain/enable" \
  -H 'Host: localhost' -H 'X-Forwarded-For: 127.0.0.1' -H 'X-Real-IP: 127.0.0.1' \
  -H 'X-Forwarded-Host: localhost' -H 'Origin: http://localhost:3000'      # 401
code -X POST "http://$LAN_IP:8080/api/v1/plugins/ext-auth-plain/enable"     # 401
```

The two update routes are ordinary protected routes now: no loopback exception,
no `automaticUpdateCheck` dependency, no 30-second throttle. Section 1 showed
them working tokenless with scheduling off; here, with scheduling still off:

```bash
code -X POST "$BASE/api/v1/plugins/update"                       # 401
code -X POST "$BASE/api/v1/webui/skins/update"                    # 401
code -X POST "$BASE/api/v1/plugins/update" -H "$AUTH"             # 200
code -X POST "$BASE/api/v1/webui/skins/update" -H "$AUTH"         # 200
code -X POST "$BASE/api/v1/plugins/update"                        # 401 again immediately: no throttle window to wait out
```

The settings body gate and import/pull-sync gates apply too:

```bash
settings -d "{\"logLevel\": \"$OTHER_LEVEL\"}"                            # 200, ordinary keys need nothing
settings -d "{\"defaultSkinId\": \"$CURRENT\"}"                           # 200, value already in effect
settings -d '{"webUiPath": "/tmp/ext-mgmt"}'                              # 401, no key applied
settings -d '{"automaticUpdateCheck": true}'                              # 401, no key applied
settings -H "$AUTH" -d '{"automaticUpdateCheck": false}'                  # 200
curl -sf "$BASE/api/v1/settings" | jq -r .logLevel                        # $LOG_LEVEL, unchanged
```

Import and pull-sync skip the two protected settings with a warning while ON;
while OFF (section 1) they apply them without a token. With at least two skins
installed, a different default skin is gated the same way:

```bash
if [ -n "$OTHER_SKIN" ]; then
  settings -d "{\"defaultSkinId\": \"$OTHER_SKIN\"}"                  # 401, no key applied
  settings -H "$AUTH" -d "{\"defaultSkinId\": \"$OTHER_SKIN\"}"      # 200
  settings -H "$AUTH" -d "{\"defaultSkinId\": \"$CURRENT\"}"         # 200, back
fi
```

An import archive or a `pull`/`two_way` sync carrying
`{"defaultSkinId": "<other>", "automaticUpdateCheck": true}` is imported with a
per-key warning in the `settings` section result and changes neither value;
`test/webserver/extension_management_settings_import_test.dart` pins both keys
in both modes over a real archive, which is the reproducible form of this check.

### #1187 in protected mode

```bash
code -X POST "$BASE/api/v1/plugins/visualizer.reaplugin/settings" \
  -H 'content-type: application/json' -d '{"Password":"scenario-secret-2"}'  # 401
curl -s -X POST "$BASE/api/v1/plugins/visualizer.reaplugin/settings" \
  -H 'content-type: application/json' -d '{"Password":"scenario-secret-2"}' | grep -c scenario-secret-2  # 0
curl -sf "$BASE/api/v1/plugins/visualizer.reaplugin/settings" | jq -c .Password
# {"isSet":true}   (the value stored in section 1, unchanged by the refused request)
code -X POST "$BASE/api/v1/plugins/visualizer.reaplugin/settings" -H "$AUTH" \
  -H 'content-type: application/json' -d '{"Username":"scenario-user"}'      # 200
```

## 4. A live flip applies to the next request

With the app open on the Security page, turn the switch **OFF**, then:

```bash
code -X POST "$BASE/api/v1/plugins/ext-auth-plain/disable"       # 200, no app restart
```

Turn it **ON** again:

```bash
code -X POST "$BASE/api/v1/plugins/ext-auth-plain/enable"        # 401, again without a restart
code -X POST "$BASE/api/v1/plugins/ext-auth-plain/enable" -H "$AUTH"   # 200
```

That round trip is the live-toggle check: the policy is read per request. The
native screen writes the persisted value first and publishes it after, so the
mode line in the UI and the shell answer agree.

## 5. The switch cannot be changed over REST, import, sync or a plugin

While the switch is **ON**, try to turn it off through every writable surface.
Every attempt leaves the policy untouched; the ordinary keys in the same body
still apply.

```bash
settings -d "{\"requireExtensionManagementAuthorization\": false, \"logLevel\": \"$OTHER_LEVEL\"}"
# 200, unknown key ignored
curl -sf "$BASE/api/v1/settings" | jq -r .logLevel                       # $OTHER_LEVEL: the ordinary key applied
code -X POST "$BASE/api/v1/plugins/ext-auth-plain/enable"                # 401: still protected
curl -sf "$BASE/api/v1/settings" | jq -r 'has("requireExtensionManagementAuthorization")'
# false
```

The same attempt through `host.localApi` is refused before dispatch, because the
plugin bridge's settings allowlist is only `defaultSkinId` and
`automaticUpdateCheck`; the plugin tests cover it
(`test/plugins/plugin_local_api_bridge_test.dart`).

Export and a pushed sync do not carry the key at all:

```bash
curl -sf "$BASE/api/v1/data/export" -o /tmp/ext-mgmt/export.zip
unzip -p /tmp/ext-mgmt/export.zip settings.json | grep -c requireExtensionManagementAuthorization
# 0
```

A crafted `settings.json` with the key inside a backup archive, and the same in
a `pull` or `two_way` sync, is ignored per key; the policy stays ON and the rest
of the settings still import. Plugins cannot reach it either: the plugin
settings API only stores keys declared in that plugin's own manifest, and a
plugin endpoint that calls the REST settings route without a token is refused
while ON (401) and reaches an unknown key while OFF, which is still ignored.

If the native flip is attempted while storage is failing, the policy stays
protected (fail closed). `test/settings/extension_security_setting_test.dart`
covers that path; it cannot be provoked from a shell.

## 6. Persistence across a restart

Stop and start the app with the same flags. The switch is still ON:

```bash
scripts/sb-dev.sh restart
code -X POST "$BASE/api/v1/plugins/ext-auth-plain/enable"        # 401
curl -sf "$BASE/api/v1/plugins/ext-auth-plain/enable" -X POST -H "$AUTH" >/dev/null && echo manager-ok
# manager-ok
```

`automaticUpdateCheck`, the default skin and the visualizer settings written in
section 1 survive as any other setting does.

## Postconditions

Restore the switch to the position recorded in the preconditions (an upgrade
from 0.9.2 starts OFF, so that is the usual answer), then clean up:

```bash
settings -H "$AUTH" -d "{\"automaticUpdateCheck\": $AUTO}"   # the recorded value
settings -H "$AUTH" -d "{\"logLevel\": \"$LOG_LEVEL\"}"       # the recorded value
[ "$(curl -sf "$BASE/api/v1/settings" | jq -c '{defaultSkinId, automaticUpdateCheck, logLevel}')" = "$ORIG" ] \
  && echo restored                                                       # restored
curl -sf -X POST "$BASE/api/v1/plugins/visualizer.reaplugin/settings" -H "$AUTH" \
  -H 'content-type: application/json' \
  -d "$(jq -c '{Username} + {Password: null}' <<<"$VIS_ORIG")" >/dev/null   # restore Username, clear the test secret
for p in manager plain; do
  curl -sf -X DELETE "$BASE/api/v1/plugins/ext-auth-$p" -H "$AUTH" >/dev/null
done
curl -sf "$BASE/api/v1/plugins" | jq -c '[.[] | select(.id|startswith("ext-auth"))]'
# []
rm -rf /tmp/ext-mgmt
scripts/sb-dev.sh stop
```

Confirm in the app that **Settings → Security** shows the mode you left it in,
and that no fixture plugin remains in the Plugins screen. The
`--extensions-token` value ends with the process and is not persisted; the
switch position is persisted and is the only thing this scenario changes that
outlives the run.
