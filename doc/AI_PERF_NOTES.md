# Performance notes

Cross-device performance measurement. Load this when a change might affect frame
timing, startup cost, or main-isolate work, and when investigating reported
stutter or jank.

## The instrument

`lib/src/services/telemetry/frame_profiler.dart` installs a
`SchedulerBinding.addTimingsCallback` listener and aggregates engine
`FrameTiming` into named segments. Nothing is installed in a normal build; the
callback only exists when the build carries a `perfFrames` define.

Any **non-empty** value enables capture, including `perfFrames=false`. The check
is `String.fromEnvironment('perfFrames').isNotEmpty`, not boolean parsing, so
treat the define as an on/off switch that must be absent, never set to a falsy
string.

`scripts/perf-capture.sh build` is the only supported way to produce a capture
build. It builds an Android profile apk with:

- `--dart-define=perfFrames=1`
- `--dart-define=perfRefreshHz=<N>` (jank budget = `1000/N` ms, default 60)
- `--dart-define=simulate=1` unless `--real`, so device discovery does not
depend on what happens to be advertising; frame timing is still not
reproducible run to run

## Segments

Segments are markers, not timers. `FrameProfiler.mark(label)` opens a new
segment; every frame after that mark is attributed to it.

Current markers:

| Marker | Set by |
|--------|--------|
| `boot` | `main()`, before `runApp` |
| `boot:<phase>` | `BootTiming.mark()` (`firebase_done`, `init_start`, `init_ready`, `scan_start`, `...`) |
| `onboarding:<step.id>` | `OnboardingView.build` (`lib/src/onboarding_feature/onboarding_view.dart:50`) |
| `unmarked` | frames before the first mark |

Frames are attributed by an index of *delivered* timings, not of rendered
frames. FrameTiming batches arrive after the frames that produced them, so a
mark that lands while a batch is still in flight puts those earlier frames in
the **new** segment. Two marks inside one batch share a start index and the
later one wins.

This is a known correctness bug, recorded under Known limitations. Every
per-segment figure is approximate until it is fixed, including `boot` and
`boot:<phase>` - they use the same marking mechanism. Only the device-wide
frame total survives segment reassignment.

## How to run a capture

**Exploratory only.** Until Known limitations items 1 and 3 are fixed, captures
are not a regression baseline: segment attribution is wrong and a failed run can
be stamped with an older report. Read the numbers as a lead, not a gate, and
promote a baseline only for the device and flow you are actively investigating.

Fully automated (preferred):

```bash
scripts/perf-capture.sh build            # profile apk with the perf defines
scripts/perf-capture.sh drive baseline-01
scripts/perf-capture.sh baseline baseline-01
scripts/perf-capture.sh drive candidate-01
scripts/perf-capture.sh compare candidate-01 baseline-01
```

`drive` builds and installs its own `integration_test` target; `build` only
produces the apk used for the install-and-grant step that precedes it.

`drive` runs `integration_test/onboarding_flow_test.dart` through
`flutter drive`. The test boots `app.main(['--force-onboarding', '--no-account'])`
and taps whichever advance control is on screen (`_advanceLabels`, with
`Continue to Dashboard` gated on a connected machine). `--no-account` removes
the Decent account step entirely rather than trying to tap through it.

The tap set is intended to be identical per run, but the run is **not**
byte-for-byte reproducible: the driver requests frames with `tester.pump` under
`fullyLive`, BLE discovery timing shifts which controls appear, and observed tap
counts varied between 2 and 3. Compare rates, not counts.

Manual (when the automated flow cannot reach what you want to measure):

```bash
scripts/perf-capture.sh run baseline-01 --wait 90   # drive it yourself
scripts/perf-capture.sh shot                        # screencap to inspect a stall
```

## How the report reaches the host

The integration test hands the JSON back through `binding.reportData`, which the
driver writes to `build/perf/integration_response.json`. Do not rely on logcat
for collection: the transport truncates long lines and the app logs at FINE
level, so a 90 s capture rotates chunks out of the buffer. `collect` falls back
to the in-app report file (`app_flutter/perf/latest.json`, read via `run-as`)
and then to logcat chunks. `drive` uses the same collector, so it inherits those
fallbacks when `reportData` is missing - which is one reason a stale capture can
be picked up (Known limitations item 3).

## Reading the numbers

`build` is the UI thread. `raster` is the raster/GPU thread.

