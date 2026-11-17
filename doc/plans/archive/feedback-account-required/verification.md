# Feedback Verification

Verified on Windows on 2026-09-30 at source commit
`02b7c6f2820760e8e164f0a356f2f4d2ccd717fd`.

## Delivery Regression

The serial-mismatch controller test uses the real account service with a mocked
Support response of HTTP 200 and `legacy-success-token`. After disconnecting and
reconnecting the same machine, it asserts that Support received one email.
Before the fix, the test observed two emails. After the fix, it passes.

The shared send operation preserves delivery success when the receipt is
unrecognized or invalid. Feedback can publish only a validated numeric
`messageId`; an absent valid ID skips the GitHub PATCH. Non-200 responses and
empty/zero acknowledgements remain delivery failures.

## Running App

Used the Windows lifecycle documented in
`.agents/skills/decent-app/lifecycle.md`: native `flutter run` with
`--dart-define=simulate=1`, rather than the POSIX-only `sb-dev.sh`.
Only `MockDe1` and `MockScale` reported connected.

The isolated test checkout used a temporary in-memory credential store with
synthetic credentials and a local HTTP Support fixture through the existing
`DECENT_BASE_URL` define. The real account service, production web-server
registration, and feedback handler processed the requests. No production
authentication bypass or test credential store is part of the PR.
The test build omitted `GITHUB_FEEDBACK_TOKEN` to prevent external feedback.

Sent JSON feedback requests with `curl.exe` to the running route:

```powershell
curl.exe -sS --max-time 40 -D headers.txt -o response.json `
  -w '%{http_code} %{time_total}' -X POST `
  http://127.0.0.1:8080/api/v1/feedback `
  -H 'Content-Type: application/json' --data-binary '@request.json'
```

| Account / fixture state | HTTP result | Observed verification |
| --- | --- | --- |
| Signed out | 400, login-required message | No upstream requests |
| Authenticated | 503, missing GitHub configuration | `login_test` received the synthetic credentials |
| Upstream unavailable (503) | 400, could-not-verify message | `login_test` reached the fixture |
| Upstream stalled | 400 after 30.007229 seconds | Fixture observed the aborted `login_test` connection |
| Credentials rejected (401) | 400, login-required message | `login_test` rejected the credentials |
| Authenticated again | 503, missing GitHub configuration | A new `login_test` request |
| Signed out again | 400, login-required message | No upstream requests |

After hot reload, repeated signed-out 400 and authenticated 503.
`GET /api/v1/account/decent` then returned `{"loggedIn":true}`.
The fixture recorded zero `/support/api/email` requests. No test issue, Gist,
or real Support message was sent. Restored the temporary factory edit and
stopped both the app and fixture after verification.

This verifies the authenticated route through the configuration check, not a
live GitHub 201 or a real backend message-ID round trip. Backend contract
confirmation and that external round trip remain pending.

## Tests And Analysis

- Focused controller, account, feedback-service, and HTTP tests: 169 passed.
- `node --test test/plugins/settings_feedback_test.cjs`: 4 passed.
- `flutter analyze --no-pub lib test`: no issues found.
- `flutter test --no-pub`: 4,443 passed, 2 skipped, 1 failed.
- Repository-wide `flutter analyze --no-pub`: six warnings in pre-existing,
  untracked `doc/reliability-audit/checks/` files outside this PR.
- Ran `dart format lib test`; excluded unrelated formatter-only changes.

The remaining full-suite failure is
`test/unit/services/export/archive_export_delivery_test.dart:35`.
Its expected path ends in `/archive.zip`, while Windows directory enumeration
returns `\archive.zip`.

Checked the exact PR base, `8975a2fd7a3624d6e93f4b0881f37fec71e37c7c`, in
an isolated checkout with the same Windows test dependencies:

```powershell
flutter test --no-pub `
  test/unit/services/export/archive_export_delivery_test.dart `
  test/unit/services/webserver/api_docs_server_port_test.dart
```

Result: 6 passed and the same archive-path failure. Both test files are unchanged
between that base and the verified source commit. Both API-docs port tests pass
on the base and in the current full suite; the earlier socket failures no longer
reproduce after the host's excluded-port ranges changed. This supersedes the
earlier three-failure verification report.
