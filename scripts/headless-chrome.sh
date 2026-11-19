#!/usr/bin/env bash
# Headless Chrome with scoped cleanup.
#
# Usage:
#   scripts/headless-chrome.sh run [--] <command...>
#       Runs <command> with CHROME_BIN and CHROME_PROFILE exported. On exit,
#       SIGINT or SIGTERM, its probe and browser processes are stopped and the
#       owned disposable profile is removed.
#
#   scripts/headless-chrome.sh sweep
#       Recovers managed profiles whose owning run has ended.
set -euo pipefail
umask 077

case "${BASH_SOURCE[0]}" in
  */*) script_directory="${BASH_SOURCE[0]%/*}" ;;
  *) script_directory='.' ;;
esac
SCRIPT_DIR="$(cd "$script_directory" && pwd -P)"
PROCESS_READER="$SCRIPT_DIR/headless_chrome_processes.py"
RUNTIME_DIR="${CHROME_RUNTIME_DIR:-/tmp/decent-chrome-${USER:-default}}"
OWNER_FILE='.decaid-chrome-owner-v1'
PROBE_FILE='.decaid-chrome-probe-v1'

usage() {
  printf '%s\n' \
    'Usage: headless-chrome.sh run [--] <command...> | sweep | help' \
    'run exports CHROME_BIN and a fresh disposable CHROME_PROFILE.' \
    'Profiles live under CHROME_RUNTIME_DIR (default /tmp/decent-chrome-$USER).'
}

find_chrome() {
  [ -n "${CHROME_BIN:-}" ] && [ -x "$CHROME_BIN" ] && { printf '%s\n' "$CHROME_BIN"; return 0; }
  local candidate
  for candidate in \
    '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome' \
    '/Applications/Chromium.app/Contents/MacOS/Chromium' \
    "$(command -v google-chrome 2>/dev/null || true)" \
    "$(command -v google-chrome-stable 2>/dev/null || true)" \
    "$(command -v chromium 2>/dev/null || true)" \
    "$(command -v chromium-browser 2>/dev/null || true)"; do
    [ -n "$candidate" ] && [ -x "$candidate" ] && { printf '%s\n' "$candidate"; return 0; }
  done
  return 1
}

require_process_reader() {
  command -v python3 >/dev/null 2>&1 || { printf 'error: Python 3 is required for safe process inspection\n' >&2; return 1; }
  [ -r "$PROCESS_READER" ] || { printf 'error: missing headless Chrome process reader\n' >&2; return 1; }
  python3 "$PROCESS_READER" --check
}

prepare_runtime() {
  mkdir -p "$RUNTIME_DIR"
  RUNTIME_DIR="$(cd "$RUNTIME_DIR" && pwd -P)"
}

process_started() {
  LC_ALL=C ps -p "$1" -o lstart= 2>/dev/null
}

record_process() {
  local started
  started="$(process_started "$2")" || return 1
  [ -n "$started" ] || return 1
  printf '%s\n%s\n' "$2" "$started" > "$1"
}

read_record() {
  [ -f "$1" ] && [ ! -L "$1" ] && [ -O "$1" ] || return 1
  {
    IFS= read -r record_pid
    IFS= read -r record_started
  } < "$1" || return 1
  case "$record_pid" in '' | *[!0-9]*) return 1 ;; esac
  [ "$record_pid" -gt 1 ] && [ -n "$record_started" ]
}

record_alive() {
  read_record "$1" || return 1
  [ "$(process_started "$record_pid" || true)" = "$record_started" ]
}

owned_profile() {
  local dir="$1"
  [ -d "$dir" ] && [ ! -L "$dir" ] && [ -O "$dir" ] || return 1
  [ "${dir%/*}" = "$RUNTIME_DIR" ] || return 1
  read_record "$dir/$OWNER_FILE" || return 1
  case "${dir##*/}" in "run-$record_pid-"*) return 0 ;; *) return 1 ;; esac
}

new_profile() {
  local owner="${1:-$$}" dir
  dir="$(mktemp -d "$RUNTIME_DIR/run-$owner-XXXXXXXX")"
  if ! record_process "$dir/$OWNER_FILE" "$owner"; then
    rmdir "$dir"
    return 1
  fi
  printf '%s\n' "$dir"
}

