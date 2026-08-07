#!/usr/bin/env bash
# sb-dev.sh — Decent dev-session manager
# Manages a `flutter run` process for simulate-mode development by default,
# with opt-in flags for running against real hardware (including Android
# devices via adb port forwarding). See
# .agents/skills/decent-app/lifecycle.md for the full reference.
# Runtime state lives under $SB_RUNTIME_DIR (default /tmp/decent-$USER).

set -euo pipefail

RUNTIME_DIR="${SB_RUNTIME_DIR:-/tmp/decent-${USER:-default}}"
PIDFILE="$RUNTIME_DIR/flutter.pid"
HOLDER_PIDFILE="$RUNTIME_DIR/holder.pid"
STDIN_FIFO="$RUNTIME_DIR/stdin"
LOGFILE="$RUNTIME_DIR/flutter.log"
FLAGSFILE="$RUNTIME_DIR/last-flags"
ADB_FORWARD_MARK="$RUNTIME_DIR/adb-forwarded"
HOST="${SB_HOST:-localhost}"
PORT="${SB_PORT:-8080}"
BASE_URL="http://$HOST:$PORT"

if ! command -v jq >/dev/null 2>&1; then
  echo "error: jq is required for sb-dev (install via your package manager, e.g. 'brew install jq' / 'apt install jq' / 'pacman -S jq')" >&2
  exit 1
fi

cmd="${1:-help}"
shift || true

