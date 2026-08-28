---
name: decent-app
description: Use when touching the Decent Flutter app, its REST/WebSocket API, profiles, shots, simulated devices, or real BLE/USB hardware via an Android tablet or desktop, or whenever exercising a code change against a running Decent instance. Covers the sb-dev dev loop and shell-based verification.
---

# Decent — agent skill

This skill covers driving a running Decent Flutter app from the shell — simulate mode by default, real hardware via `--real` (+ `--adb-forward` for Android). It exposes REST via `curl`, WebSocket via `websocat`, and lifecycle (start, stop, reload, logs) via `scripts/sb-dev.sh`. Written for any agent that can read markdown and execute shell commands — Claude Code, Cursor, Codex, Windsurf, humans — and deliberately avoids agent-specific mechanisms like MCP tools or slash commands.

The skill lives under `.agents/skills/decent-app/` following the [agentskills.io](https://agentskills.io) cross-client convention. Any compliant client will auto-discover it. Claude Code also loads it via a forwarder at `.claude/skills/decent-app/SKILL.md`.

## Routing

| Task | File |
|---|---|
| Start/stop/reload the app | `lifecycle.md` |
| Call REST endpoints, add endpoints | `rest.md` |
| Read/write WebSocket streams | `websocket.md` |
| Work with MockDe1 / MockScale | `simulated-devices.md` |
| Smoke-test a code change | `verification.md` |
| End-to-end regression recipes | `scenarios/` (index below) |

All files above are siblings of this `SKILL.md` under `.agents/skills/decent-app/`. Relative paths in the sub-files resolve against that directory.

### Scenario index

Pick the scenario that matches the task, run it verbatim, and finish before calling related work done. Each file lists preconditions, a `curl` / `websocat` sequence, expected output hints, and postconditions.

| Scenario | File |
|---|---|
| BLE error surfacing (adapterOff, scaleConnectFailed, sticky errors) | `scenarios/ble-error-surfacing.md` |
| Device scan + connection policy | `scenarios/device-scan-connection-policy.md` |
| Onboarding connection phases (MockDe1 + MockScale auto-connect) | `scenarios/onboarding-connection-phases.md` |
| Preferred-device fast-path round-trip | `scenarios/onboarding-preferred-device.md` |
| Build-info endpoint | `scenarios/build-info.md` |
| Firmware endpoints | `scenarios/firmware.md` |
| ETag / If-None-Match on list endpoints | `scenarios/etag-conditional-gets.md` |
| Discover / restore default profiles | `scenarios/profiles-defaults.md` |
| Hot-water stop-at-weight | `scenarios/hot-water-stop-at-weight.md` |
| Shot-state WebSocket + persisted stop reason | `scenarios/shot-state-ws.md` |
| Display brightness 0-100 + low-battery toggle | `scenarios/display-brightness.md` |
| Debug scale control (simulate) | `scenarios/debug-scale-control.md` |
| Bengle LED strip v2 | `scenarios/bengle-led-strip.md` |
| Bengle integrated scale end-to-end | `scenarios/bengle-integrated-scale.md` |
| Bengle cup-warmer + preheat + capability discovery | `scenarios/bengle-cup-warmer.md` |
| Bengle scale calibration | `scenarios/bengle-scale-calibration.md` |
| Bengle firmware wake-schedule sync | `scenarios/bengle-wake-schedule.md` |
| Account-proxy CORS pinned to skin origin | `scenarios/account-proxy-cors.md` |
| Account-proxy write forwarding + write-scope gate | `scenarios/account-proxy-write.md` |
| Account-proxy native consent gate | `scenarios/account-proxy-consent.md` |
| Plugin Decent-account proxy bridge (host.decentProxy) | `scenarios/plugin-decent-proxy.md` |
| API pressure hardening | `scenarios/api-pressure-hardening.md` |

## Authoritative sources

**Always read the spec before making API calls.** Never guess paths or shapes — the specs are the ground truth and stay in sync with the code.

- `assets/api/rest_v1.yml` — OpenAPI 3.0 spec. Canonical REST endpoint reference.
- `assets/api/websocket_v1.yml` — AsyncAPI 3.0 spec. Canonical WebSocket channels and message shapes.
- `scripts/sb-dev.sh` — lifecycle helper. The entry point for driving a running dev instance.
- `CLAUDE.md` and `AGENTS.md` at the repo root — project-wide conventions, architecture, and workflow rules.

## Prerequisites

Hard dependencies on `PATH`:

- `bash`
- `curl`
- `jq`
- `websocat` (or `wscat` fallback — see `websocket.md`)
- `flutter`
- `mkfifo` (POSIX — macOS and Linux only; Windows contributors run `flutter run` directly, see `lifecycle.md`)

## Quick start

Simulate mode (default — no hardware needed):

```bash
scripts/sb-dev.sh start --connect-machine MockDe1
curl -sf http://localhost:8080/api/v1/devices | jq .
scripts/sb-dev.sh stop
```

Real hardware on an Android tablet (adb serial from `flutter devices`):

```bash
scripts/sb-dev.sh start \
  --platform 8734SCCFAC00000747 --real --adb-forward \
  --connect-machine DE1
curl -sf http://localhost:8080/api/v1/devices | jq .
scripts/sb-dev.sh stop
```

From here, pick the file in the routing table that matches your task.

## Rule of thumb

If you're about to guess an endpoint path, payload shape, or WebSocket channel — stop and read the relevant spec first. If you're about to run `flutter run` by hand, use `scripts/sb-dev.sh start` instead.
