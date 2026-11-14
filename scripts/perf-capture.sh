#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${PERF_OUT_DIR:-$ROOT/build/perf}"
BASELINE_DIR="${PERF_BASELINE_DIR:-$OUT_DIR/baseline}"
APK="$OUT_DIR/app-profile.apk"
PKG="${PERF_PACKAGE:-net.tadel.reaprime}"
ACTIVITY="${PERF_ACTIVITY:-.MainActivity}"
CHUNK_PREFIX="PERF_CHUNK "
REPORT_PATH="${PERF_REPORT_PATH:-app_flutter/perf/latest.json}"

if ! command -v jq >/dev/null 2>&1; then
  echo "error: jq is required for perf-capture" >&2
  exit 1
fi

usage() {
  cat <<'EOF'
perf-capture.sh - repeatable frame-timing capture for Decaid

Builds and runs a PROFILE build with in-app frame profiling (FrameProfiler),
then compares captures against a saved baseline.

Usage:
  perf-capture.sh build [--real] [--refresh-hz N]
  perf-capture.sh install [--fresh]
  perf-capture.sh run <label> [--wait SECS] [--fresh] [--no-force-onboarding]
  perf-capture.sh drive <label> [--real] [--refresh-hz N] [--shots] [--record]
                        [--preferred-machine-id ID] [--preferred-scale-id ID]
                        [--seconds N] [--skip-webview-compat] [--simulate V]
                        [--skin ID]
  perf-capture.sh collect <label>
  perf-capture.sh shot [name]
  perf-capture.sh show <label>
  perf-capture.sh compare <label> [baseline-label]
  perf-capture.sh baseline <label>
  perf-capture.sh list
  perf-capture.sh devices

Commands:
  build        flutter build apk --profile with perfFrames=1 (+ simulate=1 unless --real)
  install      adb install the built profile apk; --fresh uninstalls first
  run          force-stop, reset capture, launch, wait, then collect
  drive        integration_test driver taps through onboarding, then collect
  collect      pull the last capture from the device into build/perf/<label>.json
  shot         screencap to build/perf/shots/, for observing a run
  show         print the per-segment frame table for a capture
  compare      diff a capture against a baseline (default: baseline/<label>.json)
  baseline     copy a capture to the baseline directory
  list         list captures and baselines
  devices      list attached adb devices

Options:
  --fresh                 uninstall before launching (true cold first-run; re-arms onboarding)
  --no-force-onboarding   do not pass --force-onboarding to the app  --wait SECS             seconds to wait for the flow before collecting (default 90)
  --real                  build without --dart-define=simulate=1 (real BLE/USB devices)
  --refresh-hz N          display refresh rate used for the jank budget (default 60)
  --shots                 screencap every 10s during drive (perturbs the capture)
  --record                screenrecord the run to build/perf/<label>.mp4 (perturbs more)

Env:
  PERF_DEVICE          adb serial (default: the single attached device)
  PERF_OUT_DIR         capture output dir (default <repo>/build/perf)
  PERF_BASELINE_DIR    baseline dir (default <PERF_OUT_DIR>/baseline)

The instrument is off in normal builds. Only builds made by this script carry
--dart-define=perfFrames=1, which installs a SchedulerBinding timings callback.
EOF
}

die() {
  echo "error: $*" >&2
  exit 1
}

