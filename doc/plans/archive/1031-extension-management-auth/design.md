# 1031 — Scoped authorization for plugin and skin management

Issue: decentespresso/decaid#1031. Follow-ups: #1135 (optional authentication for the rest of
the API), #925 (HTTPS listener), #1029 (remote skin reload).

## Audit (main at b4acf861)

- The API listener (`0.0.0.0:8080`) is the only listener that reaches management code. The API
  docs listener (4001), the skin server and the skin entry redirect serve static content only.
  No WebSocket command installs, enables, configures or removes a plugin or skin.
- `PluginManager._performFetch` opens any URL for a plugin holding `api`, and `host.transport`
  opens any TCP or WebSocket destination, so every plugin can reach the local API. A check on
  the plugin side of `fetch` would therefore be bypassable; only the server can decide.
- Direct mutations: ten plugin routes in `plugins_handler.dart` and eight skin routes in
  `webui_handler.dart` (table below).
- Indirect mutations: `POST /api/v1/settings` with `defaultSkinId` (same effect as
  `PUT /api/v1/webui/skins/default`) or `webUiPath` (restarts the skin server on any path);
  `POST /api/v1/data/import` and a pulling `POST /api/v1/data/sync`, whose `settings.json`
  section sets `defaultSkinId`.
- Audited and left open: `GET` discovery and status routes, `GET /api/v1/plugins/<id>/settings`
  (secure values are already reduced to `isSet`), plugin-defined endpoints
  (`/api/v1/plugins/<id>/<endpoint>`, `/ws/v1/plugins/<id>/<endpoint>`), the app update
  routes, and the key-value store. A key-value namespace equal to a plugin id holds that
  plugin's `host.storage` data; it is plugin data, not installation or configuration, and
  belongs with the general API authentication of #1135.
- Callers of the gated routes: the bundled `settings.reaplugin` page, Streamline
  (`src/modules/api.js`), DYE2's dashboard page, and the dev-loop scenarios. Native settings
  call the services in-process and are unaffected, except backup restore, which posts to
  `/api/v1/data/import` over loopback.

## Design

1. **One policy, one place.** `extension_management_auth.dart` holds
   `extensionManagementRoutes`, an explicit list of method + route pattern, and
   `extensionManagementAuthMiddleware`, added to `buildWebServerHandler` after the account-proxy
   middleware and before body reading and admission. Every listener built from that handler,
   including a future HTTPS one, carries it. It is installed even without a token service, so
   the routes fail closed.
2. **Matching cannot drift from routing.** The middleware classifies a request with a
   `shelf_router` `Router` built from the same patterns the handlers register, fed the same
   `request.url.path` and method. Percent-encoding, case and trailing slashes are therefore
   judged exactly as the real router judges them, and method-specific entries leave plugin
   endpoints with reserved names (`GET …/<id>/enable`) and `OPTIONS` alone.
3. **Scope.** `extensions:manage` joins the existing token primitives
   (`ProxyTokenService`, `ProxyTokenStore`, `AccountTokensController`). A token carries either
   account-proxy scopes or `extensions:manage`, never both by construction of the native
   dialog, and each middleware checks only its own scope.
4. **Responses.** No or malformed bearer, or an unknown or revoked one: 401. A known token
   without the scope: 403. The JSON shape matches the account proxy (`{"error": …}`).
5. **Body-dependent routes use the same decision.** The middleware records its decision in the
   request context; `requireExtensionManagement` and `mayManageExtensions` read it. Settings
   POST refuses `defaultSkinId` and `webUiPath` before applying any key. Import and pull-sync
   skip a differing `defaultSkinId` with a section warning and import the rest, so an ordinary
   backup restore keeps working. A handler reached without the middleware is refused.
6. **Plugins get a principal, not a bearer.** `manage.extensions` is a manifest permission.
   On load `PluginManager` creates an in-memory grant bound to that runtime object and
   generation. `host.localApi(path, options)` sends a path-only request (`/api/v1/…`, no
   scheme, authority or fragment; method, body and content type only) to the shared handler
   in-process, with the grant in the request context. Only in-process code can populate a
   shelf request context, so a network caller cannot present a grant. The middleware asks the
   grant whether it is still current on each request: plugin manager active, same runtime,
   same generation, runtime running, permission still in the manifest. Unload, disable,
   uninstall, reload and disposal end it before `onUnload` runs. Nothing is followed or
   forwarded: a redirect response is returned to the plugin as data.
