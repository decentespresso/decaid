# Built-in browser compatibility design

## Diagnosis

Real-pipeline tests reproduce docs-port 4001 preflight/write failures and the delivered bundled settings page's management writes under a DNS alias. Numeric settings writes work; automaticUpdateCheck=false is intentionally exempt. Docs port is absent from the existing numeric-origin allowlist, while DNS aliases are intentionally rejected to prevent rebinding.

## Approved boundary

The operator approved redirects after the parent reviewed the red evidence. Trust the docs port only after its listener successfully binds. Canonicalize DNS-alias entry only for built-in API docs viewer GET and bundled settings.reaplugin UI GET to a numeric local address and the bound listener port. Do not trust the alias for mutation. Do not redirect global API routes or third-party plugin pages. Do not forward secrets in queries, authority, or headers into the redirect target. Dart HttpConnectionInfo provides the peer, not the accepted socket's local address. Use the listener's concrete bound address where available; otherwise require exactly one usable current interface address of the normalized peer family. Ambiguous multi-interface entry returns 403, with direct numeric access as the workaround. Never guess from subnets or prefer the first candidate. Missing reliable socket provenance fails closed. Numeric entry remains on the existing origin policy.

SOP-isolated page capabilities alone were rejected as an answer to DNS rebinding: an attacker-controlled alias can read a same-origin capability after rebind. Explicit alias configuration would add a trust-policy surface unnecessarily.

## Verification goals

Prove original alias entry, canonical page delivery and actual built-in browser request construction through successful compatibility mutation. Prove direct alias/hostile/null/stale/forged origins remain rejected, scoped credentials remain enforced, and originless curl still works. Cover address families, loopback and missing provenance, no secret leakage or unrelated route interception. Run focused tests, formatting, analysis, full tests and isolated simulated smoke, then independent two-model security review. The initial lane excluded physical devices and publication until separate operator approval. The operator subsequently approved verification on an M50Mini using a distinct test application package, followed by a PR only after verification. The regular application's APK and persisted data must remain unchanged.

## Browser parser compatibility

Real Chromium verification exposed a gap in the Node VM harness: it reads only server blocks, whereas the shipped js-yaml 5 parser reads the entire spec. Three multiline flow sequences closed at their mapping key's indentation, so parsing failed and the REST viewer silently fell back to Swagger's original `localhost` target. Reformat those sequences as block lists without changing their values. A focused YAML indentation regression guards this known parser incompatibility; actual browser navigation and Execute requests remain the end-to-end check.