resolve_device() {
  if [[ -n "${PERF_DEVICE:-}" ]]; then
    printf '%s' "$PERF_DEVICE"
    return
  fi
  local devices=() line
  while IFS= read -r line; do
    devices+=("$line")
  done < <(adb devices | awk 'NR>1 && $2=="device" {print $1}')
  if [[ ${#devices[@]} -eq 0 ]]; then
    die "no adb device attached"
  fi
  if [[ ${#devices[@]} -gt 1 ]]; then
    echo "error: multiple devices attached; set PERF_DEVICE" >&2
    printf '  %s\n' "${devices[@]}" >&2
    exit 1
  fi
  printf '%s' "${devices[0]}"
}

capture_path() {
  printf '%s/%s.json' "$OUT_DIR" "$1"
}

cmd_build() {
  local real=0 refresh_hz=60 sim_value=1
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --real) real=1; shift ;;
      --refresh-hz) refresh_hz="$2"; shift 2 ;;
      --simulate) sim_value="$2"; shift 2 ;;
      *) die "unknown build option: $1" ;;
    esac
  done

  mkdir -p "$OUT_DIR"
  local -a defines=(
    "--dart-define=perfFrames=1"
    "--dart-define=perfRefreshHz=$refresh_hz"
  )
  [[ "$real" -eq 0 ]] && defines+=("--dart-define=simulate=$sim_value")

  echo "Building profile apk (perf capture on, simulate=$((1 - real)), ${refresh_hz}Hz budget)..."
  ( cd "$ROOT" && flutter build apk --profile --no-tree-shake-icons ${defines[@]+"${defines[@]}"} )
  local built="$ROOT/build/app/outputs/flutter-apk/app-profile.apk"
  [[ -f "$built" ]] || die "profile apk not found at $built"
  cp "$built" "$APK"
  echo "APK: $APK"
}

cmd_install() {
  local fresh=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --fresh) fresh=1; shift ;;
      *) die "unknown install option: $1" ;;
    esac
  done
  [[ -f "$APK" ]] || die "no apk at $APK - run 'perf-capture.sh build' first"
  local device
  device="$(resolve_device)"
  if [[ "$fresh" -eq 1 ]]; then
    adb -s "$device" uninstall "$PKG" >/dev/null 2>&1 || true
  fi
  adb -s "$device" install -r -t "$APK"
}

launch_app() {
  local device="$1" force_onboarding="$2"
  local args=""
  [[ "$force_onboarding" -eq 1 ]] && args="--esal dart_entrypoint_args '--force-onboarding'"
  adb -s "$device" shell \
    "am start -W -n $PKG/$ACTIVITY ${args}" >/dev/null
}

cmd_run() {
  local label="" wait_secs=90 fresh=0 force_onboarding=1
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --wait) wait_secs="$2"; shift 2 ;;
      --fresh) fresh=1; shift ;;
      --no-force-onboarding) force_onboarding=0; shift ;;
      -*) die "unknown run option: $1" ;;
      *) label="$1"; shift ;;
    esac
  done
  [[ -n "$label" ]] || die "run needs a label, e.g. 'perf-capture.sh run baseline-01'"
  [[ -f "$APK" ]] || die "no apk at $APK - run 'perf-capture.sh build' first"

  local device
  device="$(resolve_device)"
  mkdir -p "$OUT_DIR"

  if [[ "$fresh" -eq 1 ]]; then
    adb -s "$device" uninstall "$PKG" >/dev/null 2>&1 || true
  fi
  adb -s "$device" install -r -t "$APK" >/dev/null
  adb -s "$device" shell am force-stop "$PKG"
  adb -s "$device" logcat -c

  echo "Launching $label on $device"
  launch_app "$device" "$force_onboarding"

  echo "Recording. Drive the flow now; collecting in ${wait_secs}s."
  local started_at
  started_at="$(date +%s)"
  sleep "$wait_secs"
  echo "Elapsed $(( $(date +%s) - started_at ))s"

  if ! adb -s "$device" logcat -d | grep -q "PERF_CHUNK "; then
    die "no capture data found - is the installed apk a perf build? (PERF_READY missing)"
  fi
  cmd_collect "$label"
}

reassemble_chunks() {
  sed -n 's/.*PERF_CHUNK \([0-9]*\) \([0-9]*\) \(.*\)$/\1 \2 \3/p' \
    | awk '
        {
          idx = $1 + 0
          total = $2 + 0
          payload = $0
          sub(/^[0-9]+ [0-9]+ /, "", payload)
          if (idx == 1) { buf = payload; got = 1; need = total }
          else if (got > 0) { buf = buf payload; got++ }
          if (need > 0 && got == need) { last = buf; got = 0; need = 0 }
        }
        END { if (last != "") print last }
      '
}

