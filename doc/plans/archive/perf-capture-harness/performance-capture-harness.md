# Performance capture harness

## Problem

Stutter was visible while recording onboarding videos on the M50Mini tablet
(Android 14, 60 Hz), most clearly in the onboarding progress indicators. There
was no way to tell whether the UI thread is being blocked, whether the raster
thread is the limit, or which onboarding step is responsible - and no way to
check whether a change made it better or worse.

## Approach

Three pieces, each addressable independently.

1. **In-app frame recorder** (`lib/src/services/telemetry/frame_profiler.dart`).
   A `SchedulerBinding.addTimingsCallback` listener that aggregates engine
   `FrameTiming` per named segment and emits a JSON snapshot every 15 s and on
   demand. Only installed when the build carries a `perfFrames` define; any
   non-empty value enables it, so shipped builds pay nothing as long as the
   define is absent.

2. **Segment markers.** `FrameProfiler.mark(label)` is called from `main()`,
   from `BootTiming.mark()`, and from `OnboardingView.build()` for the current
   step. That attributes jank to `boot:<phase>` and `onboarding:<step.id>`,
   which is the specific question being asked. Markers are cheap no-ops when
   capture is off.

3. **Host script** (`scripts/perf-capture.sh`). Builds a profile apk with the
   capture defines, installs and launches it on the attached device, collects the
   report, and diffs a capture against a saved baseline. Profile, not debug:
   `sb-dev.sh` runs debug, where JIT and assertions make frame timing
   unrepresentative of the shipped product.
4. **Flow driver** (`integration_test/onboarding_flow_test.dart`). uiautomator
   sees nothing in a Flutter app and no coordinates survive a layout change, so
   driving the flow needs `integration_test`. The driver boots the real
   `app.main()` and taps by widget text.

## How the report reaches the host

Originally the snapshot was emitted as chunked `Logger.info` lines and
reassembled from logcat. Both of those proved unreliable: the transport truncates
long lines, and the app logs at FINE level so a 90 s capture rotates chunks out of
the ring buffer before collection.

The primary path is now `binding.reportData`, written by
`test_driver/integration_test.dart` to `build/perf/integration_response.json`.
The in-app file write (`app_flutter/perf/latest.json`, read via `run-as`) and the
logcat chunks remain as fallbacks for manual `run` captures only.

## Rejected alternatives

- **`traceAction` timeline summaries**: usable alongside this harness, but they
  describe the driver's widget tree rather than the per-screen attribution we
  wanted. The in-app recorder covers more of the real boot path.
- **DevTools timeline by hand**: interactive, not comparable run to run.
- **Firebase Performance traces**: already used for `cold_boot`, but sampling and
  aggregation hide single-frame stalls, and it is not available in
  `simulate` builds.
- **`uiautomator` / `adb shell input tap`**: Flutter renders to one surface and
  does not publish semantics to the Android accessibility bridge, so there is
  nothing to match text against; coordinates alone break on any layout change.

## Result

`doc/AI_PERF_NOTES.md` documents the instrument, the commands, and how to read
`build` vs `raster` numbers.

## What the first measurements showed

Captures of the onboarding flow on the M50Mini, including runs against a real
BLE DE1 (an ESP32-S3 emulator), not only simulated devices.

- The largest observed values were raster-side. The import step measured
  3 frames at `build p90` 16.96-17.95 ms and `raster p90/max` 140-174 ms; the
  welcome step measured raster p90 25.6-33.97 ms; the scan step hit
  `raster max` 135-144 ms.
- Everything else stayed at `build p90` 0.4-5.5 ms against a 16.67 ms budget.
- The main isolate may or may not be blocking: this recorder does not retain
  scheduling delay, so it cannot exclude a block that delayed frames from
  starting.

Two product problems surfaced while measuring, independent of the harness:

- `WebViewCompatibilityChecker` runs a headless WebView test with a 10 s timeout
  and fails on this tablet when a real machine is connected, so `SkinView`
  refuses to load the WebView. A `perfSkipWebViewCompat` define bypasses it for
  measurement; the timeout itself is unresolved.
- Android logged `Choreographer: Skipped 60 frames`, a ~1 s stall that produced
  no long build frame and was invisible to the original metrics.

Still unmeasured: the same flow with screen recording active, which is what the
original recordings had in play, and skin time-to-interactive. The skin does
reach a fully rendered state (Streamline: Default profile, live water
temperature, `Ready`), but only after a spinner phase lasting minutes, and
neither `onLoadStart` nor `onLoadStop` fires, so the capture cannot time it.

Also unmeasured: the connecting screen's own cost. `scan_flow_view.dart:122`
marks `connect_<phase>` on the phase event rather than on the rendered screen, so
scanning, connecting and the hand-off all collapse into one segment.

Before this plan is archived: fix segment attribution (Known limitations item 1)
and the stale-capture reuse (item 3), then re-record the numbers above.
