# Verification

Use this file for end-to-end verification against a running Decent instance. For unit, integration, and end-to-end test policy, follow the root `AGENTS.md` and `doc/AI_TESTING_NOTES.md`.

## When to verify via a running app

- **Unit / widget tests** — pure logic, single controller, model, DAO, handler. No BLE, no transport. Run with `flutter test`.
- **Integration tests in-tree** — multi-component flows that mock only the transport edge (`TestScale`, `MockDeviceDiscoveryService`, in-memory Drift). Still `flutter test`; they live alongside unit tests in `test/`.
- **End-to-end verification (this file)** — the feature only exists as a side effect of a running app: REST endpoints, WebSocket streams, plugin runtime, skin webview, hardware-like flows. That's what `sb-dev` + `curl` + `websocat` is for.

## Generic smoke-test recipe

```bash
scripts/sb-dev.sh start --connect-machine MockDe1
scripts/sb-dev.sh status
curl -sf http://localhost:8080/api/v1/machine/state | jq .
# exercise the feature ...
scripts/sb-dev.sh reload
curl -sf http://localhost:8080/api/v1/machine/state | jq .
scripts/sb-dev.sh logs -n 30 --filter error
scripts/sb-dev.sh stop
```

Boot the app with a mock machine connected, confirm REST is reachable and a DE1 is actually connected (`status`), hit the thing you changed, hot-reload the Dart source so the next curl sees the new code, re-exercise, skim the tail of the log for errors, then shut down cleanly. When in doubt about which restart level you need, read `lifecycle.md`.

## Added a new REST endpoint

1. Implement the handler under `lib/src/services/webserver/` and register its route; see `doc/AI_API_NOTES.md` -> "Adding An Endpoint (Checklist)".
2. `scripts/sb-dev.sh reload` to pick up the change.
3. `curl -sf` the new endpoint and confirm the response shape.
4. **Update `assets/api/rest_v1.yml` in the same commit as the handler change.** Stale spec = stale agent knowledge — future `rest.md` users read the spec, not your handler.
5. Update `doc/Api.md` if the change is user-facing.

## Changed a WebSocket message shape

1. Implement the change.
2. `scripts/sb-dev.sh reload`.
3. One-shot verify against the affected channel:
   ```bash
   websocat --no-async-stdio -n -U -t --max-messages-rev 3 \
     ws://localhost:8080/ws/v1/machine/snapshot | jq .
   ```
   Adjust the channel URL to match what you touched. See `websocket.md` for what each flag does.
4. **Update `assets/api/websocket_v1.yml` in the same commit as the handler change.**
5. Update `doc/Api.md` and/or `doc/Plugins.md` if events or event shapes changed.

## Modified an existing endpoint or stream

Shortest loop: reload, re-hit the endpoint, diff the response against the spec. If the shape changed, update `assets/api/rest_v1.yml` or `assets/api/websocket_v1.yml` in the same commit, and update `doc/Api.md` / `doc/Plugins.md` if user-facing.

## Driving a browser (skins, plugin UI, CDP probes)

Run browser probes through the wrapper and retain explicit browser closure in `finally`. The wrapper adds crash recovery; it does not replace Playwright's normal shutdown. An open browser or referenced child stderr stream can keep Node alive, preventing the wrapper's EXIT cleanup from starting.

```bash
scripts/headless-chrome.sh run -- node /tmp/probe.mjs
```

The wrapper requires Python 3 for exact same-effective-user process-environment inspection on macOS/Linux; it never logs full environments. It exports `CHROME_BIN` and a fresh private `CHROME_PROFILE`, without reusing or removing a caller-supplied profile. Playwright requires `launchPersistentContext` to use this owned directory:

```js
import { chromium } from 'playwright';

const context = await chromium.launchPersistentContext(process.env.CHROME_PROFILE, {
  executablePath: process.env.CHROME_BIN,
  headless: true,
});
try {
  const page = context.pages()[0];
  await page.goto('http://127.0.0.1:8080');
} finally {
  await context.close();
}
```

Existing probes with a `browser` object must retain `finally { await browser.close(); }`. Persistent contexts close their browser with `context.close()` as above. Raw CDP probes must pass `--user-data-dir="$CHROME_PROFILE"` and explicitly close their browser and child streams. If supplying a custom child or Playwright environment, include `...process.env` so the inherited run marker survives.

Wrapper-only INT/TERM stops the probe group and processes carrying its run marker. After an untrappable SIGKILL, run `scripts/headless-chrome.sh sweep` with the same `CHROME_RUNTIME_DIR` if overridden. Sweep checks managed profile ownership, actual inherited environment markers and process identity, preserving live runs and unmarked directories. Missing dependencies, unsupported platforms or an unreadable required scan produce an error and retain recovery state rather than claiming cleanup succeeded. It does not recover arbitrary detached processes that strip the run marker, or profiles from older unmarked wrappers. Standalone profile allocation with `path` is intentionally unsupported because it cannot propagate run ownership into a later caller. Review those separately rather than killing unrelated Chrome sessions.

Run `node --test scripts/test_headless_chrome.mjs` and `python3 -B scripts/test_headless_chrome_processes.py` for CLI/process/reader regressions. To include real Playwright lifecycle tests, set `CHROME_BIN` to an installed browser and `HEADLESS_CHROME_PLAYWRIGHT_MODULE` to an existing Playwright module path; no browser is downloaded by this test.

## Physical Android device

See the `decent-dev` skill for the tablet loop (stay-awake, `--dart-define` argument form, tap-target discovery, screenshots) and the onboarding flags. This file covers the app's runtime surface, not the development loop.

## Completion requirements

Follow the root `AGENTS.md` for formatting, tests, plan archival or deletion, documentation, and PR requirements. In addition, runtime-facing changes need the relevant `sb-dev` smoke or regression scenario.

## Regression scenarios

The scenario index is in `scenarios/README.md`. Pick the matching recipe and run it before calling related work done.

## Stale spec, stale skill

The skill only works because `assets/api/rest_v1.yml` and `assets/api/websocket_v1.yml` are authoritative. `rest.md` and `websocket.md` both tell readers to trust the spec over their own guesses; future agents generate code from those specs. Any API-shape change that ships without a matching spec update is a regression in the skill itself — the next agent will produce broken code against the wrong contract. This is load-bearing. Update the spec in the same commit as the handler. No exceptions.