read_capture_payload() {
  local device="$1" log_file="$2" payload=""
  payload="$(adb -s "$device" exec-out run-as "$PKG" cat "$REPORT_PATH" 2>/dev/null | tr -d '\r' || true)"
  if printf '%s' "$payload" | jq -e . >/dev/null 2>&1; then
    printf '%s' "$payload"
    return 0
  fi
  if [[ -n "$log_file" && -f "$log_file" ]]; then
    payload="$(reassemble_chunks < "$log_file")"
    if printf '%s' "$payload" | jq -e . >/dev/null 2>&1; then
      printf '%s' "$payload"
      return 0
    fi
  fi
  adb -s "$device" logcat -d | reassemble_chunks
}

grant_permissions() {
  local device="$1" perm
  for perm in \
    android.permission.BLUETOOTH_SCAN \
    android.permission.BLUETOOTH_CONNECT \
    android.permission.POST_NOTIFICATIONS \
    android.permission.CAMERA; do
    adb -s "$device" shell pm grant "$PKG" "$perm" >/dev/null 2>&1 || true
  done
  adb -s "$device" shell dumpsys deviceidle whitelist +"$PKG" >/dev/null 2>&1 || true
}

cmd_drive() {
  local label="" real=0 refresh_hz=60 shots=0
  local preferred_machine="" preferred_scale="" seconds=60 skip_compat=0 sim_value=1
  local record=0 skin=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --real) real=1; shift ;;
      --refresh-hz) refresh_hz="$2"; shift 2 ;;
      --shots) shots=1; shift ;;
      --record) record=1; shift ;;
      --preferred-machine-id) preferred_machine="$2"; shift 2 ;;
      --preferred-scale-id) preferred_scale="$2"; shift 2 ;;
      --seconds) seconds="$2"; shift 2 ;;
      --skip-webview-compat) skip_compat=1; shift ;;
      --simulate) sim_value="$2"; shift 2 ;;
      --skin) skin="$2"; shift 2 ;;
      -*) die "unknown drive option: $1" ;;
      *) label="$1"; shift ;;
    esac
  done
  [[ -n "$label" ]] || die "drive needs a label"
  [[ -f "$APK" ]] || die "no apk at $APK - run 'perf-capture.sh build' first"

  local device
  device="$(resolve_device)"
  mkdir -p "$OUT_DIR"

  adb -s "$device" install -r -t "$APK" >/dev/null
  grant_permissions "$device"
  if [[ "${fresh:-0}" -eq 1 ]]; then
    adb -s "$device" shell am force-stop "$PKG" || true
  fi

  local -a defines=(
    "--dart-define=perfFrames=1"
    "--dart-define=perfRefreshHz=$refresh_hz"
    "--dart-define=perfDriveSeconds=$seconds"
  )
  [[ "$real" -eq 0 ]] && defines+=("--dart-define=simulate=$sim_value")
  [[ -n "$preferred_machine" ]] && \
    defines+=("--dart-define=preferredMachineId=$preferred_machine")
  [[ -n "$preferred_scale" ]] && \
    defines+=("--dart-define=preferredScaleId=$preferred_scale")
  [[ "$skip_compat" -eq 1 ]] && \
    defines+=("--dart-define=perfSkipWebViewCompat=1")
  [[ -n "$skin" ]] && defines+=("--dart-define=perfSkin=$skin")

  local shot_pid=""
  local record_pid=""
  if [[ "$shots" -eq 1 ]]; then
    mkdir -p "$OUT_DIR/shots"
    (
      while true; do
        adb -s "$device" exec-out screencap -p \
          > "$OUT_DIR/shots/$label-$(date +%s).png" 2>/dev/null || true
        sleep 10
      done
    ) &
    shot_pid=$!
  fi

  if [[ "$record" -eq 1 ]]; then
    adb -s "$device" shell rm -f "/sdcard/$label.mp4" >/dev/null 2>&1 || true
    adb -s "$device" shell screenrecord --bit-rate 4000000 \
      --time-limit "$((seconds + 60))" "/sdcard/$label.mp4" >/dev/null 2>&1 &
    record_pid=$!
  fi

  local visual="clean"
  [[ "${shots:-0}" -eq 1 && "${record:-0}" -eq 1 ]] && visual="shots+record"
  [[ "${shots:-0}" -eq 1 && "${record:-0}" -eq 0 ]] && visual="shots"
  [[ "${shots:-0}" -eq 0 && "${record:-0}" -eq 1 ]] && visual="record"

  local drive_log="$OUT_DIR/$label.drive.log"
  printf '%s' "$visual" > "$OUT_DIR/$label.visual"
  local status=0
  rm -f "$OUT_DIR/integration_response.json"
  ( cd "$ROOT" && flutter drive \
      --profile \
      -d "$device" \
      --driver=test_driver/integration_test.dart \
      --target=integration_test/onboarding_flow_test.dart \
      ${defines[@]+"${defines[@]}"} ) 2>&1 | tee "$drive_log" || status=${PIPESTATUS[0]}

  if [[ -n "$shot_pid" ]]; then
    kill "$shot_pid" 2>/dev/null || true
    wait "$shot_pid" 2>/dev/null || true
  fi

  if [[ -n "$record_pid" ]]; then
    kill "$record_pid" 2>/dev/null || true
    adb -s "$device" shell pkill -INT screenrecord >/dev/null 2>&1 || true
    sleep 2
    adb -s "$device" pull "/sdcard/$label.mp4" "$OUT_DIR/$label.mp4" >/dev/null 2>&1 || true
    adb -s "$device" shell rm -f "/sdcard/$label.mp4" >/dev/null 2>&1 || true
    [[ -f "$OUT_DIR/$label.mp4" ]] && echo "Video: $OUT_DIR/$label.mp4"
  fi

  if [[ "$status" -ne 0 ]]; then
    echo "driver exited $status; collecting anyway (teardown assertions are expected to fail)" >&2
  fi

  if adb -s "$device" logcat -d 2>/dev/null \
      | grep -q 'cr_ChildProcessConn.*Failed to establish the service connection'; then
    echo >&2
    echo "WARNING: WebView sandboxed renderer failed to start this run." >&2
    echo "  Symptom: skin stays on its loading spinner; page JS never executes;" >&2
    echo "  Runtime.evaluate over DevTools hangs. Repeated am force-stop / rapid" >&2
    echo "  relaunch wedges it. Reboot the device before trusting this capture." >&2
    echo >&2
  fi

  cmd_collect "$label"
}