usage() {
  cat <<'EOF'
sb-dev.sh — Decent dev-session manager

Usage:
  sb-dev start [--platform <id>] [--connect-machine <name|id>] [--connect-scale <name|id>]
               [--preferred-machine-id <id>] [--preferred-scale-id <id>]
               [--real] [--adb-forward] [--dart-define k=v]
  sb-dev stop
  sb-dev restart           — cold restart with the same flags as the last start
  sb-dev reload            — hot reload (preserves app state)
  sb-dev hot-restart       — hot restart (resets app state, reloads code)
  sb-dev status            — pid + http reachability + devices
  sb-dev logs [-n 50] [--filter text]
  sb-dev help

Flags:
  --platform <id>          Flutter device id (`-d` passthrough). Examples: macos,
                           linux, chrome, or an Android adb serial like 8734SCCFAC00000747.
  --connect-machine <v>    Match by device name OR id in the post-boot scan loop.
                           In simulate mode also drives preferredMachineId (the
                           mock's name == its id). In --real mode a name like
                           "DE1" won't match a BLE MAC deviceId, so pair with
                           --preferred-machine-id if you want auto-connect
                           based on a saved preference.
  --connect-scale <v>      Same semantics for the scale.
  --preferred-machine-id <id>   Explicit --dart-define=preferredMachineId=<id>.
                                Use with --real to pin the preferred device to
                                a BLE MAC or UUID that ConnectionManager
                                actually matches on.
  --preferred-scale-id <id>     Same for the scale.
  --real                   Do NOT inject --dart-define=simulate=1. Use real BLE/USB.
  --adb-forward            Run `adb forward tcp:$PORT tcp:$PORT` on start so host
                           localhost:$PORT reaches the REST server on an Android
                           device. Removed on stop.
  --dart-define k=v        Extra --dart-define passed to flutter (repeatable).

Env:
  SB_RUNTIME_DIR  runtime state directory (default: /tmp/decent-$USER)
  SB_HOST         host for curl checks (default: localhost)
  SB_PORT         port for curl checks (default: 8080)
EOF
}

init_runtime() {
  mkdir -p "$RUNTIME_DIR"
}

is_running() {
  [[ -f "$PIDFILE" ]] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null
}

wait_ready() {
  local start timeout=120
  start=$(date +%s)
  while (( $(date +%s) - start < timeout )); do
    if curl -sf "$BASE_URL/api/v1/devices" >/dev/null 2>&1; then
      echo "HTTP server ready"
      return 0
    fi
    if ! is_running; then
      echo "Flutter process exited before becoming ready. Last logs:" >&2
      tail -n 30 "$LOGFILE" >&2 || true
      return 1
    fi
    sleep 1
  done
  echo "Timed out after ${timeout}s waiting for HTTP ready" >&2
  return 1
}

connect_machine() {
  local needle="$1" start
  start=$(date +%s)
  # Re-scan each iteration: early post-boot scans can return empty
  # (simulate service may not have populated yet, and real BLE scans
  # take ~15 s), so we retry within the 30 s window rather than trusting
  # a single scan result. Each scan call blocks until
  # ConnectionManager.connect() completes, so the loop self-paces.
  # Match by either device name or id so callers can pass "DE1" or a
  # BLE MAC like "D9:11:0B:E6:9F:86" against real hardware.
  while (( $(date +%s) - start < 30 )); do
    curl -sf "$BASE_URL/api/v1/devices/scan?connect=true" >/dev/null || {
      echo "Scan request failed" >&2
      return 1
    }
    local devices
    devices=$(curl -sf "$BASE_URL/api/v1/devices" || echo "[]")
    if printf '%s' "$devices" \
         | jq -e --arg needle "$needle" '
             .[] | select(
               (.name == $needle or .id == $needle)
               and .state == "connected"
             )' \
           >/dev/null 2>&1; then
      echo "Connected to $needle"
      return 0
    fi
    sleep 1
  done
  echo "Timed out waiting for $needle to connect" >&2
  return 1
}

start_cmd() {
  init_runtime
  if is_running; then
    echo "Already running (pid=$(cat "$PIDFILE"))" >&2
    return 1
  fi

  local platform="" machine="" scale=""
  local preferred_machine_id="" preferred_scale_id=""
  local real=0 adb_forward=0
  local -a extra_defines=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --platform)
        [[ $# -ge 2 ]] || { echo "Missing value for $1" >&2; return 2; }
        platform="$2"; shift 2 ;;
      --connect-machine)
        [[ $# -ge 2 ]] || { echo "Missing value for $1" >&2; return 2; }
        machine="$2"; shift 2 ;;
      --connect-scale)
        [[ $# -ge 2 ]] || { echo "Missing value for $1" >&2; return 2; }
        scale="$2"; shift 2 ;;
      --preferred-machine-id)
        [[ $# -ge 2 ]] || { echo "Missing value for $1" >&2; return 2; }
        preferred_machine_id="$2"; shift 2 ;;
      --preferred-scale-id)
        [[ $# -ge 2 ]] || { echo "Missing value for $1" >&2; return 2; }
        preferred_scale_id="$2"; shift 2 ;;
      --real)
        real=1; shift ;;
      --adb-forward)
        adb_forward=1; shift ;;
      --dart-define)
        [[ $# -ge 2 ]] || { echo "Missing value for $1" >&2; return 2; }
        extra_defines+=("--dart-define=$2"); shift 2 ;;
      *) echo "Unknown flag: $1" >&2; return 2 ;;
    esac
  done

  {
    [[ -n "$platform" ]] && printf '%s\n' "--platform $platform"
    [[ -n "$machine" ]] && printf '%s\n' "--connect-machine $machine"
    [[ -n "$scale" ]] && printf '%s\n' "--connect-scale $scale"
    [[ -n "$preferred_machine_id" ]] && \
      printf '%s\n' "--preferred-machine-id $preferred_machine_id"
    [[ -n "$preferred_scale_id" ]] && \
      printf '%s\n' "--preferred-scale-id $preferred_scale_id"
    [[ "$real" -eq 1 ]] && printf '%s\n' "--real"
    [[ "$adb_forward" -eq 1 ]] && printf '%s\n' "--adb-forward"
    for d in ${extra_defines[@]+"${extra_defines[@]}"}; do printf '%s\n' "--dart-define ${d#--dart-define=}"; done
  } > "$FLAGSFILE"

  # Set up adb port forwarding before spawning flutter so readiness
  # checks against $BASE_URL work immediately after the app binds 8080.
  if [[ "$adb_forward" -eq 1 ]]; then
    if ! command -v adb >/dev/null 2>&1; then
      echo "error: --adb-forward requires adb on PATH" >&2
      return 1
    fi
    if ! adb forward "tcp:$PORT" "tcp:$PORT" >/dev/null; then
      echo "error: adb forward tcp:$PORT tcp:$PORT failed" >&2
      return 1
    fi
    : > "$ADB_FORWARD_MARK"
    echo "adb forward tcp:$PORT -> device tcp:$PORT"
  fi

  local -a defines=()
  [[ "$real" -eq 0 ]] && defines+=("--dart-define=simulate=1")
  # In simulate mode the mock device's name doubles as its id, so
  # reusing `--connect-machine` for `preferredMachineId` is harmless.
  # In `--real` mode a name like "DE1" won't match a device.deviceId
  # like "D9:11:0B:E6:9F:86", so only wire up the preferred-id dart
  # define when the caller has explicitly provided one via
  # `--preferred-machine-id` (same for scale).
  if [[ "$real" -eq 0 && -n "$machine" ]]; then
    defines+=("--dart-define=preferredMachineId=$machine")
  fi
  if [[ "$real" -eq 0 && -n "$scale" ]]; then
    defines+=("--dart-define=preferredScaleId=$scale")
  fi
  [[ -n "$preferred_machine_id" ]] && \
    defines+=("--dart-define=preferredMachineId=$preferred_machine_id")
  [[ -n "$preferred_scale_id" ]] && \
    defines+=("--dart-define=preferredScaleId=$preferred_scale_id")
  defines+=(${extra_defines[@]+"${extra_defines[@]}"})

  local -a platform_flag=()
  [[ -n "$platform" ]] && platform_flag=(-d "$platform")

  rm -f "$STDIN_FIFO"
  mkfifo "$STDIN_FIFO"

  # Persistent writer so flutter's reader never sees EOF
  tail -f /dev/null > "$STDIN_FIFO" &
  echo $! > "$HOLDER_PIDFILE"

  nohup ./flutter_with_commit.sh run \
    ${platform_flag[@]+"${platform_flag[@]}"} ${defines[@]+"${defines[@]}"} \
    < "$STDIN_FIFO" > "$LOGFILE" 2>&1 &
  echo $! > "$PIDFILE"

  echo "Started flutter (pid=$(cat "$PIDFILE")), waiting for HTTP server..."
  if ! wait_ready; then
    echo "Start failed. Run 'sb-dev logs' to inspect." >&2
    if [[ -f "$PIDFILE" ]] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
      kill "$(cat "$PIDFILE")" 2>/dev/null || true
    fi
    cleanup_runtime
    return 1
  fi

  if [[ -n "$machine" ]]; then
    connect_machine "$machine" || true
  fi
}

cleanup_runtime() {
  if [[ -f "$HOLDER_PIDFILE" ]]; then
    kill "$(cat "$HOLDER_PIDFILE")" 2>/dev/null || true
    rm -f "$HOLDER_PIDFILE"
  fi
  # Best-effort: remove the adb forward we installed on start. Ignore
  # errors (adb may be gone, device detached, etc).
  if [[ -f "$ADB_FORWARD_MARK" ]]; then
    if command -v adb >/dev/null 2>&1; then
      adb forward --remove "tcp:$PORT" 2>/dev/null || true
    fi
    rm -f "$ADB_FORWARD_MARK"
  fi
  rm -f "$PIDFILE" "$STDIN_FIFO"
}

stop_cmd() {
  if ! is_running; then
    echo "Not running"
    cleanup_runtime
    return 0
  fi
  local pid
  pid=$(cat "$PIDFILE")

  echo q > "$STDIN_FIFO" || true

  local start
  start=$(date +%s)
  while (( $(date +%s) - start < 5 )); do
    if ! kill -0 "$pid" 2>/dev/null; then
      break
    fi
    sleep 0.2
  done

  if kill -0 "$pid" 2>/dev/null; then
    echo "Flutter did not quit gracefully, sending SIGKILL" >&2
    kill -9 "$pid" 2>/dev/null || true
  fi
  cleanup_runtime
  echo "Stopped"
}

status_cmd() {
  if is_running; then
    echo "Running (pid=$(cat "$PIDFILE"))"
    if curl -sf "$BASE_URL/api/v1/devices" >/dev/null 2>&1; then
      echo "HTTP: reachable at $BASE_URL"
      curl -sf "$BASE_URL/api/v1/devices" | jq -c '.' 2>/dev/null || true
    else
      echo "HTTP: not yet reachable"
    fi
  else
    echo "Not running"
  fi
}

logs_cmd() {
  local count=50 filter=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -n|--count)
        [[ $# -ge 2 ]] || { echo "Missing value for $1" >&2; return 2; }
        count="$2"; shift 2 ;;
      --filter)
        [[ $# -ge 2 ]] || { echo "Missing value for $1" >&2; return 2; }
        filter="$2"; shift 2 ;;
      *) echo "Unknown flag: $1" >&2; return 2 ;;
    esac
  done
  if [[ ! -f "$LOGFILE" ]]; then
    echo "No log file yet at $LOGFILE" >&2
    return 1
  fi
  if [[ -n "$filter" ]]; then
    grep -i -- "$filter" "$LOGFILE" | tail -n "$count" || true
  else
    tail -n "$count" "$LOGFILE"
  fi
}

wait_for_pattern_after() {
  local pattern="$1" timeout="$2" start_line="$3"
  local start
  start=$(date +%s)
  while (( $(date +%s) - start < timeout )); do
    if tail -n +"$((start_line + 1))" "$LOGFILE" 2>/dev/null \
         | awk -v pat="$pattern" '$0 ~ pat {found=1; exit} END {exit !found}'; then
      return 0
    fi
    sleep 0.2
  done
  return 1
}

reload_cmd() {
  if ! is_running; then
    echo "Not running" >&2
    return 1
  fi
  local before
  before=$(wc -l < "$LOGFILE")
  echo r > "$STDIN_FIFO"
  if wait_for_pattern_after 'Reloaded [0-9]+( of [0-9]+)? libraries' 30 "$before"; then
    echo "Hot reload complete"
    tail -n +"$((before + 1))" "$LOGFILE" \
      | awk '/Reloaded [0-9]+( of [0-9]+)? libraries/ {print; exit}'
  else
    echo "Timed out waiting for reload confirmation" >&2
    return 1
  fi
}

hot_restart_cmd() {
  if ! is_running; then
    echo "Not running" >&2
    return 1
  fi
  local before
  before=$(wc -l < "$LOGFILE")
  echo R > "$STDIN_FIFO"
  if wait_for_pattern_after 'Restarted application in [0-9]+ms' 60 "$before"; then
    echo "Hot restart complete"
    tail -n +"$((before + 1))" "$LOGFILE" \
      | awk '/Restarted application in [0-9]+ms/ {print; exit}'
  else
    echo "Timed out waiting for restart confirmation" >&2
    return 1
  fi
}

restart_cmd() {
  local -a saved_args=()
  if [[ -f "$FLAGSFILE" ]]; then
    while IFS= read -r line; do
      # shellcheck disable=SC2206
      saved_args+=($line)
    done < "$FLAGSFILE"
  fi
  stop_cmd || true
  start_cmd ${saved_args[@]+"${saved_args[@]}"}
}

case "$cmd" in
  help|-h|--help) usage; exit 0 ;;
  start) start_cmd "$@" ;;
  stop) stop_cmd ;;
  status) status_cmd ;;
  logs) logs_cmd "$@" ;;
  reload) reload_cmd ;;
  hot-restart) hot_restart_cmd ;;
  restart) restart_cmd ;;
  *) echo "Not yet implemented: $cmd" >&2; exit 2 ;;
esac
