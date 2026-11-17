# 1191 — Extension management: open by default, opt-in native protection

Issue: decentespresso/decaid#1191 (milestone 0.9.3). Companion operations doc: #1192 (café
provisioning and hardening guide, forthcoming). Superseded direction: #1162 / #1164 / #1184.
Non-goals: general REST/WS auth (#1135), new HTTPS listener (#925), native per-operation
confirmation coordinator (#1164), new skin switch REST APIs, changes to Decent account
authentication.

## Context

PR #1142 (issue #1031) turned the plugin and skin management API into an
`extensions:manage`-gated surface for everybody: tokenless loopback and LAN callers, skins, and
plugins without the permission all got 401/403. The one exception, #1163, admitted tokenless
loopback calls to the two update routes while `automaticUpdateCheck` was on.

That broke existing integrators: Home Assistant, MCP clients, Streamline, DYE2 (#1187) and the
bundled settings plugin. #1191 restores the pre-#1031 contract as the default and moves the
#1031 policy behind a native, persisted, opt-in `Settings → Security` switch. It does not revert
PR #1142: the scoped token, the `manage.extensions` grant, the native token lifecycle and the
separate account-proxy scopes all stay, they stop being the default for extension management.

## Design

1. **One policy toggle, read per relevant request.** `SettingsKeys.requireExtensionManagementAuthorization`
   persists the mode through `SettingsService`. `SettingsController.currentRequireExtensionManagementAuthorization()`
   resolves it for every API request whose outcome can depend on it, through the `Future<bool> Function()?`
   `requireExtensionManagementAuthorization` callback that `buildWebServerHandler` hands to
   `extensionManagementAuthMiddleware`, and again when the app resumes. The read is lazy and memoized per
   request, so unrelated traffic never touches storage (see point 3). Settings load before the API
   listener starts: `loadSettingsBeforeWebServer` in `lib/main.dart` installs the simulate listener,
   awaits `loadSettings()` and only then starts the web server, and a failing settings load now means
   the API is never started. That ordering was corrected in round two; the API previously started
   first and the earlier claim that the original order was already correct was wrong. An omitted
   callback and a throwing storage read both resolve to **protected**; the stored key resolves to
   **OFF** when absent. The opposite defaults are deliberate: an upgrade from a build without the key must run
   in compatibility mode, and a storage fault must never downgrade security.
2. **Missing key is OFF, never inferred.** The stored value is the only input. A device that still
   holds `extensions:manage` tokens is not treated as protected, so the upgrade ships
   compatibility mode and says so prominently in the native Security screen, `doc/RELEASE.md` and
   the App Store release notes.
3. **One decision per request, shared with handlers.** The middleware stores the whole
   `ExtensionManagementAuthorization` snapshot in the shelf request context;
   `requireExtensionManagement` and `mayManageExtensions` read that snapshot. A route gate and a
   body-dependent handler gate can never disagree, a settings write that flips the toggle cannot
   land between them, and handlers never read storage. The snapshot holds a single memoized future,
   so the stored read happens at most once per request and only when the outcome can depend on it:
   the 18 management routes, a `POST /api/v1/settings` body with a gated key, an import, and a
   pull/two-way sync that includes `settings`. Machine, state, polling, account, read-only and
   plugin-defined routes, ordinary settings bodies, `automaticUpdateCheck: false` and a push or a
   non-settings sync never read it, so they no longer queue behind the settings store. An active
   in-process grant is decided before the read starts, and an origin refusal short-circuits before
   it. Import resolves it once after its bounded stream, because which keys are gated is only known
   after parsing the archive. On OFF, every table match and every body-dependent check is
   authorized without consulting a credential, while an ended in-process plugin grant is still
   denied.
4. **The policy stays an explicit table.** The 18 method + `shelf_router` pattern pairs in
   `extensionManagementRoutes`, plus the named body-dependent keys (`webUiPath`, a changed
   `defaultSkinId`, `automaticUpdateCheck` turned on, and the same two keys inside import and
   pull/two-way sync). No path prefix, no method-only gate, no reclassification of read-only or
   plugin-defined routes. Matching still builds a real `Router`, so encoding, case and trailing
   slashes are judged exactly as the handlers judge them.
5. **Native-only setting.** `POST /api/v1/settings` keeps its unknown-key behaviour (ignored, 200)
   and never writes the key; `SettingsExportSection` neither exports nor imports it, so a backup,
   a `pull`/`two_way` sync and a pushed archive cannot carry it; `extensionManagementSettingsKeys`
   stays `{defaultSkinId, automaticUpdateCheck}` so `host.localApi`, the plugin settings API and
   the KV store cannot reach it; `GET /api/v1/settings` does not expose it. The only writer is
   `lib/src/settings/security_page.dart`. Token creation and revocation stay reachable in the
   native Account page whether the switch is on or off.
6. **The #1163 loopback update exception retires.** In compatibility mode the two manual update
   routes need nothing at all: no credential, no loopback peer, no `automaticUpdateCheck`
   dependency, no 30 s throttle. In protected mode they are ordinary protected routes.
   `_TokenlessUpdateCheckPolicy`, its throttle, its per-route CORS echo and the middleware's
   `automaticUpdateCheckEnabled`/`localOrigins`/`clock` parameters were deleted rather than kept
   for protected mode. Scheduled/background checks still follow `automaticUpdateCheck` inside the
   update services.
7. **A browser origin is checked before the credential, in both modes.**
   `extensionManagementBrowserOriginMiddleware` is the outermost middleware in
   `buildWebServerHandler`, ahead of the account-proxy CORS rule, the general `shelf_cors_headers`
   echo, authentication and body reading. `ExtensionManagementBrowserOrigins` classifies the
   request `Origin` against a source read live from the running services: scheme `http`, a literal
   local host (`localhost`, `127.0.0.1`, `::1` or a numeric local-interface address) and a port
   that is either the live skin page port (`WebUIService.browserOriginPorts`, which follows the
   active server, a switch, a restart and dynamic allocation) or the actual API listener port.
   Everything else is untrusted, including `Origin: null`, `https`, a hostname that resolves to the
   device, another device's address and a retired port; `Host`, `Referer`, forwarding headers and
   DNS are never consulted, which closes the DNS-rebinding widening.

   A literal loopback host is trusted only with socket peer provenance. `classify` reads
   `shelf.io.connection_info` and requires `remoteAddress` to be loopback or equal to an address
   from the same fresh interface listing; a missing, wrong-typed or throwing peer fails closed, and
   a non-loopback peer that is not one of this device's current addresses is refused. A browser
   page on another machine that opens `http://localhost:<port>` is therefore refused even with a
   valid bearer, while an embedded WebView or another process on the device keeps working. The
   address listing is `WebUIService.currentBrowserOriginAddresses()`: live interface enumeration per
   classification, no cache, no dependency on a skin being served, no stale WiFi fallback, and an
   enumeration failure is a fail-closed refusal for numeric origins. `Host`, `Referer`, `Forwarded`,
   `X-Forwarded-*` and DNS remain unused, so the only provenance is the socket.

   Untrusted actual requests to the 18 routes are refused `403` before the handler. The three
   body-gated routes are decided in the handler by `requireTrustedBrowserOrigin`: import always and
   before the archive is read, a settings body that contains a gated key, and a pull/two-way sync
   that includes `settings`, before any network request or write. Safe settings bodies, a push and
   a pull that excludes `settings` are not refused. Untrusted preflights for a guarded method on a
   guarded path are refused `403` with no `access-control-*` headers before general CORS can answer
   them, while preflights for read-only methods on shared paths and for plugin-defined routes keep
   the general answer; a preflight without a usable `Access-Control-Request-Method` is refused
   conservatively because the method is unknown. The three body-gated paths are guarded at preflight
   too, before a body they do not carry is known, so a browser page on an untrusted origin cannot
   send a safe settings body or a `push` sync as an ordinary request even though the handler would
   admit the actual one; `doc/Api.md`, the spec and the scenario state that as a deliberate limit.
   Handler-level refusals are marked in the response context and stripped of `access-control-*` by
   the outer middleware. Withholding a CORS header after a mutation is never treated as the
   protection.

   The check is a browser boundary, not authentication: a non-browser client can omit or forge
   `Origin`, so originless LAN clients, Home Assistant, MCP and `host.localApi` (in-process, no
   `Origin`) keep the compatibility contract, and protected mode plus network restriction remain
   the controls for a shared deployment. Outside these refusals the pre-existing general CORS echo
   is unchanged, so a browser page on any origin that can reach the device can still read other API
   responses.
8. **The spec and public docs state the origin contract.** `info.description`,
   the `extensionsManage` scheme and every protected operation's `403` describe the refusal, and
   `doc/Api.md` (Browser origins), `doc/Plugins.md` and `doc/Skins.md` spell out the trusted and
   rejected forms, the socket-peer condition for a loopback origin, the affected routes and
   preflights, the conservative preflight refusal for the three body-gated paths, and the fact that
   Origin is not authentication. The import `403` in the spec states that an unauthorized protected
   import skips a gated key with a warning while an authorized one applies it.
   `test/webserver/extension_management_pipeline_test.dart`,
   `extension_management_auth_test.dart`, `extension_management_settings_import_test.dart`,
   `account_proxy_cors_middleware_test.dart` and `webui_stable_origin_test.dart` pin it over real
   sockets and live origin sources.
9. **Authorization is not confidentiality.** The public contract states that :8080 is plain HTTP,
   so a bearer is readable on a hostile LAN; #925 is the HTTPS listener and #1135 the separate
   optional full REST/WS authentication. Neither is part of this issue.
10. **The spec models the credential as optional.** Each of the 18 operations declares
   `security: [{}, {extensionsManage: []}]`, so a generated client does not demand a token
   unconditionally, and every description (operation, 401, 403, `ReaSettingsRequest.webUiPath`,
   `defaultSkinId`, `automaticUpdateCheck`, import, sync, and the security scheme itself) states
   the requirement as conditional on protection being ON. `test/api/extension_management_spec_test.dart`
   pins the alternatives, the exact table, the conditional wording and the absence of the retired
   tokenless exception.
11. **The native UX tells the truth.** `Settings → Security` shows the mode ("Compatibility mode
    (OFF)" with the "Anyone can manage extensions" warning and the upgrade notice, or "Protected
    mode (ON)" with what is covered), the switch labelled "Require authorization for extension
    management", the API-token entry that is the only way to create a token, and a link to the
    forthcoming #1192 café hardening guide (issue URL, labelled future). The OFF warning names
    installs, permission escalation and settings changes by anyone who can reach the API on the
    network, and says compatibility is a tradeoff rather than a guarantee.

## What the two modes mean for a caller

Compatibility mode is the pre-#1031 contract for tokenless loopback and LAN clients, skins and
plugins using `fetch`/`host.transport`, including a client that still sends an expired or
revoked token. Protected mode applies the #1031 checks to the same table with no loopback,
update or scheduling exception. Business validation, manifest checks, pending-update rules,
rollback, secure-value handling and request validation are identical in both modes, and the
account proxy keeps its own scopes in both.

## Tests

- `test/webserver/extension_management_compatibility_test.dart` — the default-mode contract.
- `test/webserver/extension_management_auth_test.dart` — ON/OFF/read-error/absent-callback for all
  18 routes, one lazy resolution per request, the origin classifier (trusted, rejected, live
  port/address source), and the guard's preflight and handler-level behaviour.
- `test/webserver/extension_management_pipeline_test.dart` — real sockets (IPv4, `localhost`,
  IPv6 `::1` on a second listener, LAN-bound peer with a bound client source), per-route
  observable handler work in both modes, forged `Host`/`Referer`/forwarding headers, the full
  untrusted/trusted origin matrix with live skin-port moves, refusal and pass-through preflights,
  #1187 with a real plugin loader.
- `test/plugins/plugin_extension_management_bypass_test.dart` — plugin transports and the
  `manage.extensions` grant in both modes, including that `fetch` and `host.localApi` are unaffected
  by the origin guard.
- `test/webserver/extension_management_settings_import_test.dart`,
  `test/webserver/extension_management_native_only_test.dart`,
  `test/plugins/plugin_local_api_bridge_test.dart` — body-dependent gates, the native-only tamper
  surfaces, origin refusals for settings/import/sync before any side effect, and the
  Completer-controlled read-count and toggle-ordering checks.
- `test/webserver/account_proxy_cors_middleware_test.dart`,
  `test/webui_support/webui_stable_origin_test.dart` — the management origin policy beside the
  account-proxy CORS rule, and the live port/address source over the real skin server.
- `test/settings/extension_security_setting_test.dart`, `test/settings/security_page_test.dart`,
  `test/app_lifecycle_observer_test.dart` — persistence, fail-closed read, serialized
  refresh/toggle, resume, and the Security screen.
- `test/api/extension_management_spec_test.dart` — spec/table agreement and the optional
  credential alternative.

## Risks

- Default-off is a real security downgrade for upgrader devices; the native UX, release notes and
  the #1192 guide are the mitigations and are part of the acceptance criteria, not decoration.
- Compatibility mode must not become a blanket gate: the policy stays an explicit table plus the
  named body-dependent keys, checked per request.
- Deleting the #1163 exception is safe only because both modes cover the two update routes
  (compatibility: open; protected: credential required). Keeping it in protected mode would be
  the bug.
- The origin guard is a browser boundary, not authentication. A direct LAN client can omit or forge
  `Origin`, so originless LAN exposure persists by design in compatibility mode, and the residual
  exposure is stated in `doc/Api.md` rather than implied to be closed.
- The body-gated routes are decided by body content, not by the path: an import is refused whole
  because the archive's keys are unknown until parsing, while a pull that excludes `settings` and a
  push are allowed from any origin. A preflight carries no body at all, so the three body-gated
  paths are refused at preflight before their relevance is known; a browser page on an untrusted
  origin therefore cannot send a safe settings body or a push, even though the actual request is
  admitted. Both are stated as deliberate limits. This is an extension-management boundary, not a
  general data-import one, and the docs say so.
- The trusted port is the live one. A skins redirect (`3000`) or retired alias is trusted only if it
  happens to be serving, which keeps a stale bookmark or a rebound name from widening the set.
