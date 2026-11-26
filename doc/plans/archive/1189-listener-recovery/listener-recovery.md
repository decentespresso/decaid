# #1189 listener recovery design

Accepted contract: issue #1189, 2026-11-26. L3: application lifecycle, required API availability and authenticated embedded skin behavior.

## Ownership and recovery

API handler construction runs once. ApiListener owns the retained handler and separately binds its listener; foreground recovery does not recreate controllers, plugins, subscriptions or authentication middleware. Actual bounded HTTP probes check the API info route, active skin and stable entry redirect. Recovery only rebinds unhealthy required listeners through a bounded single-flight coordinator.

WebUI recovery retains the serving handler, skin identity and assigned port. Lifecycle versions fence recovery against explicit stops and newer selections. No active skin or an intentional stop remains stopped. Existing aliases, origin isolation and token providers retain their contracts. Each actual API, skin, entry, and alias binding receives a fresh cryptographically random identity, exposed as the additive `x-decaid-listener-id` marker on ordinary HTTP responses; hijacked WebSocket handshakes do not carry it. Health probes require the exact retained marker in addition to their existing response checks. The marker is not a credential, client requirement, CORS-exposed value, or defense against a malicious local proxy or replay after observation. No machine-connection gating, background keep-alive or dependency on #1110 is introduced.

SkinView initial creation, recreation and resume wait for listener readiness. Failed recovery exposes a persistent retry action. Native WebView timer ownership is independent of readiness tokens: invalidating asynchronous navigation must not invalidate ownership of already-acquired process-global native timer debt. Tests caught the earlier coupling as 22 ordering regressions; separate controller ownership restored the existing guarantees.

## Verification limits

Deterministic tests close actual listening sockets while retaining non-null server references, then assert HTTP/WebSocket recovery and port stability. They do not establish that iOS reclaims sockets during suspension, that background machine disconnection is recovered, or that native error/retry behavior is correct. Physical iOS extended suspension and machine connection transitions require authorized operator validation. App lifecycle integration with #1110 should receive combined review without adding an implementation dependency. Shared main/startup wiring with #1190 requires integration inspection.