- **build p90 above budget** - the UI thread spent that long building frames:
  synchronous IO, JSON decoding, rebuild storms, or long `setState` chains.
- **raster p90 above budget, build fine** - painting/blur/overdraw cost on the
  raster thread.
- **`janky_build_pct` high with low `build p90`** - frequent short stalls
  rather than one slow path.
- **`fps_effective` much below the refresh rate with low build and raster** -
  the segment rendered few frames. That is consistent with an idle screen, but
  it is also consistent with blocking that produced no frames at all; the frame
  data alone cannot separate them.

Low `build p90` does **not** prove the main isolate is not blocking. Only
`buildDuration` and `rasterDuration` are retained; work that delays a frame from
starting shows up in `vsyncOverhead`, and a block between frame callbacks need
not produce a long build frame at all. Retaining `vsyncOverhead` and `totalSpan`
is outstanding work. `max_gap_ms` measures the interval between rendered vsyncs
only, and a static screen followed by a tap produces the same signature as a
stall, so it cannot distinguish the two on its own.

`compare` classifies against the frame budget rather than percentage drift, but
it only looks at `build`. A raster regression from 5 ms to 100 ms still reads
`ok`. Judge raster columns by eye until that is fixed.

## Exploratory capture (M50Mini, 60 Hz, real DE1 emulator)

Recorded 2026-11-13 with the automated flow, against an ESP32-S3 DE1 emulator
(see `~/development/work/cyd-quickjs-poc`) connected over real BLE. Treat these
as a starting point, **not** a regression baseline: the attribution bug and the
gap-metric caveats above are unresolved.

- The UI thread was never the largest observed cost in this flow, but that is
  weaker than "not blocking": see the `vsyncOverhead` caveat above.
- The largest observed values were raster-side. `onboarding:import` measured
  3 frames with `build p90` 16.96-17.95 ms, `build max` 16.96 ms and `raster
  p90/max` 140-174 ms. The sample is three frames and the report keeps no frame
  order, so calling that "first paint" is an inference, not a measurement.
- `onboarding:welcome` measured raster p90 25.6-33.97 ms over 3-12 frames.
- `onboarding:scan` measured `raster max` 135-144 ms with `build p90` 1.1-7.2 ms.
- Per-segment `build p90` across the whole flow ranged 0.4-5.5 ms, with the
  16.96-17.95 ms import segment as the exception. Quote per-segment numbers;
the report has no pooled distribution, so there is no "aggregate build p90".

Step attribution is marked in `OnboardingView.build`, so it follows whatever
step is rendered. Segments go missing for two different reasons:

- `initialization`: `BootTiming.mark('init_start')` fires inside
  `_initializeServices()` and immediately supersedes the step marker.
- `permissions`: `scripts/perf-capture.sh` pre-grants the Bluetooth and
  notification permissions, so the step's `shouldShow` excludes it entirely in
  automated runs. It appears in manual runs where the grant has not happened.

## Known limitations

Ordered by how much they undermine the numbers. Do not present conclusions that
depend on an unresolved item here.

1. **Segment attribution is wrong.** Marks are indexed by delivered timings, so
   in-flight frames land in the newer segment and marks within one batch
   collapse. Per-segment conclusions are approximate. Needs attribution by
   engine vsync timestamps plus a delayed-batch regression test.
2. **Main-isolate blocking is underdetected.** `vsyncOverhead` and `totalSpan`
   are not retained, so blocking that delays a frame from starting is invisible.
3. **A stale capture can be labelled as a fresh run.** `collect` prefers the
   shared `integration_response.json` regardless of label, and `run` never
   clears it, so a failed run can be stamped with an older report. Clear it at
   run start and validate freshness until a run id is threaded through.
4. **The driver injects frames.** `tester.pump` under `fullyLive` requests
   frames that the product would not render, changing frame counts, effective
   FPS and gap distributions. Not equivalent to a hand-driven run.
5. **The driver's only assertion is `taps > 0`,** and `drive` suppresses the
   driver's exit status when collecting. A stalled flow can therefore present as
   a successful capture. Check `taps` and the `devices` line in the drive log.
6. **Samples are tiny for short segments.** Three-frame segments get confident
   percentile output. Anything under ~30 frames is anecdote.
