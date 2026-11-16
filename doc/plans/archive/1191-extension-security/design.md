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

1. **One policy toggle, read per request.** `SettingsKeys.requireExtensionManagementAuthorization`
   persists the mode through `SettingsService`. `SettingsController.currentRequireExtensionManagementAuthorization()`
   reads it fresh for every API request through the `Future<bool> Function()?`
   `requireExtensionManagementAuthorization` callback that `buildWebServerHandler` hands to
   `extensionManagementAuthMiddleware`, and again when the app resumes. An omitted callback and a
   throwing storage read both resolve to **protected**; the stored key resolves to **OFF** when
   absent. The opposite defaults are deliberate: an upgrade from a build without the key must run
   in compatibility mode, and a storage fault must never downgrade security.
2. **Missing key is OFF, never inferred.** The stored value is the only input. A device that still
   holds `extensions:manage` tokens is not treated as protected, so the upgrade ships
   compatibility mode and says so prominently in the native Security screen, `doc/RELEASE.md` and
   the App Store release notes.
3. **One decision per request, shared with handlers.** The middleware stores the whole
   `ExtensionManagementAuthorization` snapshot in the shelf request context;
   `requireExtensionManagement` and `mayManageExtensions` read that snapshot. A route gate and a
   body-dependent handler gate can never disagree, a settings write that flips the toggle cannot
   land between them, and handlers never read storage. On OFF, every table match and every
   body-dependent check is authorized without consulting a credential, while an ended in-process
   plugin grant is still denied.
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
7. **CORS, origin and input validation are preserved, not widened.** `buildWebServerHandler` keeps
   the pre-existing `shelf_cors_headers` policy: any request carrying an `Origin` gets that origin
   echoed, with `Access-Control-Allow-Credentials: true`, and `OPTIONS` keeps its 200 preflight —
   on admitted and refused responses alike, in both modes. The account proxy keeps its stricter
   rule on top (`accountProxyCorsMiddleware` strips ACAO outside its allowlist). Consequence, and
   the reason the risk text in `doc/Api.md` says it this way: while protection is OFF, a browser
   page on any origin that can reach the device can also read the management responses. The switch
   changes authorization only. Tightening CORS is a separate change with its own compatibility
   analysis.
8. **Authorization is not confidentiality.** The public contract states that :8080 is plain HTTP,
   so a bearer is readable on a hostile LAN; #925 is the HTTPS listener and #1135 the separate
   optional full REST/WS authentication. Neither is part of this issue.
9. **The spec models the credential as optional.** Each of the 18 operations declares
   `security: [{}, {extensionsManage: []}]`, so a generated client does not demand a token
   unconditionally, and every description (operation, 401, 403, `ReaSettingsRequest.webUiPath`,
   `defaultSkinId`, `automaticUpdateCheck`, import, sync, and the security scheme itself) states
   the requirement as conditional on protection being ON. `test/api/extension_management_spec_test.dart`
   pins the alternatives, the exact table, the conditional wording and the absence of the retired
   tokenless exception.
10. **The native UX tells the truth.** `Settings → Security` shows the mode ("Compatibility mode
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
  18 routes, one resolution per request.
- `test/webserver/extension_management_pipeline_test.dart` — real sockets (IPv4, `localhost`,
  IPv6 `::1` on a second listener, LAN-bound peer with a bound client source), per-route
  observable handler work in both modes, forged headers, #1187 with a real plugin loader.
- `test/plugins/plugin_extension_management_bypass_test.dart` — plugin transports and the
  `manage.extensions` grant in both modes.
- `test/webserver/extension_management_settings_import_test.dart`,
  `test/webserver/extension_management_native_only_test.dart`,
  `test/plugins/plugin_local_api_bridge_test.dart` — body-dependent gates and the native-only
  tamper surfaces.
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