cmd_collect() {
  local label="$1"
  local device
  device="$(resolve_device)"
  mkdir -p "$OUT_DIR"

  local payload=""
  local response="$OUT_DIR/integration_response.json"
  if [[ -f "$response" ]]; then
    payload="$(jq -r '.perf_report // empty' "$response" 2>/dev/null || true)"
  fi
  if ! printf '%s' "$payload" | jq -e . >/dev/null 2>&1; then
    payload="$(read_capture_payload "$device" "$OUT_DIR/$label.drive.log")"
  fi

  [[ -n "$payload" ]] || die "no capture found (looked for reportData, $REPORT_PATH, the drive log, and logcat)"
  printf '%s' "$payload" | jq -e . >/dev/null 2>&1 \
    || die "capture payload is not valid JSON (partial write or rotated logcat buffer)"

  local out
  out="$(capture_path "$label")"
  local visual="unknown"
  [[ -f "$OUT_DIR/$label.visual" ]] && visual="$(cat "$OUT_DIR/$label.visual")"
  jq -n \
    --arg label "$label" \
    --arg captured_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg device_model "$(adb -s "$device" shell getprop ro.product.model | tr -d '\r')" \
    --arg device_serial "$device" \
    --arg build "$(cd "$ROOT" && git rev-parse --short HEAD 2>/dev/null || echo unknown)" \
    --arg visual "$visual" \
    --argjson report "$payload" \
    '{label: $label, captured_at: $captured_at,
      device: {model: $device_model, serial: $device_serial},
      build: $build, visual_evidence: $visual, report: $report}' > "$out"

  echo "Captured: $out"
  cmd_show "$label"
}

cmd_show() {
  local label="$1"
  local file
  file="$(capture_path "$label")"
  [[ -f "$file" ]] || die "no capture named '$label' ($file)"

  jq -r '
    . as $root
    | ($root.report.budget_ms | tostring) as $budget
    | "\($root.label)  build=\($root.build)  device=\($root.device.model)  budget=\($budget)ms  frames=\($root.report.frames_total)  visual=\($root.visual_evidence // "unknown")",
      "",
      ([ "segment", "frames", "fps", "build p50", "build p90", "build max", "raster p90", "gap max", "gaps>100ms", "janky build", "janky raster" ] | @tsv),
      ($root.report.segments[]
        | [ .id, .frames, .fps_effective, .build.p50_ms, .build.p90_ms,
            .build.max_ms, .raster.p90_ms, .max_gap_ms, .long_gaps,
            "\(.janky_build) (\(.janky_build_pct)%)",
            "\(.janky_raster) (\(.janky_raster_pct)%)" ]
        | @tsv)
  ' "$file" | column -t -s $'\t'
}

