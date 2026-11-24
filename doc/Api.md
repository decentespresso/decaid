# API Reference

Scale REST command failures preserve the existing HTTP 500 response and `error`
message. Plugin Scale failures additionally include `code`; unsupported optional
operations use `unsupported_operation`. Native timer no-op behavior is unchanged.
The four tare/timer 500 responses share the OpenAPI `ScaleCommandError` schema.

Decaid exposes REST and WebSocket APIs on port 8080. Full OpenAPI specs are in [`assets/api/rest_v1.yml`](../assets/api/rest_v1.yml) and [`assets/api/websocket_v1.yml`](../assets/api/websocket_v1.yml). Interactive docs are available at port 4001 when the app is running.

`GET /api/v1/manifest` returns this compact documentation discovery manifest:

```json
{"api":"v1","docs":{"port":4001,"viewer":"/","openapi":"/rest_v1.yml","asyncapi":"/websocket_v1.yml"}}
```

The `viewer`, `openapi`, and `asyncapi` paths use the same host as the API request with the manifest's `docs.port` (4001), not port 8080; the manifest does not guarantee that the separate docs listener is available. For example, reconstruct `http://decaid.local:4001/rest_v1.yml` or `http://decaid.local:4001/websocket_v1.yml` from the manifest. The viewer then sends its own API calls to the host it was served from rather than to the `localhost` default the shipped spec carries, so a browser on another machine addresses the device. An unmatched API route returns JSON with `error: "Route not found"` and a `hint` naming the same-host docs port and the viewer/OpenAPI/AsyncAPI paths.

For skin development, see [`doc/Skins.md`](Skins.md). For plugin development, see [`doc/Plugins.md`](Plugins.md).

GitHub personal access tokens are stored in platform secure storage and are not
part of the REST API or data exports. Android uses a dedicated secure-storage
preferences file excluded from both cloud backup and device transfer; other
application preferences remain eligible for backup. iOS uses a non-synchronizing,
this-device-only keychain item. macOS stores the token in an encrypted file named
`github_pat_secure_storage_v1.dat` in Application Support, using a device- and
purpose-separated key; temporary and final files have mode 0600 from creation.
An absent file means no PAT is configured. A corrupt or unreadable file blocks
GitHub requests rather than falling back to another identity; native Advanced
Settings offers explicit replacement or removal. No macOS keychain entitlement
is required.

External sensor IDs in REST and WebSocket paths are opaque URI path
components. Clients percent-encode them once; the host decodes them once at
the sensor route boundary. This preserves literal reserved characters,
Unicode, plus signs, and percent-bearing IDs. Invalid UTF-8 receives `400` at
the HTTP boundary. Host-assigned UUID resource IDs keep their existing route
contracts.

The #809 work-in-progress manifest schema includes `transport.ble`, Scale
capabilities, and BLE matchers. Public non-BLE Scale registration is implemented;
runtime BLE binding and full API acceptance remain incomplete. See
[the active design](plans/issue-809-design.md). This stage
adds no routes or WebSocket messages.

---

## Admission control

Decaid rejects excess local API work rather than queueing it. `/api/` requests
allow 128 concurrent globally and 32 per client, with fixed one-second accepted
request limits of 1024 globally and 256 per client. Per-client rejection is `429`;
global rejection is `503`. Both include `Retry-After: 1`. `OPTIONS`, static/WebUI,
and `/ws/` requests do not use these API slots.

WebSocket admission is separate: 128 open connections globally, 32 per client,
and one-second upgrade limits of 128 globally and 32 per client. Rejected upgrades
use the same `429`/`503` and `Retry-After: 1` contract. Closing a socket releases its
connection slot.

Endpoints that buffer request bodies enforce byte and read-time limits. Small
control payloads use 64 KiB and 10 seconds, ordinary JSON payloads use 1 MiB and
30 seconds. Oversized bodies return `413`; bodies that miss their read deadline
return `408`. Firmware, workflow, and data-transfer endpoints retain their
documented limits.

---

## Extension management authorization

Routes that install, update, configure, enable, disable or remove plugins and
skins, choose the default skin, or start and stop the skin server are open to
any client that can reach the API, by default. Decaid ships with **Settings →
Security → "Require authorization for extension management" OFF**, which is
compatibility mode: those operations behave as they did before decaid#1031,
including requests from other devices on the LAN (Home Assistant, MCP
clients), skins such as Streamline, and plugins calling the API with `fetch` or
`host.transport`. A stale, revoked or wrong-scope `Authorization` header makes
no difference there either.

Turning the setting ON puts the decaid#1031 scoped-token policy in front of the
same operations: each then needs `Authorization: Bearer <token>` with the scope
`extensions:manage`, or an approved `manage.extensions` plugin calling
`host.localApi` in process. There is no loopback, update-check or
`automaticUpdateCheck` exception in either mode.

