# AI Build Notes

Read this when building, running, flashing, or touching platform configuration. Skip it for pure Dart/logic changes that don't touch native code or build tooling.

## Common Commands

Prefer `./flutter_with_commit.sh` for all runs — it injects the git commit hash and respects `.env.dev`. Pass `--dart-define` flags through it.

```bash
# Run
./flutter_with_commit.sh run                                    # Standard
./flutter_with_commit.sh run --dart-define=simulate=1           # All simulated
./flutter_with_commit.sh run --dart-define=simulate=machine,scale

# Test & Lint
flutter test                                   # All tests
flutter test test/path/to_test.dart            # Specific file
flutter test --name "test pattern"             # Specific test
flutter analyze                                # Static analysis
dart format lib/ test/                      # Format

# Build (Linux via Docker/Colima)
make build-arm                                 # ARM64 binary
make build-amd                                 # x86_64 binary
make dual-build                                # Both architectures
```

## Simulate Modes

Simulated devices avoid hardware requirements for smoke testing. Available types:

| Flag value | Devices |
|------------|---------|
| `1` | All: `MockDe1`, `MockScale`, `MockBengle`, `MockSensor` |
| `machine` | `MockDe1` only |
| `scale` | `MockScale` only |
| `bengle` | `MockBengle` only |
| `machine,scale` | `MockDe1` + `MockScale` |
| `sensor` | `MockSensor` only |
| `replay` | `MockReplayDe1` (replay recorded shots, matched to the profile) |
| `0` | None (debug routes on, real hardware) |

Also toggleable from the settings UI after launch.

### Replay simulator (`simulate=replay`)

`MockReplayDe1` is a single device that plays back a real recorded shot instead
of synthesizing telemetry. On shot start it asks `SimulatedShotLibrary` for a
bundled recording made with the currently selected profile (`forProfileTitle`,
normalized match); if none exists it falls back to a generic shot, and streams
the recording's samples at 10 Hz.

It implements `BengleInterface`, so it is one device that is both machine and
integrated scale — the connection manager auto-wraps its `weightSnapshot` as a
`BengleVirtualScale` (no separate scale device), and target-weight uses the
autonomous stop-at-weight path (the `ShotSequencer` bypasses its own SAW for
`BengleInterface`; the device stops itself when the recorded weight reaches the
target the `BengleSawBridge` pushes). It does NOT extend `MockDe1`: it
*composes* one, delegating the De1Interface surface to it and falling back to it
for steam / hot water / flush. `MockDe1`/`MockScale` are untouched.

Replay is **opt-in**: `simulate=1` expands to the default set only (see
`_defaultSimulatedDevices` in `main.dart`) and never enables it. To force a
specific recording (instead of profile match) use the debug API:
`GET /api/v1/debug/replay/shots` to list stable ids,
`POST /api/v1/debug/replay/shot/{id}` to force one, `DELETE
/api/v1/debug/replay/shot` to clear (session-only).

`MockReplayDe1` implements `BengleInterface`, so it is one device that is both
machine and integrated scale (the connection manager wraps its `weightSnapshot`
as a `BengleVirtualScale`). Target weight uses the autonomous stop-at-weight
path (the `ShotSequencer` bypasses its SAW for `BengleInterface`; the
`BengleSawBridge` pushes the target; the device stops itself). It does NOT
extend `MockDe1`: it composes one, delegates the De1Interface surface to it, and
falls back to it for steam / hot water / flush (running a
`SimulatedShotWeightModel` for the integrated scale when replay is inactive).
`skipStep` seeks the replay to the next recorded frame; without a positive
target the shot ends at the recording's real endpoint.

### Replay profile matching