cmd_compare() {
  local label="$1"
  local baseline_label="${2:-$label}"
  local current baseline
  current="$(capture_path "$label")"
  baseline="$BASELINE_DIR/$baseline_label.json"
  [[ -f "$current" ]] || die "no capture named '$label'"
  [[ -f "$baseline" ]] || die "no baseline named '$baseline_label' ($baseline)"

  echo "compare: $label  vs  baseline/$baseline_label"
  jq -r -n --argjson floor 30 --slurpfile b "$baseline" --slurpfile c "$current" '
    def agg($r):
      $r.report.segments
      | group_by(.id)
      | map(
          . as $g
          | ($g | map(.build.p90_ms) | max) as $bp
          | ($g | map(.raster.p90_ms) | max) as $rp
          | {
              id: $g[0].id,
              occurrences: ($g | length),
              frames: ($g | map(.frames) | add),
              build_p90: $bp,
              build_p90_n: ($g | map(select(.build.p90_ms == $bp) | .frames) | max),
              raster_p90: $rp,
              raster_p90_n: ($g | map(select(.raster.p90_ms == $rp) | .frames) | max),
              build_max: ($g | map(.build.max_ms) | max),
              raster_max: ($g | map(.raster.max_ms) | max),
              jank_build: ($g | map(.janky_build) | add),
              jank_raster: ($g | map(.janky_raster) | add),
              truncated: ($g | map(.samples_truncated == true) | any)
            }
        )
      | map(. + {
          jank_build_pct: (if .frames > 0 then ((.jank_build * 10000 / .frames) | round) / 100 else 0 end),
          jank_raster_pct: (if .frames > 0 then ((.jank_raster * 10000 / .frames) | round) / 100 else 0 end)
        })
      | map({key: .id, value: .})
      | from_entries;

    def state($o; $pk; $budget):
      if $o == null then "MISSING"
      elif ($o[$pk + "_n"] // 0) < $floor then "INSUFFICIENT SAMPLES"
      elif $o.truncated then "TRUNCATED SAMPLES"
      elif $o[$pk] > $budget then "OVER BUDGET"
      else "AT/BELOW BUDGET" end;

    def signal($bo; $co; $jk; $comparable):
      if $bo == null then "NEW SEGMENT"
      elif $co == null then "MISSING SEGMENT"
      elif ($comparable | not) then "NOT COMPARABLE"
      elif ($bo.frames < $floor) and ($co.frames < $floor) then "INSUFFICIENT SAMPLES (BOTH)"
      elif $bo.frames < $floor then "INSUFFICIENT SAMPLES (BASE)"
      elif $co.frames < $floor then "INSUFFICIENT SAMPLES (NOW)"
      elif ($co[$jk] - $bo[$jk]) > 0 then "OBSERVED UP"
      elif ($bo[$jk] - $co[$jk]) > 0 then "OBSERVED DOWN"
      else "NO OBSERVED CHANGE" end;

    ($b[0]) as $base | ($c[0]) as $cur
    | agg($base) as $bm | agg($cur) as $cm
    | ($base.report.budget_ms) as $bbudget
    | ($cur.report.budget_ms) as $budget
    | (($bbudget == $budget)
       and ($base.report.refresh_hz == $cur.report.refresh_hz)
       and ($base.device.model == $cur.device.model)
       and ($base.device.serial == $cur.device.serial)
       and (($base.visual_evidence // "unknown") == ($cur.visual_evidence // "unknown"))
       and (($base.visual_evidence // "unknown") != "unknown")) as $comparable
    | "base \($base.label) budget \($bbudget)ms    now \($cur.label) budget \($budget)ms",
      (if $comparable then "configuration matches"
       else "WARNING: configurations differ (budget, refresh, device or visual mode) - paired signals suppressed" end),
      "",
      "BUILD (UI thread)   p90 guarded on the frame count of the worst occurrence, not the sum",
      ([ "segment", "frames", "base p90", "now p90", "base max", "now max",
         "base jank%", "now jank%", "base state", "now state", "jank signal" ] | @tsv),
      ( ($bm | keys) + ($cm | keys) | unique[] as $id
        | ($bm[$id]) as $bo | ($cm[$id]) as $co
        | [ (if $co != null then $co.id else $bo.id end),
            (if $co != null then $co.frames else $bo.frames end),
            ($bo.build_p90 // "-"), ($co.build_p90 // "-"),
            ($bo.build_max // "-"), ($co.build_max // "-"),
            ($bo.jank_build_pct // "-"), ($co.jank_build_pct // "-"),
            state($bo; "build_p90"; $bbudget), state($co; "build_p90"; $budget),
            signal($bo; $co; "jank_build_pct"; $comparable) ]
        | @tsv ),
      "",
      "RASTER (GPU thread)   same guards; a raster-only regression shows here",
      ([ "segment", "frames", "base p90", "now p90", "base max", "now max",
         "base jank%", "now jank%", "base state", "now state", "jank signal" ] | @tsv),
      ( ($bm | keys) + ($cm | keys) | unique[] as $id
        | ($bm[$id]) as $bo | ($cm[$id]) as $co
        | [ (if $co != null then $co.id else $bo.id end),
            (if $co != null then $co.frames else $bo.frames end),
            ($bo.raster_p90 // "-"), ($co.raster_p90 // "-"),
            ($bo.raster_max // "-"), ($co.raster_max // "-"),
            ($bo.jank_raster_pct // "-"), ($co.jank_raster_pct // "-"),
            state($bo; "raster_p90"; $bbudget), state($co; "raster_p90"; $budget),
            signal($bo; $co; "jank_raster_pct"; $comparable) ]
        | @tsv )
  ' | column -t -s $'\t'
}

cmd_baseline() {
  local label="$1"
  local file
  file="$(capture_path "$label")"
  [[ -f "$file" ]] || die "no capture named '$label'"
  mkdir -p "$BASELINE_DIR"
  cp "$file" "$BASELINE_DIR/$label.json"
  echo "Baseline: $BASELINE_DIR/$label.json"
}

cmd_screenshot() {
  local name="${1:-shot-$(date +%s)}"
  local device
  device="$(resolve_device)"
  mkdir -p "$OUT_DIR/shots"
  adb -s "$device" exec-out screencap -p > "$OUT_DIR/shots/$name.png"
  echo "$OUT_DIR/shots/$name.png"
}

cmd_list() {
  echo "captures ($OUT_DIR):"
  local found=0 f
  for f in "$OUT_DIR"/*.json; do
    [[ -e "$f" ]] || continue
    found=1
    printf '  %-24s %s\n' "$(basename "$f" .json)" "$(jq -r '.captured_at // "?"' "$f")"
  done
  [[ "$found" -eq 1 ]] || echo "  (none)"
  echo "baselines ($BASELINE_DIR):"
  found=0
  for f in "$BASELINE_DIR"/*.json; do
    [[ -e "$f" ]] || continue
    found=1
    printf '  %s\n' "$(basename "$f" .json)"
  done
  [[ "$found" -eq 1 ]] || echo "  (none)"
}

cmd_devices() {
  adb devices -l
}

cmd="${1:-help}"
shift || true

case "$cmd" in
  build) cmd_build "$@" ;;
  install) cmd_install "$@" ;;
  run) cmd_run "$@" ;;
  drive) cmd_drive "$@" ;;
  collect) cmd_collect "${1:?collect needs a label}" ;;
  shot) cmd_screenshot "${1:-}" ;;
  show) cmd_show "${1:?show needs a label}" ;;
  compare) cmd_compare "$@" ;;
  baseline) cmd_baseline "${1:?baseline needs a label}" ;;
  list) cmd_list ;;
  devices) cmd_devices ;;
  help | -h | --help) usage ;;
  *) echo "unknown command: $cmd" >&2; usage >&2; exit 1 ;;
esac
