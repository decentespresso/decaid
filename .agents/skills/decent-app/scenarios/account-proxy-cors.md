# Scenario: Account-proxy CORS pinned to skin origin

Verifies the defense-in-depth CORS hardening (#301): on `/api/v1/account/proxy/*`
the `Access-Control-Allow-Origin` is **pinned** to the active skin origin(s)
(loopback + the device LAN IP, on the current per-generation skin port) instead
of the global permissive value. Non-proxy API paths keep their existing
permissive CORS.

The CORS headers are applied by an outer middleware that post-processes every
response on the proxy path, so the behaviour is observable **without a valid proxy
token** — an unauthenticated `401` on the proxy path still carries the pinned
(or absent) ACAO header. That makes this a pure-`curl` smoke test.

## Preconditions

```bash
scripts/sb-dev.sh start --platform macos --connect-machine MockDe1
P=/api/v1/account/proxy/support/api/sn
SKIN_PORT=$(curl -sf http://localhost:8080/api/v1/webui/server/status | jq -r '.port')
SKIN_ORIGIN="http://localhost:$SKIN_PORT"
```

## Steps

```bash
# 1. Allowed skin origin -> ACAO echoes that origin (not '*') + Vary: Origin
curl -s -D - -o /dev/null -H "Origin: $SKIN_ORIGIN" \
  "http://localhost:8080$P" | grep -iE "access-control-allow-origin|^vary"
# -> access-control-allow-origin: $SKIN_ORIGIN
# -> vary: Origin

# 2. Disallowed origin on the proxy path -> NO permissive ACAO at all
curl -s -D - -o /dev/null -H "Origin: http://evil.example:3000" \
  "http://localhost:8080$P" | grep -iE "access-control-allow-origin" \
  && echo "FAIL: proxy path leaked ACAO to disallowed origin" || echo "OK: no ACAO"

# 3. Non-proxy API path is unchanged (stays permissive)
curl -s -D - -o /dev/null -H "Origin: http://evil.example:3000" \
  "http://localhost:8080/api/v1/info" | grep -iE "access-control-allow-origin"
# -> access-control-allow-origin present (permissive, pre-existing behaviour)

# 4. OPTIONS preflight follows the same rule
curl -s -D - -o /dev/null -X OPTIONS \
  -H "Origin: $SKIN_ORIGIN" -H "Access-Control-Request-Method: GET" \
  "http://localhost:8080$P" | grep -iE "access-control-allow-origin|^vary"
# -> access-control-allow-origin: $SKIN_ORIGIN ; vary: Origin
curl -s -D - -o /dev/null -X OPTIONS \
  -H "Origin: http://evil.example:3000" -H "Access-Control-Request-Method: GET" \
  "http://localhost:8080$P" | grep -iE "access-control-allow-origin" \
  && echo "FAIL: preflight leaked ACAO" || echo "OK: preflight no ACAO"
```

One-shot assertion:

```bash
allowed=$(curl -s -D - -o /dev/null -H "Origin: $SKIN_ORIGIN" "http://localhost:8080$P" \
  | awk 'BEGIN{IGNORECASE=1}/access-control-allow-origin:/{print $2}' | tr -d '\r')
denied=$(curl -s -D - -o /dev/null -H "Origin: http://evil.example:3000" "http://localhost:8080$P" \
  | awk 'BEGIN{IGNORECASE=1}/access-control-allow-origin:/{print $2}' | tr -d '\r')
test "$allowed" = "$SKIN_ORIGIN" || { echo "FAIL allowed: '$allowed'"; exit 1; }
test -z "$denied" || { echo "FAIL denied leaked: '$denied'"; exit 1; }
echo OK
```

The device LAN-IP origin (`http://<device-ip>:<skin-port>`) is also allowed. The
allowlist is rebuilt per request, so an IP learned after startup works. Loopback variants
(`127.0.0.1`, `[::1]`) are included. mDNS/`*.local` hostnames are intentionally not
in the allowlist (open question carried from the design doc).

## Postconditions

```bash
scripts/sb-dev.sh stop
```
