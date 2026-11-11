---
name: decent-dev
description: Development workflows for changing Decaid — the GitHub repository is decentespresso/decaid and the Dart package is reaprime — covering Flutter/Dart source, tests, build configuration, the local gate, and worktrees. Use when the task modifies the code; when a code change also needs runtime verification, use this skill as the primary guide and the decent-app skill for the REST/WebSocket procedures that exercise the running build.
---

# Decaid development

This skill is for changing the code. A code change that also needs runtime verification uses this
skill and `decent-app` together: this one for the build, test, and gate loop, `decent-app` for the
REST/WebSocket procedures that exercise a running build. Runtime recipes stay in `decent-app`; this
file does not repeat them.

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
| Pinned Flutter SDK | the `flutter-version` in `.github/workflows/`, restated in `README.md` prerequisites |

`AGENTS.md` and those notes win over this file when they disagree. This file carries only what they
do not: the local loop's sharp edges.

## The local gate

```bash
git diff --name-only --diff-filter=ACMR -z HEAD -- '*.dart' | xargs -0 -r dart format --
flutter analyze
flutter test                  # full suite before claiming done
```

Done means: format idempotent on the files you touched, analyze clean, suite green, no unrelated Dart
formatting churn in the diff, and the numbers quoted in your report. A focused run is evidence for a
mid-change check, not for completion.

### Formatting policy

CI enforces formatting. The `Dart format check` step in `.github/workflows/pr-checks.yml` runs
`dart format --set-exit-if-changed` over the Dart files the PR **changed**, with the Flutter SDK that
workflow pins. So:

- Format the files you changed, not the tree. `dart format lib test` rewrites every file in both
  directories with whatever formatter your local SDK ships.
- Do not restate the SDK version in prose. The workflow `flutter-version` is authoritative and
  `README.md` prerequisites restate it for humans; if the two ever disagree, the workflow wins.
- Local and CI SDKs drift independently. A newer local formatter reflows code CI would leave alone, and
  an older one leaves code CI would reflow; either way the failure is not your change. Check out the
  pinned SDK instead of reformatting files to match your local one.

## Worktrees

`AGENTS.md` -> "Worktrees and local verification" is authoritative for worktree build inputs and for
the keystore rules; read it rather than working from memory. What it means in the loop:

- A fresh worktree checks out tracked files only, so `assets/plugins/*.reaplugin` (except the tracked
  `time-to-ready`) and `assets/bundled_skins` are missing. Their `flutter analyze` asset warnings and
  the bundled-plugin test failures are baseline noise you did not cause. Copy the untracked inputs
  from the primary checkout when you need a green run.
- Copy `android/app/debug.keystore` only when a debug build needs it, and never overwrite a keystore
  that is already there.
- Never commit the copies: no gitignored build inputs, no bundled plugin binaries, no keystores.

## Physical Android device

The tablet is the primary target for onboarding, settings, and permission flows. `adb` works in
screen coordinates, so a screenshot pixel is a tap pixel.

```bash
adb devices -l                                  # confirm the serial first
adb -s <adb-serial> shell svc power stayon usb  # a dozing screen returns a black PNG
scripts/sb-dev.sh start --platform <adb-serial> --adb-forward --dart-define key=value
adb -s <adb-serial> exec-out screencap -p > shot.png
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

Onboarding re-arm and bypass are **Dart entrypoint arguments**, not dart-defines: `--force-onboarding`
and `--bypass-onboarding` are parsed from `main()`'s argument list in `lib/src/cli/cli_args.dart`.
There is no compile-time `forceOnboarding` or `dummyAccount` define — nothing reads those names, and
passing them has no effect.

Entrypoint arguments reach `main()` on desktop and under `flutter-tester`. The Android launch path in
`flutter_tools` does not forward them, so with `flutter run --dart-entrypoint-args=...` or
`scripts/sb-dev.sh --app-arg <flag>` on a tablet, `main()` receives an empty list and the flag is
inert.

The Flutter embedding does read `dart_entrypoint_args` from the activity's launch intent
(`FlutterFragmentActivity.getDartEntrypointArgs`), which means an `am start --esa dart_entrypoint_args`
launch is the only remaining candidate path. Nothing in this repository documents or tests that path,
and `launchMode="singleTask"` means an already-running app receives it as `onNewIntent` and never
re-runs `main()`. Treat it as unverified until someone confirms it on a device; do not cite it as the
supported procedure.

Two things that do work today:

- **Clear stored app data** on the tablet. This is a full reset, not an onboarding-only one:

  ```bash
  adb -s <adb-serial> shell pm clear net.tadel.reaprime   # drops all app data
  ```

  Paired devices, saved workflow, and preferences all go with it, so expect to redo setup.
- **Verify the flag on desktop**, where entrypoint arguments are honoured:
  `flutter run --dart-entrypoint-args=--force-onboarding`. Usable for onboarding logic that is not
  platform-specific; the Android warning step still needs a tablet and manual taps.

Adding a tablet-side way to force onboarding would be a code change, not a documentation update.

`--force-onboarding` clears exactly three keys in `lib/main.dart` — `onboardingCompleted`,
`accountStepSeen`, `androidWarningDismissed`. Other one-time prompts (for example
`telemetryConsentDialogShown` or consent keys) keep their state. Because the flag re-arms every step it
does clear, behaviour that depends on "already answered" — a step that must appear only once, an opt-in
cleared after it has been applied — cannot be verified while the flag is on. Verify those with a plain
start after completing the flow once.

## Simulated devices

`scripts/sb-dev.sh` injects `--dart-define=simulate=1` unless you pass `--real`, which adds
`MockDe1`, `MockBengle`, `Mock Scale`, `DebugPort` and `SensorBasket`. Simulated behaviour is not
product behaviour and never proves hardware behaviour. For hardware runs, confirm
`GET /api/v1/settings` reports an empty `simulatedDevices` list first.

## Not in this skill

- **Driving a running instance** (REST/WS calls, scenarios, skin webview): `decent-app`.
- **Private, unshipped context:** this repository is public. Proprietary material and credentials do
  not belong in it — bench tooling, factory provisioning, firmware internals, customer data, keys, and
  tokens stay in the operator's private channels. If a task seems to need them here, ask instead of
  committing them.