profile_processes() {
  local own_group
  own_group="$(ps -p $$ -o pgid= | tr -d '[:space:]')"
  python3 "$PROCESS_READER" "${1##*/}" "$own_group"
}

stop_group() {
  local group="$1" tries=0
  kill -TERM -- "-$group" 2>/dev/null || true
  while kill -0 -- "-$group" 2>/dev/null && [ "$tries" -lt 10 ]; do
    sleep 0.1
    tries=$((tries + 1))
  done
  kill -KILL -- "-$group" 2>/dev/null || true
  tries=0
  while kill -0 -- "-$group" 2>/dev/null && [ "$tries" -lt 10 ]; do
    sleep 0.1
    tries=$((tries + 1))
  done
  ! kill -0 -- "-$group" 2>/dev/null
}

kill_profile() {
  local rows groups group own_group
  rows="$(profile_processes "$1")" || return 1
  [ -n "$rows" ] || return 0
  own_group="$(ps -p $$ -o pgid= | tr -d '[:space:]')"
  groups="$(printf '%s\n' "$rows" | awk '{print $2}' | sort -u)"
  for group in $groups; do
    if [ "$group" = "$own_group" ]; then
      printf 'error: refusing to stop the wrapper process group for %s\n' "$1" >&2
      return 1
    fi
    stop_group "$group" || return 1
  done
  rows="$(profile_processes "$1")" || return 1
  [ -z "$rows" ]
}

cleanup_profile() {
  local dir="$1" probe="${2:-}"
  owned_profile "$dir" || return 1
  if [ -z "$probe" ] && record_alive "$dir/$PROBE_FILE"; then
    probe="$record_pid"
  fi
  if [ -n "$probe" ]; then
    stop_group "$probe" || return 1
  fi
  kill_profile "$dir" || return 1
  rm -rf -- "$dir"
}

sweep() {
  require_process_reader
  prepare_runtime
  local dir killed=0 kept=0 failed=0
  for dir in "$RUNTIME_DIR"/run-*; do
    owned_profile "$dir" || continue
    if record_alive "$dir/$OWNER_FILE"; then
      kept=$((kept + 1))
    elif cleanup_profile "$dir"; then
      killed=$((killed + 1))
    else
      printf 'error: cleanup incomplete; retained %s\n' "$dir" >&2
      failed=1
    fi
  done
  printf 'swept %d orphaned profile(s), kept %d still in use, under %s\n' "$killed" "$kept" "$RUNTIME_DIR"
  return "$failed"
}

cmd="${1:-help}"
shift || true

case "$cmd" in
  run)
    if [ "${1:-}" = '--' ]; then shift; fi
    if [ "$#" -eq 0 ]; then
      printf 'error: run needs a command\n' >&2
      exit 2
    fi
    chrome="$(find_chrome)" || { printf 'error: no Chrome/Chromium found; set CHROME_BIN\n' >&2; exit 1; }
    require_process_reader
    prepare_runtime
    profile="$(new_profile)"
    export CHROME_BIN="$chrome" CHROME_PROFILE="$profile" DECAID_CHROME_OWNER="$$"
    export DECAID_CHROME_RUN_TOKEN="${profile##*/}"
    probe_pid=''
    cleanup() {
      local status=$?
      trap - EXIT INT TERM
      if ! cleanup_profile "$CHROME_PROFILE" "$probe_pid"; then
        printf 'error: cleanup incomplete; retained %s\n' "$CHROME_PROFILE" >&2
        [ "$status" -ne 0 ] || status=1
      fi
      exit "$status"
    }
    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    set -m
    "$BASH" -ec '
      printf "%s\n%s\n" "$$" "$(LC_ALL=C ps -p $$ -o lstart=)" > "$CHROME_PROFILE/.decaid-chrome-probe-v1"
      kill -0 "$DECAID_CHROME_OWNER" 2>/dev/null || exit 143
      exec "$@"
    ' headless-chrome-probe "$@" &
    probe_pid=$!
    set +m
    set +e
    wait "$probe_pid"
    status=$?
    set -e
    exit "$status"
    ;;
  sweep)
    sweep
    ;;
  help | --help | -h)
    usage
    ;;
  *)
    printf 'error: unknown command %s\n' "$cmd" >&2
    usage >&2
    exit 2
    ;;
esac
