# #1191 round-two security review: browser origins and settings-read scope

Operator-directed remediation of PR #1193 after independent review. It supersedes two earlier
decisions: that permissive browser exposure could stay while CORS was untouched, and that the
security setting could be read from storage on every request. The #1191 compatibility mode stays;
what changes is its interaction with unrelated browser origins and its cost for unrelated traffic.

## Why

Runtime discovery on an existing simulated device (authorized M50Mini, no settings or extensions
changed) found `GET /api/v1/webui/server/status` serving an active skin on port 25707 with the
stable entry point on 3000 answering `307` to it. The skin port is dynamic per identity and per
fallback run, so any origin policy written as "all ports 3000" or "localhost only" would be wrong in
both directions: it would break the installed skin and it would trust a stored or guessed port that
is no longer serving. The previous design also read the persisted security setting in middleware
before classifying the route, which serialized every API request, including machine state and
account polling, behind the settings store.

## Decisions

- **One live origin source.** `ExtensionManagementBrowserOrigins` composes the literal loopback
  hosts, the numeric addresses currently on local interfaces, the live skin page port
  (`WebUIService.browserOriginPorts`, which follows the active server, a skin switch, a restart and
  a temporary fallback) and the actual API listener port, all read through callbacks on every
  request. The addresses are enumerated per classification by
  `WebUIService.currentBrowserOriginAddresses()`: current interfaces only, no cache, available
  before any skin has been served, and a retired address stops being trusted without a serve. An
  enumeration failure fails closed for numeric origins, and there is no stale WiFi fallback.
  Nothing is taken from the request, so `Host`, `Referer`, `X-Forwarded-*`, `Forwarded` and
  DNS names cannot widen the set and DNS rebinding gains nothing.
- **A loopback origin needs socket provenance.** A literal `localhost`, `127.0.0.1` or `::1`
  origin is trusted only when the request's TCP socket peer is loopback or exactly one of this
  device's current interface addresses. A browser page on another machine that opens its own
  `http://localhost:<port>` presents a non-loopback peer, so it is refused in both modes even with
  a valid bearer; an embedded WebView or another process on the device itself still passes. A
  missing, wrong-typed or unreadable peer fails closed, and the decision never consults `Host`,
  `Referer`, forwarding headers, DNS or subnet membership.
- **Refuse before the handler, in both modes.** Untrusted actual requests to the 18 management
  mutations are refused `403` by the outermost middleware, ahead of general CORS, the account-proxy
  CORS rule, authentication and body reading. The three body-gated routes are decided in the handler
  (`requireTrustedBrowserOrigin`): import always and before the archive is read, a settings body
  with a gated key, and a pull/two-way sync that includes `settings` before any network request or
  write. Untrusted preflights for a guarded method on a guarded path are refused with no
  `access-control-*` headers; a preflight without a usable `Access-Control-Request-Method` is
  refused conservatively because the method is unknown; read-only methods on shared paths and
  plugin-defined routes keep the general preflight answer. The three body-gated paths are refused at
  preflight as well, before a body they do not carry is known, so a browser page on an untrusted
  origin cannot send a safe settings body or a `push` sync as an ordinary request even though the
  handler admits the actual one. Handler-level refusals are marked and stripped of
  `access-control-*`, so a mutation is never "protected" only by withholding a CORS header.
- **Origin is not authentication.** A non-browser client can omit or forge it. Originless LAN
  compatibility (Home Assistant, MCP), `host.localApi` in process and native app code are untouched,
  and protected mode plus network restriction remain the answer for a shared deployment. Plain HTTP
  still exposes the bearer; #925, #1135 and #1192 are separate.
- **Classify before storage.** The mode lives in one lazy, memoized per-request snapshot shared by
  the route gate and the handler checks. Only the 18 management routes, a settings body with a gated
  key, an import and a settings-bearing pull resolve it; ordinary settings, `automaticUpdateCheck:
  false`, a push, a non-settings sync, machine/state/account/read-only/plugin routes never do. An
  active grant short-circuits before the read, an origin refusal short-circuits before it, and a
  completed native toggle decides the next request in both directions.
- **Load settings before the API starts.** `loadSettingsBeforeWebServer` in `lib/main.dart` installs
  the simulate listener, awaits `loadSettings()` and only then starts the web server, and a failing
  settings load means the API is never started while the original web-server port-conflict and
  binderror handling stays in place. This corrects the order rather than preserving it: the API used
  to start first, and the earlier round-two claim that the existing order was already correct was
  wrong. The resume observer refresh is unchanged.

## Consequences

- A skin or plugin page that is served from the device's live port keeps working in both modes; a
  page reached through a stale port never runs from that port, because the entry point and the
  inactive aliases only redirect.
- An import is refused whole from an untrusted browser even when it carries no gated key. That is
  deliberate: the keys are unknown until the archive is parsed, and the review preferred a
  conservative refusal over parsing attacker-supplied archives on an untrusted browser's behalf.
- Safe settings writes from an untrusted origin still apply and still carry the pre-existing CORS
  echo, so the refusal is not a general CORS tightening. Their preflight is refused, though, so a
  browser page on that origin cannot send them as JSON requests, and the same applies to a `push`
  sync. That is the price of deciding on a body a preflight does not have, and it is documented as a
  limit rather than presented as part of the mutation boundary.
- Unrelated routes are no longer serialized behind the settings store, and an unreadable store still
  fails closed for the requests that depend on the mode without blocking the rest.