`SimulatedShotLibrary.forProfileTitle` matches on a normalized key, most
specific first: the whole title, then its last path segment (bundled titles are
`prefix/name` — community shots `author/name`, Decent titles `category/name`, so
the trailing segment is the profile's real name). Canonical (full-title) matches
always win. A last-segment alias is only registered when it is unambiguous (one
recording claims it) and does not collide with a canonical title — this is what
keeps a generic segment like `default` from hijacking a distinct profile.

### Replay corpus generation

`test/tools/generate_simulation_assets_test.dart` (run with
`REGEN_SIM_ASSETS=1`) converts `tool/simulation_sources/**.shot` into the
`assets/simulations/` corpus:

- **10 Hz resample** — de1app records at ~5 Hz; MockDe1 streams at 100 ms, so the
  recorded head is resampled to a uniform 10 Hz grid (continuous channels
  interpolated; discrete state/frame carried from the sample at or before each
  grid point).
- **Frame reconstruction** — `TclShotParser` yields empty-step profiles, so
  `profileFrame` is rebuilt from the recorded `espresso_state_change` markers
  (frame advances each time the marker changes).
- **Tail extension** — each recording is extended to ~2.5 min with a steady-state
  1 Hz tail (held pressure/flow/temperature, weight rising at the final pour
  rate) so stop-at-weight has data for any target past the recorded final
  weight. `manifest.json` records each recording's original (pre-tail) duration.
- A placeholder `Replay` profile step is injected so `ShotRecord.fromJson`
  round-trips; replay drives telemetry from samples, not the profile.

The corpus lives in `assets/simulations/` (`manifest.json` maps profile titles
to shot files). Profile-matched shots were pulled from visualizer.coffee, one
per bundled profile where a public shot existed, and converted via the same
`tool/simulation_sources/**.shot` → `TclShotParser` → 10 Hz pipeline. Rebuild
with `REGEN_SIM_ASSETS=1 flutter test test/tools/generate_simulation_assets_test.dart`.

### `simulate=0` mode

`--dart-define=simulate=0` enables the debug infrastructure (API routes,
no-Firebase, no-telemetry) while creating zero simulated devices. Use it for
temporary real-hardware tuning builds where debug endpoints must be reachable.

- Enables debug REST routes (`/api/v1/debug/*`)
- Creates no simulated devices — all BLE/USB hardware is real
- Disables Firebase and telemetry
- Must not be used for production releases

## Platform Config

**Supported platforms:** Android (primary), macOS, Linux, Windows, iOS.

- `flutter_with_commit.sh` injects the git commit hash as a compile-time constant via `--dart-define`.
- CI uses pinned Flutter version. Linux build smoke runs via Docker.
- Android uses `ForegroundTaskService` for background BLE. Auto-stops 5min after disconnect; auto-restarts on reconnect.
- `Makefile` targets: `build-arm`, `build-amd`, `dual-build` (Linux only, requires Docker/Colima).

## Footgun #1: Xcode 26.4 / flutter_inappwebview

**Symptom:** `flutter build macos` fails with `Swift 6.3 error: protocol 'ASWebAuthenticationPresentationContextProviding' requires 'presentationAnchor(for:)' to be available in macOS 10.14 and newer`.

**Root cause:** Upstream `flutter_inappwebview_macos` plugin bug — `presentationAnchor(for:)` annotated `@available(macOS 10.15, *)`, narrower than the protocol requirement (10.14). Swift 6.3 promotes this from warning to hard error. Xcode 26.3 still builds fine.

**Fix:** `dependency_override` in `pubspec.yaml` pointing to fork `wangqiang1588/flutter_inappwebview` (commit `fc33a449`). Upstream PR #2809 is open but unreviewed (3+ months).

**Impact:** Blocks local macOS smoke-testing only. CI (Linux) and Android builds unaffected.

**Track:** Remove override once upstream #2809 merges + plugin release ships.

## Footgun #2: Serial Probe Write Hang

**Symptom:** Windows startup freezes when a non-Decent USB-serial device sits on a COM port.

**Root cause (fixed PR #241):** Serial discovery probes every port with MMR writes; `write(timeout:0)` blocked forever + unbounded `drain()` froze the main isolate in native FFI. Dart `.timeout()` couldn't fire.

**Fix:** Finite 500ms per-chunk write timeout + bail on zero-progress, `drainWithTimeout` polling `bytesToWrite`.

## Bengle EBus tap (hardware verification)

Decaid identifies the tap by VID `0x2e8a`, PID `0x000a`, the exact USB
product name `Bengle`, and logical USB interface `2`; it never relies on
unstable device paths. VID/PID are shared Pico SDK identifiers, so the product
name is required to reject other Pico boards. Interface `0` remains
the Bengle machine with its existing stable ID. Discovery must not probe or
write to the tap.

The Sensor behavior contract — raw bytes, DTR, and single-reader ownership —
lives in [`doc/DeviceManagement.md`](DeviceManagement.md#bengle-ebus-tap).

**Hardware checks not covered by unit tests:**

1. The machine and tap appear with distinct IDs and connect concurrently.
2. Unplug removes only the detached physical device's logical entries; replug
   rediscovers them.
3. Android opens bulk-data interface `3` for logical interface `2`; devices
   with duplicate USB descriptors receive distinct session IDs.
4. Raw Sensor snapshots remain byte-exact and discovery performs no writes.

Platform results must be observed independently on each claimed platform.

## Footgun #3: `codesign --deep` destroys Sparkle's Installer XPC

**Symptom:** After a signed/notarized update, Sparkle's "Update failed" alert or a silent failure to relaunch. The app builds and notarizes fine.

**Root cause:** `codesign --deep --force --entitlements <host.plist>` re-signs every nested binary (Sparkle.framework, Installer.xpc, Updater.app, Autoupdate) with the HOST's entitlements. The sandboxed Installer XPC service needs its own embedded entitlements; clobbering them breaks the sandbox escape that replaces the app in `/Applications`. Sparkle explicitly warns against `--deep`.

**Fix:** `scripts/sign_macos_deepest_first.sh` signs Sparkle's nested helpers deepest-first (`Installer.xpc` → `Downloader.xpc` → `Updater.app` → `Autoupdate` → framework → host), each without `--entitlements` so existing embedded entitlements survive; only the host app gets `Release.entitlements`. Gates in `scripts/verify_macos_signature.sh` (Team ID, Hardened Runtime, mach-lookup names, no `get-task-allow`) run before and after notarization.

## Footgun #4: `codesign` does not expand `$(PRODUCT_BUNDLE_IDENTIFIER)`

**Symptom:** The signed app's entitlements contain the literal string `$(PRODUCT_BUNDLE_IDENTIFIER)-spks`, so Sparkle's XPC lookup fails (the XPC registers as `net.tadel.reaprime-spks`).

**Root cause:** `codesign --entitlements` takes the file as-is; Xcode build-variable expansion happens only in Xcode's own signing step. The signing script sed-expands the bundle id before signing (see `scripts/sign_macos_deepest_first.sh`).

**Fix:** Never hand `Release.entitlements` to `codesign` unexpanded. The verification script also greps for the unexpanded variable.

**Note (App Store):** `com.apple.security.temporary-exception.mach-lookup.global-name` is not permitted in Mac App Store builds. Any future `APP_STORE=true` macOS build must drop the Sparkle keys/entitlements and keep self-update disabled.

## Footgun #5: iOS file picker returns unreadable security-scoped folders

**Symptom:** On iOS, installing a plugin (or importing a de1app folder, skin live-edit, data restore) via the file picker fails with `PathAccessException: Directory listing failed ... (OS Error: Operation not permitted, errno = 1)`. The picked path lives under `Mobile Documents/com~apple~CloudDocs/...` (iCloud Drive) or another app's sandbox — outside our container.

**Root cause:** `FilePicker.getDirectoryPath()` uses `UIDocumentPickerModeOpen`, which hands the app a *security-scoped* URL. Reading it requires `startAccessingSecurityScopedResource()`, which file_picker never calls — it only returns `url.path`. The app has no `UIFileSharingEnabled`/iCloud entitlement, so its own Documents folder is not browsable in Files either.

**Fix (PR #609):** `SecurityScopedFilePlugin` (`ios/Runner/AppDelegate.swift`, channel `com.reaprime/security_scoped`) calls `startAccessingSecurityScopedResource` on the reconstructed URL and retains it until Dart releases it. `SecurityScopedFileService` (Dart) wraps every `getDirectoryPath` pick site: plugin install, de1app import, skin live-edit, data restore. The service auto-releases the previously held folder on the next pick, keeping the native registry bounded; `stopAccessing` releases explicitly (plugin install releases after the staged copy). Access is deliberately held for the session for long-lived flows (skin live-edit serves the folder over HTTP on demand).

**Impact:** iOS only; the channel is a no-op elsewhere (`Platform.isIOS` guard). Do not add new `FilePicker.getDirectoryPath()` consumers without routing them through `SecurityScopedFileService`.

## CLI Parameters

The app supports several command-line flags for headless/calibration-station use. See PR #349 and #352 for full details.

```bash
./flutter_with_commit.sh run --dart-define=simulate=1 \
  --serial=<mac>              # Auto-connect to specific DE1 by MAC
  --bypass-onboarding         # Skip onboarding, go straight to launcher
  --direct                    # Skip scan, connect directly to --serial device
  --skin=<id>                 # Pre-select skin by ID
  --skin-path=<path>          # Pre-select skin by filesystem path
  --no-account                # Skip DecentAccountService (headless Linux with no desktop session)
  --trust-consent=<key>       # Trust one account-proxy caller for this process; repeatable
  --trust-all-consent         # Trust every account-proxy caller for this process
```

All flags are optional. Combine as needed. `--no-account` is specifically for headless Linux stations where `libsecret` blocks on XDG secrets portal. Consent keys use `skin:<installed-id>`, `plugin:<id>`, or `api:<token-id>`; API token labels are presentation-only. Both trust flags are session-only and are never persisted. With `flutter run`, pass each app flag separately as `--dart-entrypoint-args=<flag>`; `--dart-define` does not populate `main()` arguments.

## Dev-Loop Skill

Driving a running app through its lifecycle: `.agents/skills/decent-app/SKILL.md`. Managed by `scripts/sb-dev.sh`:

```bash
scripts/sb-dev.sh start      # Launch in simulate mode
scripts/sb-dev.sh reload     # Hot reload (preserves state)
scripts/sb-dev.sh hot-restart  # Full restart (resets state)
scripts/sb-dev.sh stop       # Kill the app
scripts/sb-dev.sh logs       # Tail logs
scripts/sb-dev.sh status     # Is it running?
```

Prefer `reload` over `hot-restart` — state is preserved.

## Logging

- Dart-side: `package:logging`, configured in `main.dart`.
- File log: `getApplicationDocumentsDirectory()/log.txt` (plus rotated `log.txt.1..3`).
- Android retrieval: `adb shell run-as net.tadel.reaprime cat app_flutter/log.txt` or `adb logcat`.

## Focused Checks

```sh
flutter analyze          # Minimum before any commit
flutter test             # Full suite before commit/PR
dart format lib/ test/  # Format check
```

## Keeping Notes Fresh

Add build footguns, platform-specific quirks, and toolchain issues that would save debugging time. Prune when upstream fixes ship. Prefer fewer, sharper notes over long background.
