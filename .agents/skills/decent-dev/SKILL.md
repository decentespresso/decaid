---
name: decent-dev
description: Development workflows for changing Decaid itself — Flutter/Dart code, tests, the local gate, worktrees, CI pins, and driving the M50Mini tablet. Use when making or verifying a code change in reaprime/Decaid; use the decent-app skill instead when the task is to drive a running instance through its REST/WebSocket API without changing code.
---

# Decaid development

This skill is for changing the code. If the task is to *use* a running app — add a bean, switch the
workflow, pull shot history through the API — read `decent-app` instead.

## Sources of truth — read these, do not rely on memory

| What | Where |
| --- | --- |
| Workflow, PR rules, hard rules, triage labels | repo `AGENTS.md` |
| File routing ("where does X live") | `doc/AI_REPO_MAP.md` |
| BLE, transport, connection phases | `doc/AI_BLE_NOTES.md` |
| Build, flash, simulate, platform quirks | `doc/AI_BUILD_NOTES.md` |
| Drift schema, migrations, prefs | `doc/AI_STORAGE_NOTES.md` |
| Test tiers, widget patterns, mock helpers | `doc/AI_TESTING_NOTES.md` |
| REST/WS contracts | `assets/api/rest_v1.yml`, `assets/api/websocket_v1.yml` |
| Device hardware, protocols, firmware | `doc/device-notes/` |

`AGENTS.md` and those notes win over this file when they disagree. This file carries only what they
do not: the local loop's sharp edges.

## The local gate

```bash
dart format lib test          # touched files only; see the CI pin below
flutter analyze
flutter test                  # full suite before claiming done
```

Done means: format idempotent on the files you touched, analyze clean, suite green, and the numbers
quoted in your report. A focused run is evidence for a mid-change check, not for completion.

## Worktrees

A fresh worktree checks out tracked files only, so the gitignored build inputs are missing and the
baseline is red for reasons you did not cause: `assets/plugins/*.reaplugin` (except the tracked
`time-to-ready`), `assets/bundled_skins`, and `android/app/debug.keystore`. Copy them in from the
primary checkout — never copy tracked directories over the worktree, and never commit the copies.
`lane_preflight.sh` in the a-team skill does this automatically.

## CI pins a different Flutter

Local Flutter and CI Flutter are not the same version, and repo-wide `dart format` produces drift
that CI then rejects. Format only the files you touch, and check the pinned version in CI before
blaming your change for a formatting failure.

## Physical Android device

The tablet is the primary target for onboarding, settings, and permission flows. `adb` works in
screen coordinates: the M50Mini display is 1340x800 landscape, so a screenshot pixel is a tap pixel.

```bash
adb devices -l                                  # confirm the serial first
adb -s <serial> shell svc power stayon usb      # a dozing screen returns a black PNG
scripts/sb-dev.sh start --platform <serial> --adb-forward --dart-define key=value
adb -s <serial> exec-out screencap -p > shot.png
scripts/sb-dev.sh stop                          # also drops the adb forward
```

- **Stay awake before anything else.** Without `svc power stayon usb` a screen that dozed on its own
  returns a fully black screenshot, and the next cycles go into debugging a rendering problem that
  does not exist. Confirm with `dumpsys power | grep mWakefulness=` reporting `Awake`.
- **`--dart-define` takes one argument.** Write `--dart-define key=value`; the
  `--dart-define=key=value` form is rejected with `Unknown flag`.
- **Find a control before tapping it.** `adb shell uiautomator dump /sdcard/ui.xml`, then grep the
  dump for `text="..." ... bounds="[...]"`. Guessed coordinates open system apps and produce
  screenshots that prove nothing about the app.
- **Read each screenshot before the next tap**, so the evidence for a claim is the screen that tap
  actually caused.

### Onboarding flags on device

`--dart-define forceOnboarding=true --dart-define dummyAccount=true` reaches onboarding without a
real login. `--dart-entrypoint-args` does not reach `main()` on Android; use the dart-define
fallbacks.

`forceOnboarding` **re-arms** every step at startup: it clears `onboardingCompleted`,
`accountStepSeen`, `androidWarningDismissed` and `shotUploadStepSeen`. Anything that depends on
"already answered" — a step that must appear only once, an opt-in cleared after it has been applied —
cannot be verified while that flag is on. Verify those with a plain start after completing the flow
once.

## Simulated devices

`scripts/sb-dev.sh` injects `--dart-define=simulate=1` unless you pass `--real`, which adds
`MockDe1`, `MockBengle`, `Mock Scale`, `DebugPort` and `SensorBasket`. Simulated behaviour is not
product behaviour and never proves hardware behaviour. For hardware runs, confirm
`GET /api/v1/settings` reports an empty `simulatedDevices` list first.

## Not in this skill

- **Driving a running instance** (REST/WS calls, scenarios, skin webview): `decent-app`.
- **Private, unshipped context** — bench tooling, factory provisioning, firmware internals, anything
  that must not reach this public repository: it stays in the operator's out-of-repo skill and the
  internal vault. This repository is public; treat anything proprietary as not writable here.
