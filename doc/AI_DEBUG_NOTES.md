# AI Debug Notes

Read this when debugging BLE errors, diagnosing platform-specific crashes, investigating app hangs, or tracing error paths. Skip it for feature work that doesn't touch error handling.

## Source Of Truth

- Error filter: `lib/src/services/crashlytics_error_filter.dart`.
- Logging: `package:logging`, configured in `main.dart`.

## General Debugging Principles

- **File log first:** `getApplicationDocumentsDirectory()/log.txt` (rotated `log.txt.1..3`). On Android: `adb shell run-as net.tadel.reaprime cat app_flutter/log.txt`.
- **adb logcat:** `adb logcat | grep -i rea` for live output on Android.
- **macOS log path:** `~/Library/Containers/net.tadel.reaprime/Data/Documents/log.txt`.
- **Simulate mode:** Reproduce without hardware using `--dart-define=simulate=1`. Mock devices are deterministic — use them to isolate whether an issue is transport or logic.
- **`simulate=0` (debug-on-real):** `--dart-define=simulate=0` enables debug routes and disables Firebase/telemetry while keeping real BLE/USB hardware. Use for temporary tuning builds where `/api/v1/debug/*` must be reachable against real devices. Must not be shipped to users.
- **Stream debugging:** Enable `Logger('ShotState')` for structured shot decisions. `Logger('Ble')` for BLE operations.

## Common Error Patterns

### `LateInitializationError` in SettingsController

**Symptom:** `LateInitializationError: _chargingMode has not been initialized`.
**Root cause:** `late` fields accessed before `loadSettings()` completes.
**Fix (PR #243):** Replaced all `late` fields in `SettingsController` with safe defaults matching `SharedPreferencesSettingsService` `??` fallbacks.
**Prevention:** Never use `late` for fields that depend on async initialization. Use nullable + default instead.

### `Stream has already been listened to`

**Symptom:** `Bad state: Stream has already been listened to`.
**Root cause:** A single-subscription stream (e.g., `StreamController.broadcast()` not used) was listened to by multiple subscribers.
**Fix:** Use `.asBroadcastStream()` on streams shared across multiple listeners. The guard was added in `comms-harden` #3 (`20e5d8e6`).
**Prevention:** All shared controller streams should be broadcast.

### `PathAccessException` (iOS export)

**Symptom:** `PathAccessException: Operation not permitted` when exporting data to iCloud Drive.
**Pattern:** Writing directly to file system paths that need security-scoped access.
**Related:** PR #409 fixed the `saveFile` path. Other export paths may still need the same treatment.
**Fix pattern:** Route file writes through `saveFile` (which handles security-scoped URLs) rather than direct `writeAsBytes`.

### `PlatformException(startScan, Location services required)`

**Symptom:** Android BLE scan fails with location permission error.
**Cause:** Android requires location permissions for BLE scanning on API < 31.
**Status:** Low volume. May be addressed by onboarding permission checks.

### `TimeoutException` in BLE queue

**Pattern:** BLE operations timing out after 10s in the universal_ble queue.
**Related:** May involve zombie-link teardown (#431) or concurrent BLE write contention (#423).

### `SuperNotCalledException` at launch

**Symptom:** `Activity did not call through to super.onCreate()` — Android launch crash.
**Fix (PR #435):** `super.onCreate()` moved to top of `onCreate()` before early-return guards.
**Follow-up:** `isRunningInClonedEnvironment()` heuristic may flag legitimate multi-user/work-profile devices as clones.

## BLE Error Debugging

- **GATT-133 on cold boot:** See `doc/AI_BLE_NOTES.md` footgun #1. Second connect succeeds.
- **Duplicate state messages:** See `doc/AI_BLE_NOTES.md` footgun #2. Listener stacking from reconnect.
- **Scale write exceptions:** Must be caught at `_writeCommand` / `_safeWrite`. `isBenignFrameworkError()` in `crashlytics_error_filter.dart` is the safety net, not the primary defense.
- **Gone-device errors:** `UniversalBleTransport._handleGattError()` catches `UniversalBleException` with codes: `characteristicNotFound`, `deviceNotFound`, `serviceNotFound`, `connectionTerminated`, `deviceDisconnected`, `unknownError`. On hit: emits `disconnected`, drains queue, throws `DeviceNotConnectedException`.

## Widget / UI Debugging

- **Stream propagation:** Add devices to mock service *before* building widgets, `await tester.pump()` before `pumpWidget()`.
- **Infinite animations:** Use `pump()` not `pumpAndSettle()` when tree has `CircularProgressIndicator`.
- **Async operations:** Use `tester.runAsync()` for code that uses real `Future.delayed` or stream microtasks.
- **Lifecycle:** Implement `WidgetsBindingObserver`, set stream to `null` when backgrounded.

## Debugging Commands

```sh
# Android log retrieval
adb shell run-as net.tadel.reaprime cat app_flutter/log.txt
adb logcat | grep -i rea

# macOS log path
~/Library/Containers/net.tadel.reaprime/Data/Documents/log.txt

# Simulate mode (reproduce without hardware)
flutter run --dart-define=simulate=1
```

## Profile Upload Failure Diagnosis

See [`device-notes/de1.md`](device-notes/de1.md#failure-diagnosis).

## Blank Android skin after app resume

**Symptom:** The embedded skin stays blank with a spinner after a machine
power-cycle or app relaunch. Reloading the page does not recover it, but
restarting the app does.

**Root cause:** Android `WebView.pauseTimers()` pauses layout, parsing, and
JavaScript timers for every WebView in the process. `SkinView` could be disposed
while backgrounded, or receive `resumed` before its controller existed, leaving
the process-wide pause unbalanced. A replacement WebView then inherited the
paused parser state.

**Fix pattern:** Track the outstanding pause across `SkinView` instances. Cancel
the background blank-page timer before the controller-null return, resume timers
during disposal and WebView creation, and clear `_didBlank` before reloading. Do
not infer renderer health from page DOM shape or deliberately crash the renderer;
custom skins have no common ready signal and Apple WebViews use a different
termination callback.

# Scale Frame And Feed Failures

See [`device-notes/scales.md`](device-notes/scales.md#acaia).

## Keeping Notes Fresh

Add debugging patterns with: symptom, root cause, fix pattern, prevention. Prune when fixes ship and patterns are no longer current.
