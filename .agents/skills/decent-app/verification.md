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

## Physical Android device

The tablet is the primary target for onboarding, settings, and permission flows. `adb` works in screen coordinates: the M50Mini display is 1340x800 landscape, so a screenshot pixel is a tap pixel.

```bash
adb devices -l                                  # confirm the serial first
adb -s <serial> shell svc power stayon usb      # a dozing screen returns a black PNG
scripts/sb-dev.sh start --platform <serial> --adb-forward --dart-define key=value
adb -s <serial> exec-out screencap -p > shot.png
scripts/sb-dev.sh stop                          # also drops the adb forward
```

- **Stay awake before anything else.** Without `svc power stayon usb` a screen that dozed on its own returns a fully black screenshot, and the next cycles go into debugging a rendering problem that does not exist. Confirm with `dumpsys power | grep mWakefulness=` reporting `Awake`.
- **`--dart-define` takes one argument.** Write `--dart-define key=value`; the `--dart-define=key=value` form is rejected with `Unknown flag`.
- **Find a control before tapping it.** `adb shell uiautomator dump /sdcard/ui.xml`, then grep the dump for `text="..." ... bounds="[...]"`. Guessed coordinates open system apps and produce screenshots that prove nothing about the app.
- **Read each screenshot before the next tap**, so the evidence for a claim is the screen that tap actually caused.

### Onboarding flows on device

`--dart-define forceOnboarding=true --dart-define dummyAccount=true` reaches the onboarding flow without a real login. `--dart-entrypoint-args` does not reach `main()` on Android; use the dart-define fallbacks.

`forceOnboarding` **re-arms** every step at startup: it clears `onboardingCompleted`, `accountStepSeen`, `androidWarningDismissed` and `shotUploadStepSeen`. Anything that depends on "already answered" — a step that must appear only once, an opt-in cleared after it has been applied — cannot be verified while that flag is on. Verify those with a plain start after completing the flow once.

## Completion requirements

Follow the root `AGENTS.md` for formatting, tests, plan archival or deletion, documentation, and PR requirements. In addition, runtime-facing changes need the relevant `sb-dev` smoke or regression scenario.

## Regression scenarios

The scenario index is in `scenarios/README.md`. Pick the matching recipe and run it before calling related work done.

## Stale spec, stale skill

The skill only works because `assets/api/rest_v1.yml` and `assets/api/websocket_v1.yml` are authoritative. `rest.md` and `websocket.md` both tell readers to trust the spec over their own guesses; future agents generate code from those specs. Any API-shape change that ships without a matching spec update is a regression in the skill itself — the next agent will produce broken code against the wrong contract. This is load-bearing. Update the spec in the same commit as the handler. No exceptions.
