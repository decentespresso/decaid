---
name: decent-app
description: Drive or verify a running Decent app via sb-dev, REST, WebSockets, simulated devices, or real hardware. Use for API/WebSocket changes, runtime/device flows, smoke tests, and end-to-end regression scenarios; not for pure Dart changes that do not require a running app.
---

# Decent app runtime

Use this skill to drive a running Decent Flutter app from the shell. Simulate mode is the default; `--real` stops injecting `--dart-define=simulate=1` so BLE or USB hardware can be used, with `--adb-forward` when the app runs on Android. Persisted simulated-device settings still apply.

This is an Agent Skills-compatible bundle. Codex discovers repository skills under `.agents/skills`; other clients may use different discovery locations. Claude Code uses the forwarder under `.claude/skills/decent-app/`.

## Routing

Read only the routing target(s) needed for the current task. Do not preload unrelated references or scenarios.

| Task | File |
|---|---|
| Start, stop, or reload the app | `lifecycle.md` |
| Call or add REST endpoints | `rest.md` |
| Read or write WebSocket streams | `websocket.md` |
| Work with simulated devices | `simulated-devices.md` |
| Smoke-test a change | `verification.md` |
| Diagnose local build problems | `troubleshooting.md` |
| Run an end-to-end regression | `scenarios/README.md` |

All paths are relative to `.agents/skills/decent-app/`.

## Authoritative sources

Read the relevant source before acting. Do not guess paths, payloads, or current defaults.

- `assets/api/rest_v1.yml`: REST endpoints and payloads.
- `assets/api/websocket_v1.yml`: WebSocket channels and messages.
- `scripts/sb-dev.sh`: lifecycle flags and defaults.
- Root `AGENTS.md`: project workflow and completion requirements.

## Quick start

Simulated machine:

```bash
scripts/sb-dev.sh start --connect-machine MockDe1
curl -sf http://localhost:8080/api/v1/devices | jq .
scripts/sb-dev.sh stop
```

Real BLE machine on an Android tablet:

```bash
scripts/sb-dev.sh start \
  --platform 8734SCCFAC00000747 \
  --real \
  --adb-forward \
  --connect-machine DE1 \
  --preferred-machine-id D9:11:0B:E6:9F:86
curl -sf http://localhost:8080/api/v1/settings | jq -e '.simulatedDevices == []'
curl -sf http://localhost:8080/api/v1/devices | jq .
scripts/sb-dev.sh stop
```

Before a hardware smoke test, verify that `GET /api/v1/settings` reports an empty `simulatedDevices` list. See `lifecycle.md` for the preflight and cleanup commands. `--connect-machine` matches the scan result by name or ID. In real mode, use `--preferred-machine-id` when the saved preference must target a BLE MAC or UUID.
