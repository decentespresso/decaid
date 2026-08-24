# Plan: API-client token management (#297)

**Branch:** `feat/account-proxy-tokens-297` (off `main`) · **Completion:** PR, maintainer merges.

## Goal

Let users mint, list, and revoke named **API-client tokens** so non-skin clients
(scripts, external tools) can call the already-shipped read proxy
(`GET /api/v1/account/proxy/...`) without ever seeing credentials. Today the read
proxy from #296 is reachable **only** by skins (skin token) and plugins (Dart
bridge) — no external client can use it at all. #297 is the keystone that unlocks
real external usage.

Per the session decision, we also lay the **write-scope** capability so #355
(write proxy) becomes a real, testable feature once it merges — see the
[write-scope decision](#write-scope-decision) below (carries one open question for you).

## Scope (from issue #297)

- Persist API-client tokens (`{id, token, label, scopes, createdAt}`) across restarts.
- Load persisted tokens into `ProxyTokenService` at startup, alongside the skin token.
- Settings UI: create a named token, show it **once** to copy, list existing, revoke.

**Locked (issue):** skin token stays in-memory (never persisted); tokens are
bearer secrets shown once — store only what's needed to validate + display the label.

## Current state (verified in `main`)

- `ProxyTokenService` (`lib/src/services/account/proxy_token_service.dart`): in-memory
  `Map<token, ProxyCaller>`, `registerToken` / `revokeToken` / `validate`, only
  `scopeAccountProxy` ('account:proxy'). **No persistence, no startup load.**
- `main.dart:406` constructs `ProxyTokenService()` unconditionally; passed to the
  webserver at `:484`. Auth already enforced by `proxyAuthMiddleware` on
  `/api/v1/account/proxy/*` — no API/middleware change needed for read tokens.
- Secure persistence pattern already exists: `CredentialStore` abstraction +
  `SecureCredentialStore` (FlutterSecureStorage) — `credential_store.dart`.
- Settings sub-pages: `ListTile` → `Navigator.push(MaterialPageRoute(...))`
  (`settings_view.dart`). Decent account UI lives in `lib/src/account/account_page.dart`
  + `decent_login_form.dart` — the natural home for an "API tokens" entry.

## Architecture

### 1. Persistence — `ProxyTokenStore`

New abstraction mirroring `CredentialStore` (testable, swappable):

```
abstract class ProxyTokenStore {
  Future<List<PersistedProxyToken>> load();
  Future<void> save(List<PersistedProxyToken> tokens);
}
class SecureProxyTokenStore implements ProxyTokenStore  // FlutterSecureStorage, one JSON-list key
class InMemoryProxyTokenStore implements ProxyTokenStore // tests + headless fallback
```

`PersistedProxyToken = {id, token, label, scopes:Set<String>, createdAt}`. The
non-secret UUID is the immutable caller identity; the label is presentation-only.
Stored as a JSON list under a single secure-storage key. We persist the **raw token**
(same trust level as the account password already in secure storage) because
`validate()` is an exact-match lookup — storing only a hash would require changing
the validate path. Bearer tokens shown once; this matches the issue's "store only
what's needed to validate + display the label."

**Headless/`--no-account` caveat:** secure storage (libsecret) blocks on headless
Linux — the same reason `--no-account` exists. When the proxy is disabled there, the
store is best-effort: if unavailable, tokens stay in-memory only (proxy is off
anyway, so nothing is lost). No new hard dependency on a desktop session.

### 2. `ProxyTokenService` changes (minimal, surgical)

- Add `static const scopeAccountProxyWrite = 'account:proxy:write';` (see decision).
- `registerToken` already exists — reused as-is for loading + new tokens.
- Add a small `createToken({label, scopes})` helper that generates a token
  (reusing the existing `Random.secure` 32-byte base64Url generator), registers it,
  and returns it for one-time display. Keep generation in one place.
- Service stays persistence-agnostic — a separate **loader/coordinator** wires the
  store to the service (constructor injection, no service locator).

### 3. Startup load (`main.dart`)

After constructing `ProxyTokenService` (~`:406`), load persisted tokens from
`SecureProxyTokenStore` and `registerToken` each — before the webserver starts
(`:484`). Skin token behaviour unchanged.

### 4. Settings UI

New `AccountTokensPage` (`lib/src/settings/account_tokens_page.dart`), reached via a
`ListTile` in `account_page.dart` ("API access tokens"):
- **Create:** name field → mint → show the token once in a copyable `ShadDialog`
  (reuse the `data_management_page.dart` dialog pattern) with a clear "copy now,
  won't be shown again" warning.
- **List:** label + createdAt + scopes; no token value (it's gone after creation).
- **Revoke:** confirm → `revokeToken` + persist.

A thin controller/service owns create/list/revoke + persistence so the widget stays
dumb and unit-testable.

## <a id="write-scope-decision"></a>Write-scope decision (needs your call)

#355 (write proxy, still a draft) introduces `account:proxy:write` enforcement
(middleware method→scope mapping + write routes) **and** currently defines the same
`scopeAccountProxyWrite` const on its branch. Two couplings to resolve:

1. **Const ownership:** I propose #297 owns `scopeAccountProxyWrite` in
   `ProxyTokenService` (the natural home for scope constants). #355 then drops its
   duplicate on rebase — a trivial one-line conflict. *(Alternative: #297 doesn't
   touch the const and depends on #355 merging first — but you chose #297 first.)*

2. **User-facing write toggle — ship now or with #355?** A "grant write access"
   checkbox in the create dialog is one line of UI, but a write-scoped token does
   **nothing useful until #355 merges** (writes 404 with no routes; the scope is
   inert). Options:
   - **(a) Plumb the capability, hide the toggle** — `createToken(scopes:)` accepts
     write, the const exists, persistence handles it, but the UI offers read-only for
     now. #355 (or a 1-line follow-up) flips the toggle visible. *No dead UX.* ← my recommendation
   - **(b) Show the toggle now** with a "needs write proxy (#355)" note. Honors
     "add write minting while there" literally, at the cost of a temporarily-inert option.

This is the one open product decision; everything else is mechanical.

## Files

**New:** `lib/src/services/account/proxy_token_store.dart`,
`lib/src/settings/account_tokens_page.dart`, a small tokens controller,
`.agents/skills/decent-app/scenarios/account-proxy-tokens.md`.
**Edit:** `proxy_token_service.dart` (createToken + write const),
`main.dart` (startup load), `account_page.dart` (entry ListTile).
**Tests:** `test/services/account/proxy_token_store_test.dart` (round-trip + load),
`test/services/account/proxy_token_service_test.dart` (createToken/scopes),
a widget test for the page.

## Build sequence (TDD, outside-in)

1. **Unit — store:** persistence round-trip + load-into-registry on startup → make pass.
2. **Unit — service:** `createToken` mints + registers with given scopes; revoke removes.
3. **Wire startup** load in `main.dart`; verify persisted token authorizes a proxy GET.
4. **Widget — UI:** create/list/revoke against a fake controller.
5. **E2E scenario:** _not written._ The token-management surface is login-gated UI
   (tokens are useless without a linked account), and pure-sim has no account — so
   there's no runnable-in-sim curl recipe like #353/#354 had. Verification rests on
   the unit + widget tests above (controller→service→store create/persist/load/revoke,
   and the settings UI create→show-once→list→revoke). Decision recorded with the maintainer.
6. `flutter analyze` + full `flutter test` → rebase → push → ready.

## Acceptance criteria (issue #297)

- [ ] User creates a named token in settings and can copy it (shown once).
- [ ] Token survives app restart and authorizes `GET /api/v1/account/proxy/...`.
- [ ] Revoking a token makes it return 401.
- [ ] Skin-token behaviour unchanged.

## Risks / notes

- **Secret-in-logs:** never log token values; audit `proxyAuthMiddleware` + service
  logs use caller id only (already the case).
- **Secure-store availability** on headless — handled by best-effort fallback above.
- **#355 coupling** — the two const-ownership / toggle decisions above; otherwise independent.