The rest of the API is unchanged (general API authentication is tracked in
#1135); this setting covers extension management only. Both modes run the same
handlers with the same validation, manifest checks, pending-update rules,
rollback and secure-value handling, so the setting changes authorization only.

The OpenAPI spec lists both security alternatives on each of these operations
(`{}` and `extensionsManage`), so a generated client treats the token as
optional, and each operation describes the requirement as conditional on
protection being ON. The WebUI & Skins and Plugins route tables below mark them
in a Token column.

| Method | Route |
|---|---|
| POST | `/api/v1/plugins/install` |
| POST | `/api/v1/plugins/install/github-release` |
| POST | `/api/v1/plugins/install/github-branch` |
| POST | `/api/v1/plugins/update` |
| POST | `/api/v1/plugins/:id/settings` |
| PUT | `/api/v1/plugins/:id/source` |
| POST | `/api/v1/plugins/:id/enable` |
| POST | `/api/v1/plugins/:id/disable` |
| POST | `/api/v1/plugins/:id/update/approve` |
| DELETE | `/api/v1/plugins/:id` |
| PUT | `/api/v1/webui/skins/default` |
| POST | `/api/v1/webui/skins/install/github-release` |
| POST | `/api/v1/webui/skins/install/github-branch` |
| POST | `/api/v1/webui/skins/install/url` |
| POST | `/api/v1/webui/skins/update` |
| DELETE | `/api/v1/webui/skins/:id` |
| POST | `/api/v1/webui/server/start` |
| POST | `/api/v1/webui/server/stop` |

Two more routes are gated by what the body contains, and only while protection
is ON:

- `POST /api/v1/settings` needs the token when the body contains `webUiPath`,
  sets `defaultSkinId` to a skin other than the current default, or sets
  `automaticUpdateCheck` to `true` while it is off (automatic checks install
  plugin and skin updates, like `POST /api/v1/plugins/update` and
  `POST /api/v1/webui/skins/update`). Such a body is refused with 401 or 403
  before any key is applied. In compatibility mode no token is needed for any
  of them, and in both modes values already in effect, turning
  `automaticUpdateCheck` off, and every other key need none.
- `POST /api/v1/data/import` and a pulling `POST /api/v1/data/sync` (`pull`, or
  the pull phase of `two_way`) import everything else without a token, but skip
  a `defaultSkinId` that differs from the current one and an
  `automaticUpdateCheck: true` while automatic updates are off, reporting each
  as a warning in the `settings` section result. Restoring a backup or syncing
  therefore cannot change the default skin or turn on automatic updates while
  protection is ON unless the request is authorized; with protection OFF both
  apply without a token.

Read routes (`GET`), plugin-defined endpoints (`/api/v1/plugins/:id/:endpoint`,
`/ws/v1/plugins/:id/:endpoint`) and `OPTIONS` are not gated in either mode; that
is the credential gate only, and [browser origins](#browser-origins) still
refuses an untrusted preflight for a guarded path.

While protection is ON, a protected route (including a gated settings body)
answers:

| Status | When | Body |
|---|---|---|
| 401 | No `Authorization` header, or not a bearer (also sends `WWW-Authenticate: Bearer`) | `{"error":"Missing or malformed bearer token"}` |
| 401 | Unknown or revoked token | `{"error":"Invalid token"}` |
| 403 | Known token without `extensions:manage` (for example an `account:proxy` token) | `{"error":"Token is not scoped for extensions:manage"}` |

The scope is independent of the account-proxy scopes: an `extensions:manage`
token cannot use `/api/v1/account/proxy/`, and an `account:proxy` token
(including the skin token injected into served skin pages) gets 403 here while
protection is ON. The account proxy keeps its own scopes in both modes.

### Browser origins

A browser page is also checked against its `Origin`, in both modes and
independently of any credential. The check runs ahead of the general CORS
middleware, the account-proxy CORS rule and the authentication middleware, and
refuses with `403` and
`{"error":"Extension management is not allowed from this browser origin"}`
before any handler work, naming no internal configuration and applying nothing.
A valid `extensions:manage` bearer, an approved `manage.extensions` plugin grant
and compatibility mode all make no difference to it.

Which requests it refuses:

- The 18 routes in the table above, on every method and path pair.
- `POST /api/v1/data/import`, refused whole before the archive is read: whether
  an archive carries a gated settings key is only known after parsing it, so
  the conservative answer applies to every import.
- `POST /api/v1/settings`, refused when the body contains a gated key
  (`webUiPath`, a changed `defaultSkinId`, `automaticUpdateCheck` turned on),
  and none of that body's keys are applied. A safe body that reaches the
  handler is unaffected; its preflight is refused before the body is known — see
  [Deliberate limits of the setting](#deliberate-limits-of-the-setting).
- A pulling `POST /api/v1/data/sync`, refused when the pull includes the
  `settings` section (the default), before any network request or write. The
  section list is part of the request body, so a pull or `two_way` sync that
  excludes `settings`, a `push`, and any other section are not refused by this
  check: it is an extension-management boundary, not a general data-import one.

What counts as the device's own origin:

| Trusted | Rejected |
|---|---|
| Scheme `http`, host `localhost`, `127.0.0.1`, `::1`, or a numeric address currently assigned to a local network interface, and a port equal to the live skin page port, the actual API listener port or the built-in API docs viewer port while its listener is bound | `Origin: null`, an empty value, `https` or any other scheme, a hostname such as `decaid.local`, another device's address, `user@host`, a path, query or fragment, a comma or a space in the value |

A loopback origin is trusted only while the request's TCP socket peer is
loopback or is exactly one of the addresses this device currently holds. A
browser page on another machine that opens `http://localhost:<port>` presents a
non-loopback peer, so it is refused in both modes even with a valid
`extensions:manage` bearer; a peer that is missing, unreadable or not an
`HttpConnectionInfo` is refused as well. That keeps an embedded WebView or
another process on the device itself able to use `localhost`, and stops a page
elsewhere from borrowing the name.

The ports and the addresses come from the running services and never from the
request itself: the skin port follows a skin switch, a restart and a dynamically
allocated port, the API port is the one the listener actually bound, the docs
viewer port is the one the docs listener actually bound (and is trusted only
while that bind succeeded), and the address set is enumerated when a comparison
needs it, so a moved or retired address is picked up without a restart or a skin
serve. A port that is not live is not trusted, so `http://localhost:3000` is
refused while the skin server is on another port. The port 3000 entry point only
redirects to the active origin and an inactive skin's alias port only serves a
redirect, so a skin page always runs, and posts, from its live origin. `Host`,
`Referer`, `X-Forwarded-For`, `X-Forwarded-Host`, `X-Real-IP`, `Forwarded` and
DNS resolution are never consulted, so a name that resolves to the device (DNS
rebinding) is not enough.

#### Opening a built-in page through a name

A name is still not authority, but a browser that reached a built-in page through
one would otherwise keep a page it may not use: the page loads, and every
management request it makes is then refused. So the two first-party pages Decaid
serves are canonicalised once, at the page entry, before any handler, plugin or
body work:

| Request | Answer |
|---|---|
| `GET /` or `GET /index.html` on the API docs viewer port | `302` to the same path on the numeric local endpoint |
| `GET /api/v1/plugins/settings.reaplugin/ui` on the API port | `302` to the same path on the numeric local endpoint |

The destination carries only `http`, a numeric local address and the port the
listener bound; a loopback client keeps `127.0.0.1` or `::1`, and a remote client
gets the address the listener bound when that is concrete, otherwise the single
usable current numeric address of the client's own address family. Addresses are
compared as parsed values, so the IPv4, IPv4-mapped and compressed spellings of
one interface count once. Wildcard, multicast and broadcast addresses, plus
link-local or scoped IPv6 addresses, are never a destination. The name decides only whether a
redirect is needed and never where it points. The redirect keeps neither the
incoming query string nor any credentials, and the `Location` ends in an
explicitly empty fragment: a browser inherits the fragment of the address it
entered through whenever the redirect target has no fragment component, and that
fragment is never sent to the server, so the redirect is the only place it can be
cleared. The answer carries `Cache-Control: no-store` and
`Referrer-Policy: no-referrer`. A device address
that is not unique is not resolved by preference: when the device holds more
than one current address of the client's address family, the page entry is
refused with `403` and
`{"error":"This page is only served from the device address"}`, so on a
multi-interface device open the numeric address directly. The same refusal
covers a listener that is not bound, a request without socket provenance and an
absent or malformed `Host` header. A `Host` is malformed unless it is a numeric
address, `localhost`, a bracketed IPv6 literal or dot-separated DNS labels, with
an optional port in `1`-`65535`: `/`, `?`, `#`, `,`, `;`, `@`, whitespace inside
the value, a control character, `[localhost]`, a bracketed IPv4 address, port `0`
or a port above `65535` in the value is refused rather than treated as a name.

Nothing else moves: every other route, the spec files, third-party plugin pages
and every mutation keep their existing behaviour, an `Origin` that is a name stays
refused in both modes even with a valid `extensions:manage` bearer, and a numeric
or `localhost` entry is not redirected at all. The browser finishes on the
numeric origin, which the rules above already trust, so the mutation is admitted
by the existing policy rather than by the redirect.

Requests without an `Origin` header are not affected at all: `curl`, Home
Assistant, MCP clients, native app code, `host.localApi` (in process) and every
other non-browser client keep the behaviour described in the rest of this
section, in both modes.

Preflights follow the same boundary. An `OPTIONS` from an untrusted origin for
one of the guarded methods on a management path answers `403` with no
`Access-Control-Allow-Origin`, `Access-Control-Allow-Credentials`,
`Access-Control-Allow-Methods`, `Access-Control-Allow-Headers`,
`Access-Control-Expose-Headers` or `Access-Control-Max-Age` header, instead of
the general preflight answer, and a preflight whose
`Access-Control-Request-Method` is missing or unusable is refused on a
management path because the method is then unknown. That includes the
body-gated paths: `OPTIONS /api/v1/settings`, `OPTIONS /api/v1/data/import` and
`OPTIONS /api/v1/data/sync` are refused for an untrusted origin without
consulting a body they do not carry, so a browser page on an untrusted origin
cannot send a safe settings write or a `push` sync as an ordinary JSON request,
although the same requests are admitted when they arrive without a preflight. A
preflight for a read-only method on a shared path
(`GET /api/v1/plugins/:id/settings`, `GET /api/v1/webui/skins/default`,
`GET /api/v1/settings`) and a preflight for a plugin-defined endpoint keep the
general preflight answer. The handler-level
refusals of the three body-gated routes carry no `access-control-*` headers
either: withholding an allow-origin header after a mutation is never the
protection.

Origin is not authentication. A client that is not a browser can omit `Origin`
or send any value, so direct LAN access stays exactly as exposed as the rest of
this section describes, and originless LAN access (Home Assistant, MCP) remains
intentional in compatibility mode. The check bounds browser pages and nothing
else; enabling protected mode and restricting the network remain the controls
for a shared or commercial deployment.

### What each caller sees

| Caller | Compatibility mode (OFF, default) | Protected mode (ON) |
|---|---|---|
| Tokenless localhost client | Legacy behaviour, no credential | Needs `extensions:manage` on every protected operation |
| Tokenless LAN client, including Home Assistant and MCP | Legacy behaviour, no credential | Needs `extensions:manage` |
| Skin or DYE2 page using `fetch`, no bearer | Legacy behaviour | 401 on protected operations |
| Plugin with ordinary `api`, using `fetch` or `host.transport` | Legacy behaviour | 401/403 on protected operations |
| Named token with `extensions:manage` | Allowed | Allowed |
| Approved `manage.extensions` plugin via `host.localApi` | Allowed | Allowed |
| Trusted native Flutter controls | Allowed | Allowed |
| Decent account proxy | Existing account scopes | Same account scopes |
| Other REST/WS APIs | Existing behaviour, no new gate | Existing behaviour, not protected by this setting |

The rows assume a request that carries no untrusted browser `Origin`; the
[browser-origin check](#browser-origins) refuses those before any of these
decisions, in both modes.

### Changing the setting

The setting is a native Flutter control, persisted on the device through the
normal settings storage. It is not writable over REST: a `POST
/api/v1/settings` body that names the key is treated like any other unknown key
(ignored, 200), backup import and pull/two-way sync skip it, the exported and
pushed archives do not contain it, and neither the plugin settings API, the
key-value store, `host.localApi` nor the account proxy can write it. `GET
/api/v1/settings` does not expose it.

- **Missing value means OFF.** A new installation and an upgrade from a build
  that never stored the key both run in compatibility mode. The presence of an
  old `extensions:manage` token is not treated as a reason to protect the
  device.
- **A storage read failure means ON.** If the persisted value cannot be read,
  the management policy behaves as protected and logs a warning, rather than
  silently downgrading security because storage failed.
- **The current value is resolved per relevant request, once** (and refreshed
  when the app resumes from the background). Only a request whose outcome can
  depend on the mode reads it: the 18 routes, a gated settings body, an import,
  and a `settings`-bearing pull or `two_way` sync. Everything else — machine
  state, polling, the account proxy, read-only and plugin-defined routes and
  ordinary settings bodies — never reads it. A change applies to the next
  relevant request without an app restart, and the native screen publishes the
  new value only after it is persisted.

### Deliberate limits of the setting

- **Authorization is not confidentiality.** The API listens over plain HTTP on
  port 8080, so a bearer token can be observed on a hostile LAN. HTTPS is
  proposed in #925; #1135 remains the separate, optional full REST/WS
  authentication. Use a trusted network until then.
- **The origin check does not tighten CORS in general.** Apart from the
  refusals above, responses keep the pre-existing permissive echo of the request
  `Origin` in both modes, `OPTIONS` keeps its pre-existing preflight answer on
  unrelated and read-only paths, and the account proxy keeps its own restrictive
  rule on top. So a browser page on any origin that can reach the device can
  still read other API responses. The origin check is a browser boundary for
  extension management, not authentication, and the setting still changes who is
  authorized rather than what a browser may read.
- **A preflight for a body-gated path is refused before its body exists.** A
  preflight carries no body, so an untrusted `Origin` is refused for `OPTIONS
  /api/v1/settings`, `OPTIONS /api/v1/data/import` and `OPTIONS
  /api/v1/data/sync` whatever the eventual body would contain. Import and a
  `settings`-bearing pull are refused on their content anyway, so the only
  stricter outcomes are a safe `POST /api/v1/settings` body and a `push` sync: a
  browser page on an untrusted origin cannot send either as an ordinary JSON
  request, because the browser stops at the refused preflight. A body the
  browser sends without one (a simple content type carrying the same JSON) and
  any request from a non-browser client still reach the handler, are applied as
  usual and keep the CORS echo. This is the conservative answer for a path whose
  relevance depends on a body a preflight does not have.
- **A plugin holding `manage.extensions` is full trust**, in both modes: it can
  install or rewrite plugins, approve permission escalations and change
  extension settings. Token rotation and revocation apply to named tokens
  only, and a plugin's authority is bound to that plugin's current generation.
- **Named tokens are independent of the Decent account.** They work whether or
  not an account is linked or logged in, and in both modes.
- **There is no per-operation confirmation prompt** (that direction is tracked
  in #1164 and is not part of this setting).
- **The bundled settings plugin page is unchanged.** Its management buttons work
  in compatibility mode and, while protection is ON, report that the action
  needs an `extensions:manage` token because the page holds none. It never asks
  for a token.

**Getting a token.** A token is only needed while protection is ON. In the app,
open the Decent Account page, go to "API access tokens", choose Create, name
the token and turn on "Manage plugins and skins". The token is shown once; copy
it then. No linked Decent account is needed. That is the way to provision a
device in service: the token is named, can be revoked without a restart and is
kept in the platform credential store.

For development, headless testing and automation, a token can instead be given
at launch, in the `DECAID_EXTENSIONS_TOKEN` environment variable or with
`--extensions-token <value>` (the flag wins when both are set). The value must
be at least 32 characters with no spaces or commas; any other value is ignored
with a logged error. Generate it, for example with `openssl rand -hex 32`,
rather than choosing it. It lasts for the process lifetime and is not stored. A
command-line argument can be read by other local users in the process list and
ends up in shell history and launch diagnostics, so prefer the environment
variable where the value has to stay private.

```bash
TOKEN='paste-the-token-here'
curl -X POST http://decaid.local:8080/api/v1/plugins/my.plugin/enable \
  -H "Authorization: Bearer $TOKEN"
```

Tokens are named. Decaid logs each authorized or refused request with the
caller id and name (`api:<id> "name"`, or `cli "--extensions-token"` and
`cli "DECAID_EXTENSIONS_TOKEN"` for a launch token), never the token value. A
token Decaid recognises is removed from the request before handlers run, so a
plugin-defined endpoint never receives it.

**Plain HTTP.** The API listens over plain HTTP, so a bearer token is not
confidential on the local network. Use a trusted network until the HTTPS
listener (#925) exists.

**Plugins.** A plugin whose manifest declares `manage.extensions` calls these
routes through `host.localApi(path, options)`, in process, without a token.
`host.localApi` reaches only these routes, the `GET` routes that read plugins,
skins and the skin server, and `POST /api/v1/settings` with a body of only
`defaultSkinId` or `automaticUpdateCheck` (`webUiPath` stays with token
holders). It refuses the rest of the API, so the plugin's own calls are limited
to plugin and skin management, and `api` gives no management authority. This
limits what the plugin calls, not what it can cause: a plugin that can install
plugins and approve permissions can install one that holds `api` or any other
permission, or add `api` to itself, so `manage.extensions` is full trust in the
plugin.
Installing such a plugin from the native screens asks for confirmation, and an
update that adds the permission waits for approval. A plugin holding the
permission can approve pending permission updates, including its own; a plugin
without it cannot grant it to itself. See [`Plugins.md`](Plugins.md).

**Compatibility and the upgrade.** The clients that decaid#1031 broke work
again by default: the bundled `settings.reaplugin` web page, Streamline's
plugin enable, install, update, approve and settings calls and its skin
switching over REST, DYE2's dashboard when it saves Visualizer plugin settings,
and Home Assistant or MCP style integrations on the LAN. Skins and web pages
still get no implicit authority: with protection ON, such a client must send a
user-created token, hand the operation to a plugin that holds
`manage.extensions`, or leave it to the native settings screens.
`window.decentApp.switchSkin(skinId)` inside the embedded WebView is unaffected
in both modes.

Decaid 0.9.2 shipped the decaid#1031 policy always on. 0.9.3 removes that
always-on protection for both new and existing installations and makes it an
opt-in setting, so upgrading is a deliberate security downgrade until the
toggle is turned on. Fleet and café operators should turn the toggle on and
restrict network access to the device; the provisioning guide is issue #1192
and is not published yet.

---

## Conditional GETs (ETag / If-None-Match)

The following list endpoints set a strong `ETag` on every `200 OK` response and honour `If-None-Match` with `304 Not Modified` (empty body) when the client's tag matches:

- `GET /api/v1/beans`
- `GET /api/v1/beans/{beanId}/batches`
- `GET /api/v1/grinders`
- `GET /api/v1/profiles`
- `GET /api/v1/shots` (per query-param combination — filters and pagination are part of the tag)

Usage:

```bash
# First request — note the ETag
curl -is http://localhost:8080/api/v1/beans

# Re-request with If-None-Match — 304 if nothing changed
curl -is -H 'If-None-Match: "abc123…"' http://localhost:8080/api/v1/beans
```

Tags are SHA-256 derived from the encoded response body. Single-resource GETs and mutation routes do **not** emit ETags.

For browser clients on a different origin, `ETag` is exposed via `Access-Control-Expose-Headers`.

---

## REST API

### Machine

| Method | Path | Description | Handler |
|--------|------|-------------|---------|
| GET | `/api/v1/machine/info` | Machine model, firmware, features | `de1handler.dart` |
| GET | `/api/v1/machine/state` | Current machine state + substate. The steam substates `pausedSteam` and `puffing` report as themselves; a stopped refill kit reports `needsWater`/`refillStopped` rather than `needsWater`/`idle` | |
| PUT | `/api/v1/machine/state/{newState}` | Request state change (`idle`, `sleep`, `espresso`, …) | |
| GET | `/api/v1/machine/settings` | DE1 machine settings (temps, flows) | |
| POST | `/api/v1/machine/settings` | Update machine settings (one grouped, serialized device write per request). API fan writes are retained locally per machine across app restarts and reapplied after reconnect; the default is 55 (DE1 clamps it to 50) until a fan value is written. The bounded map keeps 32 machines and evicts the oldest-updated entry. Each connection captures its raw handshake serial, falling back to device ID; account-resolved effective serials are excluded. Raw identity changes across connections do not migrate buckets, while account-only effective identity changes within a connection leave the bucket fixed. If neither is available, defaults are used with no retained entry. | |
| POST | `/api/v1/machine/shotSettings` | Update shot settings (steam temp, hot water, target volume, group temp) | |
| GET | `/api/v1/machine/settings/advanced` | Advanced heater/phase settings | |
| POST | `/api/v1/machine/settings/advanced` | Update advanced settings (heater phase flows/timeouts, idle temp, `heaterVoltage`, `refillKitSetting`). `refillKitSetting` is an override (`0` force off, `1` force on, `2` auto) retained locally per machine across app restarts and reapplied after reconnect; without a saved override, the firmware's auto handoff is the only refill-kit write on connect. The bounded map keeps 32 machines and evicts the oldest-updated entry. Each connection captures its raw handshake serial, falling back to device ID; account-resolved effective serials are excluded. Raw identity changes across connections do not migrate buckets, while account-only effective identity changes within a connection leave the bucket fixed. If neither is available, defaults are used with no retained entry. It is not detection: `GET /api/v1/machine/info` -> `extra.refillKit` reports what the machine detected | |
| DELETE | `/api/v1/machine/settings/reset` | Reset the connected machine's settings to defaults (fan, heater idle/phase flows + ph2 timeout, refill kit auto, steam purge 0) and clear its retained fan/refill overrides — flow calibration is left untouched; no calibration packet is sent and no unit multiplier is written. A legacy per-machine saved multiplier is never replayed, so reset does not preserve a calibration override for a later connection; an acknowledgement is not evidence of factory restoration | |
| GET | `/api/v1/machine/calibration` | Flow estimation calibration (`flowMultiplier`, calFlowEst MMR) read live from the machine on every request. A read failure returns 500 with an `error` and no `flowMultiplier`; the response is never a fabricated 1.0 | |
| POST | `/api/v1/machine/calibration` | Write the flow estimation calibration multiplier to the machine (calFlowEst MMR) and update the session value. The write is explicit and session-only: nothing is persisted per machine and nothing is replayed on reconnect, app restart, or settings reset. The machine stays authoritative on every connection, and firmware retention of the value across a DE1 power cycle is unverified | |
| GET | `/api/v1/machine/calibration/{target}` | Read DE1 sensor calibration for `flow`/`pressure`/`temperature`, `?source=current\|factory`. Read responses carry the calibration value in `measuredValue` (`de1ReportedValue` is 1.0 for flow/pressure, 0.0 for temperature) | |
| PUT | `/api/v1/machine/calibration/{target}` | Write DE1 sensor calibration for `flow`/`pressure`/`temperature`. Writes are corrections, not sets: flow/pressure multiply the stored value by `measuredValue/de1ReportedValue`, temperature adds `measuredValue−de1ReportedValue`. To set an absolute value, read current `C` first, then write `{de1ReportedValue: C, measuredValue: X}` | |
| POST | `/api/v1/machine/profile` | Upload profile to machine | |
| GET | `/api/v1/machine/firmware` | Firmware catalog with per-artifact eligibility | `firmware_handler.dart` |
| POST | `/api/v1/machine/firmware` | Raw firmware upload (NDJSON progress stream) | `firmware_handler.dart` |
| DELETE | `/api/v1/machine/firmware` | Cancel in-progress firmware update (idempotent) | `firmware_handler.dart` |
| POST | `/api/v1/machine/firmware/apply` | Managed firmware apply: resolve, validate, upload; HTTP 200 admits the NDJSON stream, whose terminal `done`/`error` event reports outcome | `firmware_handler.dart` |
| — | USB charger | Controlled via `POST /api/v1/machine/settings` with `{"usb": "enable"}` or `{"usb": "disable"}` | |
| GET | `/api/v1/machine/waterLevels` | Latest water levels (`currentLevel`, `refillLevel` threshold), the payload `/ws/v1/machine/waterLevels` sends. Waits up to 4 s for the first report after connect, then 504 | |
| POST | `/api/v1/machine/waterLevels` | Update water level threshold; retained per machine and reapplied after reconnect | |
| GET | `/api/v1/machine/capabilities` | List capability identifiers supported by the connected machine. Bengle returns the full set: `cupWarmer`, `integratedScale`, `stopAtWeight`, `ledStrip`, `scaleCalibration`, `preheat`, `wakeSchedule`; plain DE1 returns an empty list | |
| GET | `/api/v1/machine/cupWarmer` | Read cup-warmer state: setpoint (whole °C), manual `enabled`, live `currentTemperature` — Bengle only, 404 elsewhere | |
| PUT | `/api/v1/machine/cupWarmer` | Set setpoint (whole °C, 0–80) and/or `enabled`; temperature-only requests also enable manual heating (back-compat), `enabled:false` keeps the setpoint — Bengle only | |
| GET | `/api/v1/machine/cupWarmer/preheat` | Read scheduled pre-warm `enabled`/`leadMinutes`/`active` (firmware-owned timing) — Bengle only, 404 elsewhere | |
| PUT | `/api/v1/machine/cupWarmer/preheat` | Set pre-warm `enabled` and/or `leadMinutes` (0–120, persisted in firmware) — Bengle only | |
| GET | `/api/v1/machine/ledStrip` | Read stored LED strip palette only (never live preview state; 3 zones × 2 modes, 16-bit RGB; `frontSwitch` derived, not a hardware control); 503 until firmware hydration succeeds — Bengle only | |
| PUT | `/api/v1/machine/ledStrip` | Write palette write-through to FW registers (persisted immediately; `frontSwitch` ignored). Every save writes all four stored registers, even if the app cache matches. The 200 body is the canonical stored palette — strips quantized to the firmware's 8 bits per channel, `frontSwitch` derived — replacing the former `{"status":"accepted"}` acknowledgement, which now only appears if the machine reports no stored palette after the write — Bengle only | |
| POST | `/api/v1/machine/ledStrip/preview` | Show `frontStrip`/`backStrip` as volatile display state on the live registers, never mutating the stored palette; either optional but at least one required. Each supplied colour must be a string of exactly 12 hexadecimal characters (case-insensitive 16-bit RRRRGGGGBBBB); invalid values, including null, return 400 before machine-write queue admission. The stored palette does not move, so an asleep colour can be shown on an awake machine. A frame repeating the colour already shown writes nothing — Bengle only | |
| POST | `/api/v1/machine/ledStrip/preview/clear` | End a preview: refresh the stored palette and unconditionally restore both live registers for the current awake/sleep phase, repeating restoration if the phase changes during writes, up to five passes. Returns 503 if the palette or machine state is unavailable, or the phase did not settle within those passes — Bengle only | |
| POST | `/api/v1/machine/ledStrip/commit` | Compatibility no-op (palette writes are already persisted) — Bengle only | |
| POST | `/api/v1/machine/ledStrip/reset` | Re-read palette from FW and return refreshed state (truthful reload, not a rollback) — Bengle only | |
| GET | `/api/v1/machine/scaleCalibration` | Read decoded scale-calibration state (step, cell, sub-state, seconds remaining, status) — Bengle only, 404 elsewhere | |
| PUT | `/api/v1/machine/scaleCalibration` | Start `zero`/`latch`/`abort` calibration step (`weightGrams` 1–10000 required for `latch`); 202 accepted / 409 rejected (busy or shot in progress) — Bengle only | |

LED preview volatility is guaranteed by firmware rheasman/Bengle#114, not
merely by selecting the live registers. The four stored palette rows remain
persistent; firmware rewrites the live pair at boot and on every sleep/wake
transition. Both preview routes are available without a firmware-build gate.
On pre-#114 firmware, each changed preview frame still flash-writes the live
registers. `GET /api/v1/machine/ledStrip` always returns only the stored palette;
preview and clear never change it.

For classic DE1 machines, snapshot `mixTemperature` is not a reliable
measurement of dispensed hot-water outlet temperature while the machine is in
`hotWater` state. `targetMixTemperature` remains the requested target.

#### Firmware updates

The catalog endpoint is available offline and without a connected machine. It returns bundled artifact metadata, compatibility and version eligibility, the recommended artifact, tri-state `updateAvailable`, and the shared machine operation state. Bundled DE1 firmware builds 1352 and 1358 support the canonical models `DE1`, `DE1Plus`, `DE1Cafe`, `DE1Pro`, `DE1XL`, `DE1XXL`, and `DE1XXXL`; Bengle remains excluded. `updateAvailable: false` means that no applicable newer artifact was found, not necessarily that the machine is current. Clients must inspect per-artifact eligibility: `not_newer` is distinct from `model_incompatible`; eligibility status `unknown` is a separate indeterminate result.

Managed apply accepts `{"artifactId":"de1-1352","force":false}` with a 64 KiB body limit and a 10-second body-read timeout. The complete image is checked against its manifest, SHA-256 digest, canonical DE1 header, and connected model before erase. `force` permits reinstall or downgrade, including when the installed build is unknown, but never bypasses integrity or model checks. The raw endpoint retains its developer/recovery role and accepts `application/octet-stream`, capped at 16 MiB with a 60-second body-read timeout.

Raw and managed updates return `application/x-ndjson`. Events are ordered `erasing`, zero or more `uploading`, then `done`; failures after streaming starts terminate with `error`. A pre-start controller or initialization failure may emit only one terminal `error` without `erasing`. Error events include diagnostic `stage`/`cause` when available; cancellation intentionally omits failure-stage metadata. Upload progress is emitted in approximately one-percent increments. The stream remains open during final machine verification, and `done` is sent only after the DE1 reports `FF FF FD`. The app waits for that value on the machine's notification and on a bounded poll of the firmware-map register, whichever answers first, so an update still completes on firmware that never sends the terminal notification. The erase and verify waits stay bounded, so a stuck update fails rather than hangs. Client disconnect and `DELETE` cancel a pending update before it starts or forward cancellation to an active update.

Pre-stream responses are `400` for malformed input, `404` for an unknown artifact, `408` when a request body stalls, `409` for an active update, `413` when a raw upload exceeds 16 MiB or a managed request exceeds 64 KiB, `422` for validation or policy rejection, and `503` when apply requires a machine or the machine write queue is full. Idempotent cancellation returns `202` with `{"operation":{"state":"idle"}}` when no update remains active.

### Scale

| Method | Path | Description | Handler |
|--------|------|-------------|---------|
| GET | `/api/v1/scale/info` | Information for the currently connected scale | `scale_handler.dart` |
| PUT | `/api/v1/scale/tare` | Tare the connected scale | `scale_handler.dart` |
| PUT | `/api/v1/scales/{id}/tare` | Tare a connected primary or auxiliary scale by opaque device ID | `scale_handler.dart` |
| PUT | `/api/v1/scale/timer/start` | Start scale timer | |
| PUT | `/api/v1/scale/timer/stop` | Stop scale timer | |
| PUT | `/api/v1/scale/timer/reset` | Reset scale timer | |

`GET /api/v1/scale/info` is scoped to the currently connected scale. It returns `503` when no scale is connected and `{}` when connected metadata is not yet known. `firmwareVersion`, when present, is an opaque value reported by the scale (for example `R029`). `batteryLevel` is optional and nullable; unknown values are omitted, while `0` and `100` are valid readings. This endpoint is separate from device inventory.

### Devices

| Method | Path | Description | Handler |
|--------|------|-------------|---------|
| GET | `/api/v1/devices` | List devices (present + remembered) | `devices_handler.dart` |
| GET | `/api/v1/devices/scan` | Scan and fill missing device slots; set `?connect=false` for discovery only | |
| PUT | `/api/v1/devices/connect` | Connect to device by ID (`connectionRole: primary|auxiliary` for scales) | |
| PUT | `/api/v1/devices/disconnect` | Disconnect device | |
| PUT | `/api/v1/devices/forget` | Forget a remembered device | |
| GET | `/api/v1/devices/wifi` | List manually-added WiFi scale endpoints | `wifi_scale_handler.dart` |
| POST | `/api/v1/devices/wifi` | Add a WiFi scale by IP/hostname (`{host}`) | |
| DELETE | `/api/v1/devices/wifi` | Remove a manual WiFi endpoint (`{host}` body or `?host=`) | |

`/api/v1/devices/scan` preserves the existing defaults:
`connect=true` when omitted and `quick=false` when omitted. With connection
enabled, the request scans first, preserves occupied slots, then fills missing
machine and scale slots and connects the preferred runtime grinder when present;
this may take longer than the former quick-connect
behavior. `quick=true` returns immediately but does not change that policy.
REST and devices-WebSocket scans (including `connect=false`) may be coalesced
and deferred during preferred-scale post-wake recovery, or dropped without a
scan if the preferred scale reconnects first, the machine disconnects, the
preferred scale is cleared, or Decaid shuts down.

REST scans accept `connectPreferredScaleEarly=true`; the devices WebSocket
accepts `{"command":"scan","connect":true,"connectPreferredScaleEarly":true}`.
The option defaults to false and is ignored with `connect=false`. It is
independent of `quick`: it changes connection policy, not request waiting.
With a connected non-Bengle machine, resolved machine ownership, an empty
primary scale slot and a configured preferred scale, a matching sighting stops
the scan. GATT starts only after successful teardown; the request need not
finish exhaustive discovery. Pending machine/selection work, occupied slots,
auxiliary claims and sleeping-scale restrictions disable the shortcut. If
ineligible or the preferred scale is absent, normal full explicit discovery and
post-scan policy (including partial-service-failure handling) apply unless an
earlier shortcut teardown fault is still latched. Once the shortcut requests
stop, failed or uncertain BLE teardown prevents connection and blocks scale
reacquisition until a later scan confirms teardown. An early-stop request that
throws still falls back to normal post-scan policy once the scan completes
normally and BLE ownership is released. Unrelated discovery failures do not
block a confirmed BLE handoff.
Coalesced connect requests retain an opt-in from any caller.
Automatic startup and Bengle integrated-scale precedence are unchanged.

`PUT /api/v1/devices/connect` waits for the attempt and returns `deviceId`,
`operation`, `outcome`, the resulting device `state`, and a structured
`connectionError` when applicable. Connected and already-connected devices return
200; conflicting or stale requests return 409; transport failures return 503;
and connection timeouts return 504. The devices WebSocket returns the same result
after each connect command.

Disconnect failures return 500. A selected grinder clears local controller
state before its failure is reported. The devices WebSocket reports the same
failure in an `error` frame.

Each device entry carries an **`available`** boolean. `true` = currently present
in discovery or actively connected; `false` = a **remembered** device that isn't
present (reported with `state: "disconnected"`). Devices the user connects to are
remembered and persist across restarts, shown as unavailable when offline, until
forgotten via `PUT /api/v1/devices/forget` (deviceId in the JSON body or
`?deviceId=` query). The same `available` field is on each device in the
`ws/v1/devices` snapshot.

`GET /api/v1/devices` and `/ws/v1/devices` are inventory-only surfaces. Their device entries contain identity, availability, and connection state, not connection metadata such as `deviceInfo`, `firmwareVersion`, or `batteryLevel`. Connected scale entries additionally expose `connectionRole` (`primary` or `auxiliary`); disconnected and remembered entries omit it. A metadata refresh therefore does not emit an inventory update. Clients that need current connected-scale metadata should call `GET /api/v1/scale/info`; no scale metadata WebSocket is defined until a concrete live-update need exists.

Scale connections are primary by default. Send `connectionRole: "auxiliary"` in
the generic connect body to retain an explicitly connected scale as a runtime
auxiliary session. Auxiliary sessions are not persisted and do not affect shot
sequencing or the legacy singular scale routes. Use
`PUT /api/v1/scales/{id}/tare` and `/ws/v1/scales/{id}/snapshot` to address a
connected primary or auxiliary scale independently.

`available` describes inventory presence, not command ownership. A connected
controller-owned device such as Bengle's integrated virtual scale is listed as
available but is inventory-only: REST connect/disconnect returns 409 and the
devices WebSocket returns an explicit error. Its lifecycle follows the Bengle
machine; use the scale API for operations such as tare.

**Manual WiFi scale endpoints.** Auto-discovered (DNS-SD) WiFi scales appear in
`GET /api/v1/devices` like any other device and need no extra calls. The
`/api/v1/devices/wifi` routes are only for *manually* entering a scale by IP or
hostname (e.g. on networks where mDNS is blocked). All three return
`{ "endpoints": [<host>, ...] }`. An added endpoint surfaces in the device list
as a "Half Decent Scale (WiFi)" entry and validates through the normal
recognition gate — a bad/unreachable address shows as a scale that never
reaches `connected`.

### Shots

| Method | Path | Description | Handler |
|--------|------|-------------|---------|
| GET | `/api/v1/shots` | Paginated list with filtering | `shots_handler.dart` |
| GET | `/api/v1/shots/ids` | All shot IDs | |
| GET | `/api/v1/shots/latest` | Most recent shot | |
| GET | `/api/v1/shots/:id` | Get shot by ID (with measurements) | |
| PUT | `/api/v1/shots/:id` | Update shot annotations | |
| DELETE | `/api/v1/shots/:id` | Delete shot | |

**Filtering `GET /api/v1/shots`.** `grinderId`, `grinderModel`, `beanId`,
`beanBatchId`, `coffeeName`, `coffeeRoaster`, `profileTitle`, `search`, and
`minEnjoyment` all narrow the paginated list and apply to `total` as well as
`items`. `minEnjoyment` is an inclusive threshold on the same 0-10 scale
`PUT /api/v1/shots/:id` validates `annotations.enjoyment` against (not de1app's
or visualizer.coffee's 0-100 scale); shots with no rating are excluded, since
SQL comparisons against a NULL rating never match. A `minEnjoyment` that is not
a finite number, or falls outside inclusive `0..10`, is rejected with 400.
The legacy `ids` parameter is mutually exclusive with every filter above:
combining them is rejected with 400 rather than silently dropping either side.
`beanId` resolves through the bean's live batches, so shots that recorded a
batch of a bean deleted with `DELETE /api/v1/beans/:id` no longer match that
filter; they stay in history and remain reachable through `beanBatchId`,
`GET /api/v1/shots/:id`, and their recorded metadata.

Newly recorded shots snapshot `serialNumber`, `model`, `firmwareVersion`, and
`flowCalibration` under `workflow.machine`; `flowCalibration` is the multiplier
read from (or explicitly written to) the machine in that session and is omitted
when the machine did not report one. Historical records may omit these
fields. Consumers must not infer missing capture-time identity from the machine
that happens to be connected when a record is read.

**Modification tracking.** Every shot carries `createdAt` and `updatedAt`
(ISO-8601 UTC, always serialized with a trailing `Z`). `createdAt` is set
when the shot enters local storage; the extraction `timestamp` is the fallback
for legacy records that predate the field. Both fields are system-managed: a
`PUT /api/v1/shots/:id` body containing either is rejected with 400, so
clients cannot spoof revision metadata. The extraction `timestamp` itself is
recorded data, not an annotation, and is not editable either: a `PUT` body with
a top-level `timestamp` key is rejected with 400 even when the value is `null`
or equals the stored one, because a rewrite would reorder every time-sorted
list and detach the shot from its measurements' clock. A `timestamp` key nested
inside `annotations.extras` is ordinary annotation data. `updatedAt` advances
only when shot *content* changes: `PUT /api/v1/shots/:id` bumps it iff the
merged record differs outside the bookkeeping keys. The bookkeeping keys are
`uploaded_to_decent`, `decent_upload_rejected`, and `visualizerId` inside
`annotations.extras` (the reserved scratch space for plugin sync state).
Writes confined to those keys persist without touching `updatedAt`, so
consumers can reconcile edits by comparing `updatedAt` against their own sync
marker without feedback loops. Rejection of a non-editable field is atomic for
the whole request: a body mixing one with valid annotation edits changes no
annotation, leaves the stored record and `updatedAt` untouched, and emits no
`shotUpdated` event.

**Clearing the note.** `annotations.espressoNotes: null` (and `annotations: null`,
which clears every post-shot annotation) persists the cleared note as an empty
string, and the response carries `espressoNotes: ""` with its `shotNotes` alias
mirroring it. `ShotAnnotations.toJson` omits a null field, so an omitted
`espressoNotes` means a note that was never set; an empty string means a note
the user cleared. Clients that fall back to a pre-shot note in
`workflow.context.extras.note` must not apply that fallback to an empty string.
A clear request always stores the empty string, including on a shot that never had
a note, so it also suppresses any such fallback.
Every other cleared annotation is omitted from the response, since nothing falls
back on those.

An `extras` map emptied by that exclusion compares equal to no `extras`, and
an `annotations` map emptied by it compares equal to no `annotations`, so the
first-ever sync marker on a clean shot does not dirty it. All other `extras`
keys count as content. `measurements` is not editable through this endpoint:
a PUT body containing it is rejected with 400. Sync import with
`onConflict: overwrite` replaces the whole record, so its comparison
includes `measurements` (which overwrite can change, unlike PUT): the
existing `createdAt` is preserved, and `updatedAt` advances whenever the
imported record differs from the stored one, so a no-op re-import cannot
move a consumer's cursor backwards.

### Steams

Recorded milk-steaming sessions. Each record is opened when the machine
enters `steam` and finalized when it leaves. `SteamSnapshot.milkTemperature`
uses the preferred Bengle milk probe when its declared temperature channel is
available, and is `null` when no suitable sensor is registered.
`SteamSettings.stopAtTemperature` (in
`/api/v1/workflow`) is the target the future FW-autonomous stop or
in-app stop will trigger on.

| Method | Path | Description | Handler |
|--------|------|-------------|---------|
| GET | `/api/v1/steams` | List all steam records (no measurements) | `steams_handler.dart` |
| GET | `/api/v1/steams/ids` | All steam record IDs | |
| GET | `/api/v1/steams/latest` | Most recent steam record (no measurements) | |
| GET | `/api/v1/steams/:id` | Get steam record by ID (with measurements) | |
| PUT | `/api/v1/steams/:id` | Update steam record annotations | |
| DELETE | `/api/v1/steams/:id` | Delete steam record | |

### Profiles

| Method | Path | Description | Handler |
|--------|------|-------------|---------|
| GET | `/api/v1/profiles` | List all profiles | `profile_handler.dart` |
| GET | `/api/v1/profiles/defaults` | List bundled default profiles (filename + metadata) | |
| GET | `/api/v1/profiles/:id` | Get profile by content-hash ID | |
| POST | `/api/v1/profiles` | Create new profile | |
| PUT | `/api/v1/profiles/:id` | Update profile (in-place; hash change replaces the record) | |
| DELETE | `/api/v1/profiles/:id` | Soft-delete profile (defaults hidden, user profiles soft-deleted) | |
| PUT | `/api/v1/profiles/:id/visibility` | Change profile visibility | |
| GET | `/api/v1/profiles/:id/lineage` | Get profile version history | |
| DELETE | `/api/v1/profiles/:id/purge` | Permanently delete (user profiles only) | |
| GET | `/api/v1/profiles/export` | Export all profiles as JSON | |
| POST | `/api/v1/profiles/import` | Import profiles from JSON | |
| POST | `/api/v1/profiles/restore/:filename` | Restore a bundled default by manifest filename | |

Profile updates use tri-state patch semantics: omitting `metadata` preserves it,
`metadata: null` clears it, and an object replaces it. The profile itself is
non-nullable; `profile: null` returns `400`.

### Workflow

| Method | Path | Description | Handler |
|--------|------|-------------|---------|
| GET | `/api/v1/workflow` | Get current workflow (profile + context) | `workflow_handler.dart` |
| PUT | `/api/v1/workflow` | Update workflow (one ordered deep-merge mutation) | `workflow_handler.dart` |

Each `PUT /api/v1/workflow` is one independent mutation. Requests run in FIFO order without
cross-request or cross-client coalescing. Partial updates are deep-merged against the latest
workflow state when each request executes, and each response contains that request's resulting
workflow. Omitted steam-setting fields are preserved and supplied values replace them. The
`steamSettings` object and all of its fields are non-nullable; explicit `null` returns `400`.
The `context` object is validated against `WorkflowContextPatch`, which is not the stored
`WorkflowContext`: every context field still accepts an explicit `null` to clear it, except
`context.targetYield`, which returns `400`. `targetYield` is the single source of truth for
stop-at-weight and null and `0` both mean the feature is off, so omit the field to keep the
current value, or send `0` to turn stop-at-weight off deliberately; a value that is not a
number returns `400` rather than clearing the target. The `context` object itself is
non-nullable too — `{"context": null}` returns `400`, because dropping the whole context
would clear `targetYield` with it, so clearing is per field. A stored or returned workflow
keeps a nullable `targetYield`. `context.grinderRpm` is an optional non-negative integer recorded by the workflow; it is never inferred from a connected grinder observation or catalog UI increment. When a shot is stored, its workflow context (including RPM and namespaced `extras`) is detached as historical data, while `grinderId` remains only a catalog reference and linked burrs are resolved for that new shot.
Requests may wait behind machine I/O; the server does not debounce high-frequency
input, so clients should throttle controls themselves. Bodies larger than 1 MiB return `413`,
requests beyond the eight-entry active/queued limit return `429`, and requests waiting more
than 30 seconds for execution return `503` without being applied. Machine-write failures
return an error before the controller workflow is committed. Multi-step machine writes may
be partially applied, and retrying the same request re-attempts the requested settings.
Request bodies have a 30-second read timeout; body-read failures return `408`
without poisoning later queued mutations. DE1 writes allow one active operation and
32 pending operations; a full device queue returns `503`. Pending rinse, steam, and
hot-water settings coalesce by component, and a superseded workflow request returns
`409`. A replaceable setting may reconcile after reconnect only when the machine
identity matches; failure to reconnect within the bounded wait returns `503`.
Imperative writes are not replayed after a disconnect. In each failure case, the
workflow is not committed. A `stopAtTemperature`-only workflow change never touches
the DE1 directly — the Bengle bridge applies it
asynchronously — so it commits even while no machine is connected.

Workflow numeric settings are not constrained by guessed REST `minimum` or
`maximum` values. The consumer skin offers 1–10 ml/s for `hotWaterData.flow`,
including the model default of 10 ml/s, but finite values outside that
recommendation are preserved rather than clamped. The packed DE1
protocol has separate unsigned-byte capacities and conditional steam semantics;
those encoding limits are not API validity claims. See
[workflow-numeric-limits.md](workflow-numeric-limits.md) for the field inventory
and evidence.

### Beans

Bean, bean-batch, and grinder updates use tri-state patch semantics: omitted
fields preserve stored values, explicit `null` clears nullable fields, and
supplied values replace them. Explicit `null` for non-nullable fields returns
`400`.

`POST /api/v1/beans` requires `roaster` and `name`. Each must be a JSON string
that is non-empty after trimming; a missing, `null`, non-string, empty or
whitespace-only value returns `400` with
`{"error":"Invalid request","message":"<field> is required"}` and creates no
bean. Accepted values are stored as supplied, without trimming.

| Method | Path | Description | Handler |
|--------|------|-------------|---------|
| GET | `/api/v1/beans` | List all beans | `beans_handler.dart` |
| POST | `/api/v1/beans` | Create bean | |
| GET | `/api/v1/beans/:id` | Get bean | |
| PUT | `/api/v1/beans/:id` | Update bean | |
| DELETE | `/api/v1/beans/:id` | Delete bean | |
| GET | `/api/v1/beans/:id/batches` | List batches for a bean | |
| POST | `/api/v1/beans/:id/batches` | Create batch | |
| GET | `/api/v1/bean-batches` | List batches across all beans | |
| GET | `/api/v1/bean-batches/:id` | Get batch | |
| PUT | `/api/v1/bean-batches/:id` | Update batch | |
| DELETE | `/api/v1/bean-batches/:id` | Delete batch | |

`DELETE /api/v1/beans/:id` deletes the bean and every batch it owns, archived
batches included, in one transaction, so a failing statement rolls the whole
deletion back. Foreign-key enforcement stays enabled and no schema migration is
involved. Historical shots are preserved: their recorded `beanBatchId`,
workflow, annotations, measurements, and timestamps are neither deleted nor
rewritten, which keeps history serving a batch that no longer exists.

### Grinders

The singular `/api/v1/grinder/*` surface controls the one selected runtime
`GrinderDevice`:

| Method | Path | Description | Handler |
|--------|------|-------------|---------|
| GET | `/api/v1/grinder/info` | Runtime `deviceId`, unchanged command capabilities, optional observations, effective controls and available plugin surfaces | `grinder_handler.dart` |
| GET | `/api/v1/grinder/state` | Latest validated grinder snapshot | |
| PUT | `/api/v1/grinder/state/grinding` | Start grinding | |
| PUT | `/api/v1/grinder/state/idle` | Stop grinding | |
| PUT | `/api/v1/grinder/setting` | Set a string setting (`{"setting":"12.3"}`) | |
| PUT | `/api/v1/grinder/rpm` | Set a nonnegative integer RPM (`{"rpm":1200}`) | |
| WS | `/ws/v1/grinder/snapshot` | Snapshot-only stream across disconnect and replacement | |

No connected grinder returns 503. Unsupported declared operations return an
error with `code: "unsupported_operation"`. Effective descriptors validate
string settings and integer RPM before invoking the driver; rejected values
return `code: "invalid_argument"` without clamping or rewriting. Numeric
settings require a finite parsed value within inclusive bounds; enumerated
settings match exactly; opaque settings accept any string. `step` is a display
hint, never a rounding rule. Without descriptors, v1 commands remain valid.

`observations`, when present in info, lists independently declared `setting`
and/or `rpm` observations; it is omitted when none are declared. These declarations
do not enable commands or create writable controls. Snapshot `observedSetting`
(string) and `observedRpm` (nonnegative integer) report only declared observations.
They are omitted when unavailable for that snapshot, never defaulted or carried
forward. Drivers decide freshness in an active session; the host fences stale,
disconnected, retired and superseded sessions. Existing `setting` / `rpm` retain
v1 semantics and require their existing command capabilities in plugin publications.
Observations are runtime-only and are not saved to shot history or equipment records.

`controls` is omitted when no descriptors exist. `surfaces` is omitted when
none are declared, or `[]` when declared surfaces are temporarily hidden.
Plugins update session info through `context.publishInfo({controls, surfaces})`,
not snapshot `context.publish({state, setting, rpm, observedSetting, observedRpm})`. Info and snapshot publication
share connection authority and cleanup; invalid info preserves accepted values.
Each surface has a host-owned role and a host-built same-plugin `href` with the
runtime `deviceId` query-encoded once; do not treat that identity as a persisted
Grinder UUID. The API exposes no vendor command or catch-all route.

New snapshot WebSocket subscribers immediately receive the selected grinder's
current snapshot when available. Disconnect and replacement clear the retained
snapshot; disconnected subscriptions stay silent and never receive stale or
null frames.

This runtime identity is deliberately separate from persisted equipment. A
persisted `Grinder.id` is a UUID used by the plural `/api/v1/grinders` CRUD
surface and workflow metadata. A runtime grinder has a transport/plugin
`deviceId`. `preferredGrinderDeviceId` stores that runtime ID for connection
from normal scan results; it is never a persisted `grinderId`.

### Grinder Records

| Method | Path | Description | Handler |
|--------|------|-------------|---------|
| GET | `/api/v1/grinders` | List all grinders | `grinders_handler.dart` |
| POST | `/api/v1/grinders` | Create grinder | |
| GET | `/api/v1/grinders/:id` | Get grinder | |
| PUT | `/api/v1/grinders/:id` | Update grinder | |
| DELETE | `/api/v1/grinders/:id` | Delete grinder | |

### Settings

| Method | Path | Description | Handler |
|--------|------|-------------|---------|
| GET | `/api/v1/settings` | All app settings (gateway, theme, charging, devices, etc.) | `settings_handler.dart` |
| POST | `/api/v1/settings` | Update settings (partial, key-by-key); while extension management protection is ON, `webUiPath`, a changed `defaultSkinId` and turning `automaticUpdateCheck` on need an `extensions:manage` token ([details](#extension-management-authorization)) | |

Settings fields include: `gatewayMode`, `themeMode`, `logLevel`, `weightFlowMultiplier`, `volumeFlowMultiplier`, `hotWaterFlowMultiplier`, `scalePowerMode`, `blockOnNoScale`, `blockTareDuringShot`, `stopHotWaterAtWeight`, `preferredMachineId`, `preferredScaleId`, `preferredGrinderDeviceId`, `defaultSkinId`, `automaticUpdateCheck`, `chargingMode`, `nightModeEnabled`, `nightModeSleepTime`, `nightModeMorningTime`, `lowBatteryBrightnessLimit`, `keepAwake`, `simulatedDevices`.

Android session-only USB IDs are usable for the current attachment but are not durable device identities. Writing one to `preferredMachineId` leaves the existing preference unchanged. For `preferredScaleId`, a currently discovered, protocol-identified serial-less USB Half Decent Scale is saved as the durable family selector `usb-hds:any`; unsupported or absent session-only scale IDs return `400`. Clients may also save `usb-hds:any` directly without a connected scale. `null` still clears either preference.

The USB HDS family preference auto-connects only when a completed scan finds exactly one matching scale not reserved as auxiliary. Multiple matches require explicit selection; early-connect optimizations do not choose the first family match. Stable USB serial identities, BLE scales and Wi-Fi scales retain exact-device preferences.

For existing clients comparing settings and inventory IDs, `GET /api/v1/settings` presents the family preference as the current attachment ID when exactly one protocol-identified serial-less USB HDS is discovered. With none or multiple matches it returns `usb-hds:any`; this selector is not a device ID and must not be used in addressed routes. This readback is presentation only: stored settings and backups retain `usb-hds:any`, device inventory IDs remain unchanged, and no connection role is assigned. Device inventory coalesces a remembered canonical USB record with a live session-only machine only after that attachment supplies the matching descriptor serial. The working session keeps its ID until a safe reconnect.


`stopHotWaterAtWeight` (boolean, default `true`): when on and a scale is connected, hot-water dispensing tares the scale and stops at the configured hot-water `volume` target treated as grams (mirrors the espresso stop-at-weight). The machine's own volume/time stop remains a backstop, and the value is ignored in `full` gateway mode (a skin owns the machine). `hotWaterFlowMultiplier` (number, default `0.3`) is the seconds-of-lookahead applied to scale weight flow for that stop — separate from `weightFlowMultiplier` because hot water dispenses with a different pump/flow profile than espresso. See [DeviceManagement.md](DeviceManagement.md#hot-water-stop-at-weight).

`blockTareDuringShot` (boolean, default `false`): when on, `PUT /api/v1/scale/tare` is rejected with `400` (`type: "block_tare_during_shot"`) while an **app-tracked** espresso shot is actively brewing (any `ShotState` other than `idle`/`finished`). Prevents a stray programmatic tare (skin, external client) from re-zeroing the scale mid-pour and wrecking stop-at-weight. Does not affect the shot sequencer's own arm-before-pour tare or a manual tare via the scale's physical button — those never go through this endpoint. **`full` gateway mode is an explicit policy exemption**: the skin owns the shot there, so this lockout never blocks a tare in that mode, regardless of any app-tracked (including stale or unexpected) shot state.

### WebUI & Skins

| Method | Path | Description | Handler | Token |
|--------|------|-------------|---------|-------|
| GET | `/api/v1/webui/skins` | List installed skins | `webui_handler.dart` | |
| GET | `/api/v1/webui/skins/:id` | Get skin details | | |
| GET | `/api/v1/webui/skins/default` | Get default skin | | |
| PUT | `/api/v1/webui/skins/default` | Set default skin (`{skinId}`) | | required |
| POST | `/api/v1/webui/skins/install/github-release` | Install from GitHub release | | required |
| POST | `/api/v1/webui/skins/install/github-branch` | Install from GitHub branch and persist its source for update checks | | required |
| POST | `/api/v1/webui/skins/install/url` | Install from ZIP URL | | required |
| DELETE | `/api/v1/webui/skins/:id` | Remove installed skin | | required |
| POST | `/api/v1/webui/skins/update` | Check the configured and recorded skin sources for updates; returns per-item `results` | | required |
| GET | `/api/v1/webui/server/status` | Server status (`{serving, path, port, ip}`) | | |
| POST | `/api/v1/webui/server/start` | Start serving default skin through the port 3000 entry point | | required |
| POST | `/api/v1/webui/server/stop` | Stop serving | | required |
| GET | `/api/v1/webui/skin-assets/:id/:filepath` | Fetch a file from another installed skin (cross-skin asset sharing) | | |

Rows marked `required` need a bearer token scoped `extensions:manage` while extension management protection is ON, and need none while it is OFF (the default); see [Extension management authorization](#extension-management-authorization).

`POST /api/v1/webui/skins/update` returns `200` with `{message, results}` when the
check runs to completion, even if some skins fail. Each `results` entry has
`item`, `status` (`updated`, `alreadyCurrent`, or `failed`), and an `error`
string only when `status` is `failed`. A `500` now means the check itself could
not run, not that some items failed. A manual call answers regardless of the
`automaticUpdateCheck` setting, which governs only the app's own scheduled
checks.

`GET /api/v1/webui/skins` and `GET /api/v1/webui/skins/:id` report installed
state only. `version` is read from the installed skin's `skin-manifest.json`
(falling back to `manifest.json`) and is `null` when the manifest omits it, so a
client shows an unknown version instead of inferring one from a release tag,
`sourceUrl`, `commitHash`, an `ETag` / `Last-Modified` header or
`reaMetadata.lastChecked`. Both GET routes are strictly read-only: they never
contact GitHub or another source and never install anything, and they keep
reporting the installed version immediately after an update and across an app
restart. `POST /api/v1/webui/skins/update` is the only skin API operation that
checks the configured sources and recorded user sources for updates and
installs eligible changes. The individual install routes
(`/install/github-release`, `/install/github-branch`, `/install/url`) install
one explicitly requested source rather than running the batch update check.

### Plugins

| Method | Path | Description | Handler | Token |
|--------|------|-------------|---------|-------|
| GET | `/api/v1/plugins` | List all plugins (with `loaded`, `autoLoad`, `source`, `pendingUpdate` fields) | `plugins_handler.dart` | |
| GET | `/api/v1/plugins/:id/settings` | Get plugin settings; secure fields return `{isSet}` only | | |
| POST | `/api/v1/plugins/:id/settings` | Patch plugin settings (omitted preserves, `null` clears), reload the plugin if loaded, and return a redacted result | | required |
| POST | `/api/v1/plugins/:id/enable` | Load plugin + enable auto-load | | required |
| POST | `/api/v1/plugins/:id/disable` | Unload plugin + disable auto-load | | required |
| DELETE | `/api/v1/plugins/:id` | Remove plugin (unload + delete files) | | required |
| PUT | `/api/v1/plugins/:id/source` | Create or overwrite `manifest.json` + `plugin.js` | | required |
| POST | `/api/v1/plugins/install` | Not supported — returns 501 naming the GitHub endpoints | | required |
| POST | `/api/v1/plugins/install/github-release` | Install from a GitHub release asset; tag must equal the manifest version | | required |
| POST | `/api/v1/plugins/install/github-branch` | Install from a GitHub branch; the resolved commit drives updates | | required |
| POST | `/api/v1/plugins/update` | Check every GitHub-backed plugin for updates; returns per-item `results` | | required |
| POST | `/api/v1/plugins/:id/update/approve` | Install an update that asks for new permissions | | required |
| ANY | `/api/v1/plugins/:id/:endpoint` | Plugin HTTP endpoint; requires `api` and returns 403 without it | | |
| WS | `/ws/v1/plugins/:id/:endpoint` | Plugin WebSocket endpoint | | |

Rows marked `required` need a bearer token scoped `extensions:manage` while extension management protection is ON, and need none while it is OFF (the default); see [Extension management authorization](#extension-management-authorization).

`POST /api/v1/plugins/update` returns `200` with `{message, results}` when the
check runs to completion, even if some plugins fail. Each `results` entry has
`item`, `status` (`updated`, `alreadyCurrent`, `pendingApproval`, or `failed`),
and an `error` string only when `status` is `failed`. A `500` now means the
check itself could not run, not that some items failed.

For plugin HTTP and WebSocket endpoint routes, `id` and `endpoint` are opaque
URI path components. Clients percent-encode each once; the handler decodes each
once before lookup or subscription matching. Generated device surface hrefs
already encode these components, including spaces and literal percent signs.

Plugin setting updates use patch semantics for every field: an omitted field
preserves the existing value, a field sent as `null` clears it, and a secure
field sent as its returned `{ "isSet": true|false }` object preserves the
stored credential. Secure values are never returned by either endpoint,
including the POST response.

Plugin manifests may declare `notifications` for the generic native notification
contract documented in `Plugins.md`. It adds no REST or WebSocket route and does
not grant arbitrary native navigation or execution.

### Display

| Method | Path | Description | Handler |
|--------|------|-------------|---------|
| GET | `/api/v1/display` | Display state (brightness, wakelock) | `display_handler.dart` |
| POST | `/api/v1/display/brightness` | Set brightness | |
| POST | `/api/v1/display/wakelock` | Request wakelock override | |
| DELETE | `/api/v1/display/wakelock` | Release wakelock override | |

### Presence & Sleep

| Method | Path | Description | Handler |
|--------|------|-------------|---------|
| POST | `/api/v1/machine/heartbeat` | Signal user presence (keep-alive) | `presence_handler.dart` |
| GET | `/api/v1/presence/settings` | Get presence/sleep settings | |
| POST | `/api/v1/presence/settings` | Update presence/sleep settings (validated — see below) | |
| GET | `/api/v1/presence/schedules` | List wake schedules | |
| POST | `/api/v1/presence/schedules` | Create wake schedule | |
| PUT | `/api/v1/presence/schedules/:id` | Update wake schedule | |
| DELETE | `/api/v1/presence/schedules/:id` | Delete wake schedule | |

`POST /api/v1/presence/settings` validates its body before persisting anything:

| Field | Accepted | On anything else |
|---|---|---|
| `userPresenceEnabled` | a boolean | `400`, nothing stored |
| `sleepTimeoutMinutes` | a JSON integer | `400`, nothing stored |

Integer values for `sleepTimeoutMinutes` are normalized into **0..240**. `0` disables the app-side
idle sleep timer. Partial updates are supported — fields are optional. Invalid field types in the
same request prevent all fields from being stored (validation is atomic).

### Sensors

| Method | Path | Description | Handler |
|--------|------|-------------|---------|
| GET | `/api/v1/sensors` | List connected sensors | `sensors_handler.dart` |
| GET | `/api/v1/sensors/:id` | Get sensor manifest | |
| POST | `/api/v1/sensors/:id/execute` | Execute sensor command | |

Plugin-backed sensors registered through `host.devices` use this same API and
the device inventory. Their stable IDs have the form
`plugin:<pluginId>:<driverId>:<instanceId>`. Sensor manifests expose command
result schemas as `resultsSchema`. See `Plugins.md` for registration and
lifecycle rules.

#### `Bengle EBus Tap` sensor

The Bengle EBus tap (USB interface `2` of a composite Bengle, VID `0x2e8a` /
PID `0x000a`) is exposed through the generic Sensors surface — no new REST
path. Manifest:

```json
{
  "name": "Bengle EBus Tap",
  "vendor": "Decent Espresso",
  "data": [{"key": "bytes", "type": "string", "unit": "base64"}],
  "commands": [{"id": "write", "paramsSchema": {"bytes": "string"}}]
}
```

`GET /api/v1/sensors` lists the tap under its stable ID
`usb-2e8a-a-<serial>-if02`. Each frame on `/ws/v1/sensors/<id>/snapshot` is one
serial read chunk:

```json
{"timestamp": "2026-08-31T12:34:56.789Z", "bytes": "tp4..."}
```

`bytes` is standard base64; concatenating decoded chunks reproduces the exact
serial byte stream. Chunk boundaries carry no protocol meaning.

Raw write base64-decodes `bytes`, writes exactly those bytes to the tap, and
returns the byte count written:

```text
POST /api/v1/sensors/usb-2e8a-a-<serial>-if02/execute
{"commandId": "write", "params": {"bytes": "AO4A"}}
→ {"status": "ok", "result": {"bytesWritten": 3}}
```

Malformed or missing base64 is rejected before any write. The tap is
single-owner: no other reader may hold the port while Decaid owns it.

### Key-Value Store

| Method | Path | Description | Handler |
|--------|------|-------------|---------|
| GET | `/api/v1/store/:namespace` | List keys in namespace (or `?full=1` for the whole namespace) | `kv_store_handler.dart` |
| GET | `/api/v1/store/:namespace/:key` | Get value | |
| POST | `/api/v1/store/:namespace/:key` | Set value | |
| DELETE | `/api/v1/store/:namespace/:key` | Delete key | |

`GET /api/v1/store/:namespace?full=1` returns the entire namespace as a `{key: value}` map in one request instead of one GET per key. It sends an `ETag`, so a repeat request with `If-None-Match` returns `304 Not Modified` when nothing changed — cheap to poll. Without the flag the endpoint returns just the array of keys.

### Data Management

| Method | Path | Description | Handler |
|--------|------|-------------|---------|
| GET | `/api/v1/data/export` | Export full backup as ZIP | `data_export_handler.dart` |
| POST | `/api/v1/data/import` | Import from ZIP (raw bytes, `Content-Type: application/zip`) | |
| POST | `/api/v1/data/sync` | Sync with another Bridge instance | `data_sync_handler.dart` |

Sync accepts `target` (URL), `mode` (`pull`, `push`, `two_way`), `onConflict` (`skip` or `overwrite`), and `sections` (profiles, shots, workflow, settings, store, steams, beans, grinders). The `target` must be an HTTP/HTTPS origin with no path, query, or fragment; a trailing slash is accepted and equivalent, and IPv4, hostname, and IPv6 hosts are supported. Other forms return `400` before any network request. `sections` is optional for all three modes; omission means all locally registered sections. An explicitly empty or malformed list, or unknown section, returns `400` before any network request. Duplicate names are deduplicated in first-occurrence order.

Sync responses use semantic results rather than transport status alone. Each direct section under `pull.<section>` and `push.<section>` remains available and gains `status` (`complete`, `partial`, or `failed`). Additive phase metadata is under `phases.<phase>` with `status`, `complete`, and `partial`; fatal phase details remain available at the legacy `pull` or `push` path and are repeated under `phases`. Skipped-push reasons are reported under `phases`. A phase is complete only when every expected section is represented without errors. Warnings, conflict skips, and zero imported records do not make a valid section partial. Section errors with progress are partial; errors without progress are failed. Partial imports are not transactional.

In `two_way` mode, push runs only after every expected pull section completes by default. Set `continueOnPullFailure: true` to explicitly continue after a partial or failed pull; the option is limited to `two_way` and is never inferred from overwrite handling. A complete operation returns `200`, an incomplete single-direction operation returns `502`, and an incomplete two-way operation with meaningful progress returns `207`; a two-way operation with no complete or partial phase returns `502` (its body may still report `partial` only when meaningful progress exists). Legacy flat and structured remote import responses are supported, but malformed, contradictory, hybrid, missing-section, and HTTP `200` responses with embedded errors are not treated as success.

Backups are ZIP archives with one JSON file per registered section:
`profiles.json`, `shots.json`, `workflow.json`, `settings.json`, `store.json`,
`steams.json`, `beans.json`, and `grinders.json`. Import matches files by their
registered section names; unknown files are ignored, but an archive must contain
at least one recognized selected section. `metadata.json` is not payload:
metadata-only, empty, and unknown-only archives return `400`. Metadata is
optional for legacy archives without it. When present, its JSON and
`formatVersion` are validated before any section is imported. ZIP integrity and
structural JSON are validated for every selected section before storage is
mutated; any failure returns `400` without importing a section. Semantic record
errors are processed independently and are not transactional, so successful
sections are not rolled back when another section reports semantic errors.
Export is atomic: if any requested
section fails to export, the request returns an error identifying the failed
section(s) and no partial ZIP is returned.

`POST /api/v1/data/import` preserves its section-keyed response body. `200`
means at least one recognized section was processed and every processed section
completed without errors. `207 Multi-Status` means at least one processed
section contains errors; successful sections, counts, warnings, and errors are
all retained. Warnings and conflict-strategy skips alone still return `200`.
Clients must inspect both the HTTP status and each section result. Invalid
backup archives return `400` with `error` and `message`. Only an archive that
exceeds the 4096-entry safety limit includes `reason: "too_many_entries"`;
other invalid archives and `400` responses omit `reason`.

Data sync preserves the same phase distinction. A complete pull or push is
represented by `200`. An incomplete single-direction sync returns `502`, even
when its body reports semantic `partial` progress. A two-way sync returns `207`
when it has meaningful progress but is incomplete; a two-way sync with no
complete or partial phase returns `502`. Phase results remain under `pull` and
`push`, including successful sections and fatal error details.

### Bounded-memory transfer (issue #555)

Backup export, import, and sync stream data instead of buffering whole
archives in memory; peak memory scales with one page of records and one JSON
record, never with backup size.

- **Export** streams each section (records paged via stable keyset cursors)
  through a file-backed ZIP writer (raw deflate via `dart:io`, data
descriptors, central directory written last) and serves the completed
temporary ZIP with `Content-Type: application/zip`, `Content-Disposition:
attachment`, and `Content-Length`. The archive is atomic: a failing section
returns an error and no partial ZIP.
- **Import** streams the request body into a temporary ZIP (never
`read().toList()`), opens it with `InputFileStream` / `ZipDecoder`, and writes
one selected entry at a time to a bounded temporary JSON file for incremental
parsing. Every selected entry is structurally validated before the record-import
pass begins. ZIP bombs, duplicate names, encrypted/unsupported entries, CRC
failures, truncation, Zip64, and malformed JSON all fail safely. A 30-second
idle request body is cancelled with `408`.
- **Sync** pulls stream the remote response into a temporary ZIP; pushes
export locally and stream the file with a known content length.
- **Native transfer** downloads the localhost export into a temporary file
(validating HTTP status and `application/zip` before presenting a
destination), shares it via the OS share sheet on iOS/Android, and streams
picked files into the import request.

Limits (documented in `assets/api/rest_v1.yml`): request body 2 GiB, entry
count 4096, per-entry uncompressed 1 GiB, total uncompressed 2 GiB,
metadata 64 KiB, per-record 64 MiB (measured in UTF-8 bytes), ZIP header
fields 256 B/64 KiB/64 KiB; sync request body 1 MiB with a 30-second read
deadline, target response 8 MiB; connection 10 s (TCP establishment only — server-side
export/import processing is not counted against it), idle 30 s, and one
deadline (10 min) per phase covering the network stages (upload/download
and response). Timeouts abort the request at the transport level: a
timed-out pull is cut off even while the target is still generating its
export (before headers) and never starts its import; a timed-out push
aborts its upload, and the upload is backpressured so the archive file
is never read ahead of the network. Local export and the pull-side
import run to completion and report their actual results. If the archive
was already fully uploaded before the deadline, the remote outcome is
unknown and the phase reports reason `timeout_unknown`. A generated
archive is also bounded by the 2 GiB import request limit.

### Account

| Method | Path | Description | Handler |
|--------|------|-------------|---------|
| GET | `/api/v1/account/decent` | Decent account auth status: `{loggedIn}` (true only when stored credentials are accepted by the backend) | `account_handler.dart` |
| GET | `/api/v1/account/proxy/<path>` | Auth-enriching proxy to `decentespresso.com/<path>` | `account_proxy_handler.dart` |
| POST | `/api/v1/account/proxy/<path>` | Auth-enriching write proxy (relays body) | `account_proxy_handler.dart` |
| PUT | `/api/v1/account/proxy/<path>` | Auth-enriching write proxy (relays body) | `account_proxy_handler.dart` |

Linking/unlinking a Decent account is **native-only** — there are no network login/logout routes. Apart from the account proxy and extension management, the webserver is unauthenticated, and it echoes `Access-Control-Allow-Origin` for whatever origin a request presents (extension management additionally refuses untrusted browser origins, see [Browser origins](#browser-origins)), so exposing credential operations would let any LAN client or browser origin store attacker credentials or unlink the account. The status response omits the linked email (PII).

The **proxy** lets clients *use* the account without ever seeing the credentials: it attaches the linked account's Basic auth server-side, forwards to `decentespresso.com`, and relays the upstream status + body verbatim. It requires `Authorization: Bearer <token>`. The account proxy's scopes are independent of [extension management](#extension-management-authorization), which is the other surface with a scope of its own (and needs it only while extension management protection is ON): an `extensions:manage` token cannot use the proxy, and an account-proxy token cannot manage extensions. `GET` requires `account:proxy` (including the skin token injected into served skin pages); `POST`/`PUT` require the stronger `account:proxy:write` scope, so the read-only skin token cannot write. Forwarding is restricted to the `support/api/` prefix. The OpenAPI spec documents the generated-client-safe `/support/api/{endpoint}` form; use this raw catch-all route when a Decent backend path contains additional slashes. Each served skin generation gets a fresh token bound to that skin's immutable consent key; switching or stopping the skin server revokes the previous token. The skin's origin normally remains stable across restarts, with a temporary fallback if its assigned port is occupied; see [Skin Origins and Browser Storage](Skins.md#skin-origins-and-browser-storage). The stable port 3000 entry point redirects without caching to the active origin and is the address to bookmark. The first request from each skin, plugin, or named API client pauses for native approval on the Decaid device. Explicit allow and deny decisions are remembered; a 30-second timeout denies only that request. Responses: 401 (missing/invalid token or no linked account), 403 (token unscoped, path not allowed, or account access not granted). Write-scoped tokens are minted from the account page's API-token UI by enabling "Allow write access". Headless operators can grant session-only access with `--trust-consent=<caller-key>` or `--trust-all-consent`.

**Inactive skin ports redirect to the entry point.** The active skin is served on its own stable origin; a persisted port whose skin is inactive answers only with a `307` `Cache-Control: no-store` redirect back to the port 3000 entry point, preserving host, path and query. That listener serves no skin files and no token, and its origin is never added to the account-proxy allowlist, so an older per-skin bookmark lands on whichever skin is active instead of becoming a dead address. Temporary fallback origins are unstable and are never aliased; see [Skin Origins and Browser Storage](Skins.md#skin-origins-and-browser-storage).

### Other

| Method | Path | Description | Handler |
|--------|------|-------------|---------|
| GET | `/api/v1/info` | Build metadata (version, commit, branch) + gateway LAN IP (`localIp`) | `info_handler.dart` |
| GET | `/api/v1/diagnostics/ble` | Read-only BLE adapter, scan/watch ownership, reconnect policy, cache, and advertisement diagnostics | `ble_diagnostics_handler.dart` |
| GET | `/api/v1/update` | App-update state snapshot (`phase`, `latestVersion`, `releaseNotes`, `releaseUrl`, `installable`). Pure read — no network call; force a re-check via `/ws/v1/update`. | `update_handler.dart` |
| POST | `/api/v1/feedback` | Submit feedback with an authenticated Decent account (creates GitHub issue; optional Support-link status) | `feedback_handler.dart` |
| GET | `/api/v1/logs` | Recent log entries, newest first. Live log + rotated files `log.txt.1..N` are always stitched chronologically; response is a size-bounded tail window (`?kb=N`, default 1024 KB, clamped to 4096 KB). `?order=asc` for original chronological order | `logs_handler.dart` |
| GET | `/api/v1/webview/logs` | WebView console log forwarding, newest first (`?order=asc` for original chronological order) | `webview_logs_handler.dart` |
| POST | `/api/v1/derek/answers/stream` | Relay to the Derek RAG assistant: forwards the JSON body verbatim to `derek.decentespresso.com/api/answers/stream` and pipes the SSE response back unbuffered. No auth (public data). Exists so browser skins avoid Derek's failing CORS preflight. | `derek_handler.dart` |

Online skin/plugin actions, app updates, feedback, and host-side account/Derek
connection failures return plain-language guidance. Transport/parser details stay
in logs. Timeouts and secure-connection failures have distinct messages; connection
errors never assert Wi-Fi is off. JSON fields and upstream passthrough are unchanged.
Plugin validation and downgrade failures retain HTTP 400 and 409, respectively.

Native Android updates download before requesting installation authorization.
If permission is missing, Decaid opens Android's per-source installation settings
directly and resumes the same in-memory attempt when that native activity returns.
Granting permission opens the installer once; denial retains neutral Retry guidance
and the cached APK. Archive preflight checks package and compatible signing identity,
including single-signer forward rotation. Missing or unusable cached files are
rechecked after permission returns; the next Retry downloads a replacement when
validation fails. Android's package installer remains the authority for full APK
integrity and update policy. Pending installation does not survive process restart,
closing its owner cancels the attempt, and launching the installer does not mean
installation has completed.

Missing or incorrectly typed GitHub release, asset, or commit fields are
validation failures (HTTP 400), including when the response is valid JSON.

Skin/plugin batches attempt all items and retain successes. Both update
endpoints return HTTP 200 with per-item `results` (`updated`, `alreadyCurrent`,
`failed`, `pendingApproval`) even when some items fail. HTTP 500 means the overall
checking machinery could not run, not an individual item failure. Background
checks stay quiet; retries are manual.
Failure to persist a plugin's diagnostic `lastError` is logged without stopping
the remaining updates or replacing the original failure in the aggregate.

Feedback verifies the stored Decent credentials before uploading attachments,
creating an issue, or contacting Support. Missing, rejected, or unverifiable
credentials return `400` with `success: false`, `error: "Decent account required"`,
and a `message` explaining whether to sign in or retry verification. This applies
to native feedback and the Settings plugin's HTTP submissions. Both UI entry
points offer feedback only while logged in; otherwise they direct users to
Decent Account. Submission always re-verifies credentials, with a 30-second
deadline covering credential reads and the complete upstream response. A timeout
returns `400`, aborts the verification request, and ignores late replies.
Feedback uses the configured native GitHub PAT for GitHub API requests when
present; otherwise it uses the build-supplied feedback credential. PAT failures
never fall back to another identity and advise replacing or removing the PAT in
Advanced Settings. The PAT is never exposed through this API. It is managed only in native
Advanced Settings and stored in the platform secure credential store under a
separate Decaid GitHub namespace; it is not included in SharedPreferences,
settings responses, exports, logs, diagnostics, skins, or plugins. A token is
optional: without one, public metadata requests remain anonymous and feedback
uses the build-supplied credential. With one, GitHub API requests use the
current token immediately, while release archives, ZIPs, and CDN downloads
remain unauthenticated. The token owner is the GitHub identity shown on native
feedback issues and attachment gists. Secure-storage read failures are surfaced
in native settings and do not block app startup; requests retry loading later.

For feedback from outside the Decaid organization, use a personal access token
(classic) with `public_repo`, plus `gist` only for logs/screenshots. The broader
`repo` scope includes public-repository access but also grants private-repository
access and is unnecessary for Decaid. Fine-grained tokens may authenticate and
read metadata, but GitHub restricts their public-organization issue writes for
non-members. Use an expiry and keep tokens private.

Native **Test token** checks an unsaved draft first, otherwise the saved user
PAT, using read-only `GET https://api.github.com/user`. Success verifies
authentication and identity only, not permission to create issues or Gists.
Testing never saves a draft or changes active credentials. No token is required
for public update metadata, and no PAT-testing API is exposed to skins/plugins.

Account failures take precedence over missing GitHub configuration: `503` only
applies after successful account verification. Other submission failures remain
`500`. Trusted-LAN callers use the host's account without separate caller
authentication.
After issue creation, Support linking is best-effort: only the returned
`messageId` is appended to the latest issue body as `**Support message:**`.
Issue creation is submission success even when Support linking fails. A normal
full success returns `201`; if linking fails, the API returns `200` with the
same issue reference plus optional `supportLink: "failed"` and a safe `warning`.
A successful link may include `supportLink: "linked"`; it is omitted when no
Support reference receipt is available.
The Support response contract is `{"messageId":67890}`; no user ID is requested
or retained. The proposed ID format is a positive JSON integer or an ASCII
decimal string of 1-256 digits without leading zeros. The value `1` is reserved
and never published as a message ID. Email addresses, opaque strings, and other
invalid IDs skip linking without failing the created issue. The backend
maintainer must confirm the numeric format, lookup uniqueness, and public safety;
numeric validation alone cannot establish that an ID is safe to publish.
Unexpected response fields are ignored, and raw responses are never
included in logs or errors. Temporary Support acknowledgement `1` means
no message ID is available and skips the GitHub update. A Support outage does
not undo the GitHub issue. No response-mode query parameter is sent.
Support delivery and feedback receipts are separate: a successful legacy opaque
response or an invalid receipt has no message ID and skips linking. It does not
fail delivery-only callers such as the serial-mismatch notification. Non-200
responses and empty/zero acknowledgements still fail delivery.

### Debug (debug builds only)

Only registered when the app is launched with a non-empty `simulate` Dart define. Use `--dart-define=simulate=0` to enable the routes without selecting simulated devices. Returns 404 on production builds.

| Method | Endpoint | Description | Handler |
|--------|----------|-------------|---------|
| POST | `/api/v1/debug/update/force` | Force a fake "update available" so the update API/UI can be tested without a real newer release. Optional query: `version` (default `99.0.0`), `downloadUrl` (default = real latest APK, so the download/install path runs end-to-end). | `debug_handler.dart` |
| GET | `/api/v1/debug/flow-smoothing` | Read process-local display-flow smoothing (`windowMs`, `movingAverageSamples`). | `debug_handler.dart` |
| POST | `/api/v1/debug/flow-smoothing` | Atomically update and reset display-flow smoothing; accepts integer `windowMs` (100–2000) and `movingAverageSamples` (1–50). | `debug_handler.dart` |
| POST | `/api/v1/debug/scale/stall` | Pause mock scale weight emission (stays "connected") | `debug_handler.dart` |
| POST | `/api/v1/debug/scale/resume` | Resume weight emission after stall | `debug_handler.dart` |
| POST | `/api/v1/debug/scale/disconnect` | Simulate scale disconnect (emits disconnected state, stops data) | `debug_handler.dart` |
| POST | `/api/v1/debug/machine/disconnect` | Simulate mock machine disconnect (emits disconnected state, no auto-reconnect) | `debug_handler.dart` |
| GET | `/api/v1/debug/replay/shots` | List the replay simulator's bundled recordings (stable `id` + `profileTitle`) and the current forced selection (`simulate=replay`). | `debug_handler.dart` |
| POST | `/api/v1/debug/replay/shot/{id}` | Force ReplayDE1 to play recording `id` on subsequent pulls (session-only); overrides profile-match/fallback. | `debug_handler.dart` |
| DELETE | `/api/v1/debug/replay/shot` | Clear the forced recording, returning to profile-match/fallback selection. | `debug_handler.dart` |

Mock-scale command endpoints return 400 if no scale is connected or the connected scale is not a `MockScale`. The machine command endpoint returns 400 if no machine is connected or the connected machine is not a `MockDe1`, and 404 for unknown commands (any debug route 404s on production builds).

---

## WebSocket API

All WebSocket endpoints are on port 8080 at `/ws/v1/...`. See [`assets/api/websocket_v1.yml`](../assets/api/websocket_v1.yml) for full schemas.

| Path | Description | Data |
|------|-------------|------|
| `/ws/v1/machine/snapshot` | Machine state stream (~10Hz), including `needsWater`/`refillStopped` when firmware reports a stopped refill kit. Re-binds across a machine reconnect — see [Machine sockets re-bind](#machine-sockets-re-bind-across-a-reconnect). | Temps, pressures, flow, state |
| `/ws/v1/scale/snapshot` | Scale weight/flow stream. Device-provided flow is passed through; weight-only scales use Decaid's estimator. Stays open across scale disconnects; emits `{"status":"connected"\|"disconnected"}` frames on state change. | Weight, flow, battery |
| `/ws/v1/scales/{id}/snapshot` | Addressed raw stream for one connected primary or auxiliary scale (`timestamp`, `weight`, `batteryLevel`, `timerValue`, `flow`). Includes status frames and remains isolated from sibling sessions. | Weight, flow, battery |
| `/ws/v1/machine/shotSettings` | Shot settings changes. Re-binds across a machine reconnect. | Target temp, volume, weight |
| `/ws/v1/machine/waterLevels` | Water level changes. Re-binds across a machine reconnect. | Current/limit levels |
| `/ws/v1/machine/raw` | Raw BLE characteristic data. Re-binds across a machine reconnect; writes go to the currently-bound machine. | Hex-encoded bytes |
| `/ws/v1/machine/shotState` | Shot sequencer state + decision feed: why a step advanced, why the shot stopped. Replays the latest frame on connect; idle between shots; not gated on a connected machine. | `event` (`state`\|`decision`\|`terminal`), `shotId`, shot phase, machine context, `decision {kind, reason, details, data}` |
| `/ws/v1/devices` | Device discovery + `ConnectionManager` status (phase, found devices, ambiguity, errors). Also accepts `scan`/`connect`/`disconnect` commands. | Device list, `connectionStatus` |
| `/ws/v1/sensors/:id/snapshot` | Sensor data stream. Re-binds across replacement or transient removal/re-add of the same sensor ID. | Sensor-specific |
| `/ws/v1/plugins/:id/:endpoint` | Plugin WebSocket proxy | Plugin-specific |
| `/ws/v1/logs` | App log stream | Timestamped log entries |
| `/ws/v1/webview/logs` | WebView console log stream | WebView console messages |
| `/ws/v1/display` | Display state changes | Brightness, wakelock |
| `/ws/v1/update` | App-update state stream. Also accepts `{"command":"check"}` (refused on macOS and on externally managed App Store/TestFlight builds, where the store owns app updates) and `{"command":"install"}` (Android installs; refused elsewhere). Unsupported-platform/build refusals reply `{"error","url"}` carrying `releaseUrl`. Missing Android installation authorization replies only to the requesting client with `{"error":"Installation requires approval on the Android device","reason":"local_approval_required"}`, before any download or settings navigation, without changing the shared update state. Retry explicitly after granting permission locally. | `phase`, `progress`, `latestVersion`, `installable` |

### Machine sockets re-bind across a reconnect

When a machine reconnects — a power-cycle, a USB re-enumeration, a BLE drop — the app discards the
old machine object and builds a new one. The machine sockets
(`/ws/v1/machine/{snapshot,shotSettings,waterLevels,raw}`) **follow the swap**: the server re-attaches
each open socket to the new machine and frames resume on their own.

For clients this means:

- **Clients do not need to reconnect solely because the machine disconnects.** The socket stays open
  and goes quiet while no machine is connected, then resumes. This mirrors `/ws/v1/scale/snapshot`.
  The existing socket follows a normal machine instance swap, but clients should still reconnect after
  actual WebSocket closure, network failure, or according to their normal liveness policy.
  `/ws/v1/devices` is the authoritative source for machine connection state.
- **No status frame is emitted.** Unlike the scale socket, each machine socket carries exactly one
  payload type per frame, and existing clients parse every frame as that type — a `{"status": ...}`
  frame would break the wire contract. Track link state on `/ws/v1/devices` instead, which reports it
  independently of any machine instance.
- **A gap in frames is not a dead socket.** If a client needs a liveness signal, use `/ws/v1/devices`.
- `/ws/v1/machine/raw` writes are delivered to the machine the socket is *currently* bound to, not the
  one that was present when the socket was opened.
- A `write` response echoes the payload the client submitted, as `payload` in uppercase hex — the
  same encoding a `read` response uses, so a client can correlate **the payload that completed**. It
  does not identify an individual write: two writes carrying the same payload are indistinguishable,
  and the stream is machine-level, so another raw client sending the same payload is equally
  indistinguishable. Clients that ignore `payload` are unaffected.
- If a raw command is sent while no machine is connected, the server replies with
  `{"error": "No machine connected"}` rather than silently dropping it. The socket stays open and
  resumes normal operation when a machine reconnects. Raw commands are not queued for later delivery.

Machine sockets opened before the first machine connection behave like any later disconnected gap:
the socket stays open and remains silent until a machine attaches. No error or status frame is emitted
on the typed telemetry sockets.

### Raw notification semantics

For UnifiedDe1 transports, `/ws/v1/machine/raw` mirrors incoming state info,
DE1/Bengle shot samples, shot settings, water levels and MMR notifications once
at BLE/serial ingress, independently of typed subscribers. Replaying a typed
value, reading an initial characteristic, seeding serial settings or writing
local settings does not synthesize a `notify` frame. Firmware-map and calibration
notifications retain typed-only delivery. Raw command read/write receipts keep
their existing operation types and payload shape.

### Sensor sockets follow replacement

An open `/ws/v1/sensors/:id/snapshot` socket follows the current sensor instance for its ID. When that
sensor is replaced, the server cancels the old data subscription and binds the socket to the replacement.
During a transient removal the socket stays open and silent, then resumes when the same ID returns. The
channel remains sensor-data-only and emits no connection status frames.

The initial lookup is unchanged: opening a socket for an ID that is not present returns
`{"error":"not found"}` and closes the socket.

### `shotState` events

`/ws/v1/machine/shotState` streams the app's shot-sequencer decisions as a single event type
discriminated by `event`. Every frame carries the current shot phase (`state`) and machine context,
so a late joiner gets a coherent view from any single frame; `decision` is non-null only on
`decision`/`terminal` frames.

```json
{
  "event": "decision",
  "timestamp": "2026-06-17T10:32:18.903Z",
  "shotId": "a1b2c3d4-...",
  "state": "pouring",
  "machineState": "espresso",
  "machineSubstate": "pouring",
  "profileFrame": 2,
  "scaleConnected": true,
  "scaleLost": false,
  "machineHasAutonomousSAW": false,
  "decision": {
    "kind": "stop",
    "reason": "targetWeight",
    "details": "Target weight 36.0g reached (projected: 36.4). Stopping shot.",
    "data": {"targetYield": 36.0, "projectedWeight": 36.4}
  }
}
```

- `shotId` equals the persisted `ShotRecord.id`, so the stream can be correlated to the saved shot.
  The final stop reason is also persisted on the record as `stopReason`.
- `decision.reason` is an **open set** — tolerate unknown values. Known reasons: `targetWeight`,
  `targetVolume` (app-side targets), `profileSkip` (app-issued weight skip), `profileAdvance`
  (firmware-natural step exit), `apiStop` / `appStop` (stop command attributed to a REST client /
  the in-app Stop button), `machineEnded` (GHC stop or natural profile completion —
  indistinguishable), `noScale` (blocked by `blockOnNoScale`), `tareUnconfirmed` (with `blockOnNoScale`, the scale
  never confirmed a zero reading after the tare request, so the shot was aborted and not saved),
  `error` / `disconnected` (abnormal
  endings, `event: "terminal"`), `stoppingBackstop` (post-stop settling window closed by the safety
  timer; never the stop reason itself).
- Coverage: the feed reflects app-side sequencing only. In full gateway mode with the app
  backgrounded no sequencer runs (the feed stays `idle`), and on machines with autonomous
  stop-at-weight (Bengle) the final yield stop is firmware-side and reported as `machineEnded`.

### `connectionStatus.error`

When a BLE operation fails (connect timeout, mid-session disconnect, adapter off, permission denied, scan failure, or profile upload failure), the devices WebSocket emits an update with a structured `connectionStatus.error` object. `null` when no error is active.

```json
{
  "kind": "scaleConnectFailed",
  "severity": "error",
  "timestamp": "2026-04-19T07:49:29.025Z",
  "deviceId": "50:78:7D:1F:AE:E1",
  "deviceName": "Decent Scale",
  "message": "Scale Decent Scale failed to connect.",
  "suggestion": "Wake the scale and try again.",
  "details": {"fbp_code": 1}
}
```

See [`assets/api/websocket_v1.yml`](../assets/api/websocket_v1.yml) for the full `ConnectionError` schema. Full `kind` taxonomy, lifecycle rules, and the recommended skin handling pattern are in [`doc/Skins.md`](Skins.md#handling-connection-errors).

---

## Bundled Plugins

### Settings Plugin (`settings.reaplugin`)

Built-in settings dashboard accessible at `/api/v1/plugins/settings.reaplugin/ui`. Provides a web-based interface for app settings, data and more. Its skin and plugin management controls work while extension management protection is OFF and report that they need a token while it is ON (see **Management actions** below).

**Query parameters:**
- `backName` — customizes the back button label. E.g., `/api/v1/plugins/settings.reaplugin/ui?backName=Extracto` shows "Back to Extracto" instead of "Back to WebUI".

**Sections:** REA Application Settings, Battery & Charging, Machine Settings, Machine Advanced Settings, Calibration, Presence & Sleep, Simulated Devices, Web Interface (skin management + server control), Data Management (export/import/sync), Plugin Management, Feedback, About.

**Self-protection:** The plugin management section prevents disabling or removing `settings.reaplugin` itself (UI guard).

**Management actions:** The page's skin and plugin management buttons call routes that need an `extensions:manage` token only while extension management protection is ON (see [Extension management authorization](#extension-management-authorization)). The page holds no token and does not ask for one, so in compatibility mode the buttons apply, and while protection is ON each refused request shows the page's help text asking for the app's own settings or an API token. That includes the skin and plugin **update check** buttons.

### DYE2 Plugin (`dye2.reaplugin`)

Bean and grinder management. See [`packages/dye2-plugin/README.md`](../packages/dye2-plugin/README.md).

### Scale information

`GET /api/v1/scale/info` returns optional metadata for the currently connected scale, such as opaque `firmwareVersion`. It returns `503` when no scale is connected. Device inventory remains separate: `/api/v1/devices` and `/ws/v1/devices` describe discovery and connection state only and never include connection-scoped scale metadata.
