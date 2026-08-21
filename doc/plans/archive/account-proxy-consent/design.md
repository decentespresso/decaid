# Account proxy consent gate

## Goal

Require a remembered native allow or deny decision before any skin, plugin, or
named API client can use the linked Decent account.

## Design

- Keep bearer-token scope checks in `proxyAuthMiddleware`.
- Enforce consent in `DecentProxyService`, the shared path used by HTTP clients
  and `host.decentProxy` plugins, before any upstream request.
- Bind each served skin token to `skin:<installed skin id>`. For an unregistered
  served path, use `skin:path:<sha256(normalized path)>`. If the served path
  cannot be identified, do not inject an account-proxy token.
- Give every served skin generation a fresh token and browser origin. Port 3000
  remains a no-store redirect to the active origin, so existing entry links
  continue to work without allowing stale pages to read the next token. Revoke
  the token when the skin server stops.
- Persist explicit allow and deny decisions in the existing credential store.
  A timeout or unavailable navigator denies without persistence.
- Coalesce concurrent requests for one caller onto one prompt.
- A 30-second native dialog timeout defaults to deny. The dialog cannot be
  dismissed by tapping outside it, and each timeout removes its own route so
  concurrent prompts cannot dismiss one another.
- CLI trust keys are session-only and evaluated before persisted decisions.

## Verification

1. Unit-test storage round trips, immutable caller identity, token and origin
   rotation, remembered decisions, coalescing, concurrent timeout behavior,
   headless denial, and CLI trust.
2. Prove the shared proxy service neither forwards nor exposes credentials when
   consent is denied, including the plugin caller path.
3. Widget-test allow, deny, timeout, and rendering over the active full-screen
   route.
4. Update REST and plugin documentation, format, analyze, and run the full test
   suite.