7. **No bearer reaches plugin code.** There is no token behind `host.localApi`, and a bearer
   that the token service recognises is removed from the request before handlers run, so a
   client that sends its token to a plugin-defined endpoint does not hand it to that plugin.
8. **Approval.** An update that adds any permission already waits for approval. A native
   install (GitHub, ZIP, folder) of a plugin that adds `manage.extensions` now asks first and
   names what the permission allows; the plugin card and the update dialog repeat it. A caller
   that already holds `extensions:manage`, including a plugin with the grant, may approve a
   pending update, its own included. That delegation is the point of the permission and is
   stated in the UI and docs.
9. **Named tokens.** The native tokens section creates either kind and is shown whether or
   not a Decent account is linked. `--extensions-token` registers a process-lifetime token
   for headless and development runs, where there is no native UI or keyring.

## Authorization is decided at dispatch

A request is authorized when the middleware (or a body-dependent handler check) admits it. An
operation admitted while a grant was current runs to completion even if the plugin is unloaded
during a download, exactly as one admitted before a token was revoked does. Re-checking inside the
install and sync services would need an authorization callback threaded through eight service
methods for a window in which the caller could already have done the same thing a moment earlier.
The grant ends for every later request, including one already queued in the JavaScript bridge.

## Bundled settings page

The page served by `settings.reaplugin` does not take a token. Every plugin page is served from
the API origin, so a page from another plugin can open and script it and would see a token typed
there. Its management buttons report what to use instead.

## Known limit

All plugins run in one JavaScript runtime. The grant is bound to a plugin's bridge identity and
generation, which is the isolation every host capability already relies on; it is not a boundary
between co-loaded plugins. A device that loads a `manage.extensions` plugin therefore trusts its
other loaded plugins to the same degree. Separate runtimes per plugin would be the fix and are
outside this change. `doc/Plugins.md` states the limit.

## Non-goals

No global authentication toggle, `api:read`/`api:write` scopes or WebSocket authorization
(#1135). No skin reload API (#1029). No implicit authority for skins: the skin token keeps
only `account:proxy`. HTTP bearer tokens are not confidential on the LAN until #925.

## Protected routes

| Method | Route |
|---|---|
| POST | `/api/v1/plugins/install` |
| POST | `/api/v1/plugins/install/github-release` |
| POST | `/api/v1/plugins/install/github-branch` |
| POST | `/api/v1/plugins/update` |
| POST | `/api/v1/plugins/<id>/settings` |
| PUT | `/api/v1/plugins/<id>/source` |
| POST | `/api/v1/plugins/<id>/enable` |
| POST | `/api/v1/plugins/<id>/disable` |
| POST | `/api/v1/plugins/<id>/update/approve` |
| DELETE | `/api/v1/plugins/<id>` |
| PUT | `/api/v1/webui/skins/default` |
| POST | `/api/v1/webui/skins/install/github-release` |
| POST | `/api/v1/webui/skins/install/github-branch` |
| POST | `/api/v1/webui/skins/install/url` |
| POST | `/api/v1/webui/skins/update` |
| DELETE | `/api/v1/webui/skins/<id>` |
| POST | `/api/v1/webui/server/start` |
| POST | `/api/v1/webui/server/stop` |
| POST | `/api/v1/settings` when the body has `defaultSkinId` or `webUiPath` |
| POST | `/api/v1/data/import`, `/api/v1/data/sync` (pull): `defaultSkinId` only |

## Tests

- `extension_management_auth_test.dart`: the table; missing, malformed, unknown, revoked,
  unscoped and scoped bearers on every route with no call reaching the handler; alias paths;
  `OPTIONS`; bearer removal; fail-closed without a token service.
- A spec test: every operation in `rest_v1.yml` that declares the `extensionsManage` security
  scheme is in the table and the reverse, and every mutating operation under `/plugins` and
  `/webui` is either in the table or in a short reviewed list of open ones.
- Full-pipeline tests over a real socket with the real handlers: an `api` plugin using
  `fetch`, TCP and WebSocket against loopback, hostname and LAN-address aliases and through a
  redirect is refused; a `manage.extensions` plugin succeeds through `host.localApi`; unload,
  disable, reload and removal end the grant; a plugin cannot approve its own escalation
  before it holds the permission.
- Token lifecycle: persistence across restart, revocation, scope independence in both
  directions.