7. **`skin:loading` and `skin:ready` are the renderer health check.** They sit in
   `InAppWebView.onLoadStart` / `onLoadStop` (`skin_view.dart`) and fire normally
   on a healthy device: a full run measured `skin:mount` 46 frames,
   `skin:loading` 37 frames (`build p90` 1.43 ms, `raster p90` 8.07 ms) and
   `skin:ready` 19921 frames at 53.45 fps (`build p90` 0.59 ms, `raster p90`
   5.78 ms). If `skin:mount` is the last segment and neither later marker appears,
   the WebView renderer is dead - see the SandboxedProcessService pitfall - and no
   frame number from that run means anything.
8. **Statistics are prefix statistics past the sample cap.** After 20,000 frames
   in one segment, averages and percentiles describe only the first 20,000 while
   maxima and jank percentages cover the whole segment.

## Pitfalls

- **A dead WebView renderer looks exactly like a slow skin.** If
  `ActivityManager` logs `Unable to launch app <pkg>/<uid> for service Intent {
  cmp=<pkg>/org.chromium.content.app.SandboxedProcessService... }` and
  `cr_ChildProcessConn: Failed to establish the service connection`, the WebView
  has no renderer: the root document's first paint stays on screen (often the
  skin's own CSS spinner), no JavaScript executes, and nothing recovers on its
  own. Confirmed on the M50Mini: after this pair of lines, `Runtime.evaluate`
  over Chrome DevTools hangs indefinitely and the UI server logs only
  `GET [200] /` with no subresource requests. A device reboot clears it; a fresh
  install or `clearAllCache()` does not.
- **Don't force-stop the app right before launching it.** Repeated
  `am force-stop` plus rapid relaunch is what wedged the renderer above.
  `scripts/perf-capture.sh drive` no longer force-stops unless `--fresh` is
  passed, and it greps logcat afterwards for the failure and warns. If a capture
  shows a suspiciously static `skin:mount`, reboot before believing it.

- **A static screen produces no frames.** The engine only reports frames it
  rendered, so a capture that sits on an unchanging screen logs a handful of
  frames over ten seconds and tells you nothing. Drive the flow. `ShadProgress()`
  animates, so animated steps are measurable; a static screen is not.
- **`--esal`, never `--esa`, for app arguments.** Flutter's
  `FlutterFragmentActivity.getDartEntrypointArgs()` casts the intent extra to
  `ArrayList<String>`. `am start --esa` stores a `String[]` and crashes the app
  with `ClassCastException: java.lang.String[] cannot be cast to java.util.List`
  on launch. `scripts/perf-capture.sh` uses `--esal`.
- **Grant Android permissions before `flutter drive`, not before install.**
  `flutter drive` installs the target apk itself and uninstalls it afterwards, so
  `pm grant` against a missing package fails silently and the run stalls on the
  Bluetooth permission dialog. `drive` installs the perf apk first, then grants,
  then drives; a reinstall preserves runtime grants.
- **Boot the app outside `testWidgets`.** `main()` calls
  `SemanticsBinding.instance.ensureSemantics()` and never disposes the handle, so
  calling `app.main()` inside the test body fails the run with "A SemanticsHandle
  was active at the end of the test", and a failed test never delivers
  `reportData`. Calling `app.main()` before `testWidgets` makes the handle part of
  the baseline count and the test passes.
- **Debug builds do not measure the product.** `scripts/sb-dev.sh` runs
  `flutter run` in debug: JIT, no AOT, checked mode, and assertions. Stutter seen
  in a debug build is not evidence of stutter in a shipped build. Captures must
  come from a profile build.
- **Screen recording changes the result.** Recording the flow through
  `adb screenrecord` or a mirroring tool adds load. Capture without recording,
  and treat any recording run as a separate, non-comparable data point.
- **Compare rates, not counts.** Segment frame counts depend on how long the
  operator took on each step and on driver pump behaviour. `p90` and `max` are
  more comparable than `frames` or `wall_ms`, but they are not statistically
  stable - quote the sample count with them.
- **One device, one baseline.** Baselines are device-specific. `M50Mini`
  (Android 14, 60 Hz) numbers do not transfer to a phone or a desktop.
- A total block between frames can produce **no frame at all**, so `build max`
  can look healthy during a visible freeze. `max_gap_ms` catches part of that,
  but an idle screen produces the same signal. Watch for Android's own
  `Choreographer: Skipped N frames` line in logcat as an independent check.
