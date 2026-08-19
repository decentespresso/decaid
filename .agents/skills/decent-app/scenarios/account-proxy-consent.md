# Scenario: Account-proxy native consent gate

Verifies that the first linked-account proxy request for a skin pauses for a
trusted native prompt, denial returns `403` without contacting the upstream,
and an explicit session trust grant forwards without a prompt. Use a linked
Decent account and the read-only `support/api/sn` endpoint.

## Preconditions

Run this on a desktop with a linked account and an installed `streamline.js`
skin. The denial check uses a disposable custom skin path so it cannot lock the
normal installed skin out. `flutter run` uses `--dart-entrypoint-args` because
consent trust is a process argument, not a Dart define.

```bash
TMP=$(mktemp -d)
printf '<!doctype html><html><head></head><body>Consent smoke</body></html>\n' \
  > "$TMP/index.html"
./flutter_with_commit.sh run -d macos --dart-define=simulate=1 \
  --dart-entrypoint-args=--skin-path="$TMP"
```

In another terminal, wait for the servers and obtain the injected skin token:

```bash
until curl -sf http://localhost:8080/api/v1/info >/dev/null; do sleep 1; done
P=/api/v1/account/proxy/support/api/sn
TOK=$(curl -s http://localhost:3000/ \
  | sed -n 's/.*name="reaprime-proxy-token" content="\([^"]*\)".*/\1/p' \
  | head -1)
test -n "$TOK"
```

## Steps

Start a request and leave it waiting while the native dialog is visible:

```bash
curl -sS -w '\nHTTP %{http_code}\n' \
  -H "Authorization: Bearer $TOK" "http://localhost:8080$P"
```

Choose **Deny** on the Decaid device. The request must finish with:

```text
{"error":"Account access was not granted"}
HTTP 403
```

Stop the app, then start it with explicit session trust:

```bash
./flutter_with_commit.sh run -d macos --dart-define=simulate=1 \
  --dart-entrypoint-args=--skin=streamline.js \
  --dart-entrypoint-args=--trust-consent=skin:streamline.js
```

Fetch the new process token and repeat the request:

```bash
until curl -sf http://localhost:8080/api/v1/info >/dev/null; do sleep 1; done
TOK=$(curl -s http://localhost:3000/ \
  | sed -n 's/.*name="reaprime-proxy-token" content="\([^"]*\)".*/\1/p' \
  | head -1)
status=$(curl -sS -o /tmp/decaid-consent-body -w '%{http_code}' \
  -H "Authorization: Bearer $TOK" "http://localhost:8080$P")
test "$status" != "403"
cat /tmp/decaid-consent-body
```

No consent dialog should appear in the trusted run. With a valid linked account,
the response is the upstream serial-number result rather than Decaid's consent
error.

## Postconditions

Stop `flutter run` with `q`, then remove the disposable skin:

```bash
rm -rf "$TMP"
```

The deny remains scoped to the hash of that disposable path and cannot affect
an installed skin. The session trust override is gone when the process exits.
