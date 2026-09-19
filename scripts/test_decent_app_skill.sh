#!/usr/bin/env bash

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKILL_DIR="$REPO_ROOT/.agents/skills/decent-app"
SKILL_FILE="$SKILL_DIR/SKILL.md"
SCENARIO_INDEX="$SKILL_DIR/scenarios/README.md"

[[ "$(head -n 1 "$SKILL_FILE")" == "---" ]]
grep -qx 'name: decent-app' "$SKILL_FILE"
grep -Eq '^description: .+$' "$SKILL_FILE"

if grep -RFn '/tmp/decent-app-' "$SKILL_DIR"; then
  echo "Stale sb-dev runtime directory found" >&2
  exit 1
fi

runtime_default="$(
  sed -n 's/^RUNTIME_DIR="${SB_RUNTIME_DIR:-\(.*\)}"/\1/p' \
    "$REPO_ROOT/scripts/sb-dev.sh" |
    sed 's/${USER:-default}/$USER/'
)"
grep -Fq "default \`$runtime_default/\`" "$SKILL_DIR/lifecycle.md"

simulated_types="$(
  awk '
    /enum SimulatedDevicesTypes[[:space:]]*\{/ {
      collecting = 1
      sub(/^.*enum SimulatedDevicesTypes[[:space:]]*\{[[:space:]]*/, "")
    }
    collecting {
      if ($0 ~ /}/) {
        sub(/[[:space:]]*}.*/, "")
        values = values " " $0
        exit
      }
      values = values " " $0
    }
    END {
      gsub(/[[:space:]]+/, " ", values)
      sub(/^ /, "", values)
      sub(/ $/, "", values)
      gsub(/,[[:space:]]*/, ", ", values)
      sub(/,[[:space:]]*$/, "", values)
      print values
    }
  ' \
    "$REPO_ROOT/lib/src/settings/settings_service.dart"
)"
[[ -n "$simulated_types" ]] || {
  echo "Could not parse SimulatedDevicesTypes" >&2
  exit 1
}
grep -Fq "\`$simulated_types\`" "$SKILL_DIR/simulated-devices.md"

TEMP_DIR="$(mktemp -d)"
TEST_RUNTIME="$TEMP_DIR/sb-dev-runtime"
TEST_ARGS="$TEMP_DIR/flutter-args"
TEST_SENTINEL="$TEMP_DIR/should-not-run"
FAKE_BIN="$REPO_ROOT/scripts/test-fixtures/sb-dev-fake-bin"

cp "$REPO_ROOT/flutter_with_commit.sh" "$TEMP_DIR/flutter_with_commit.sh"
chmod +x "$TEMP_DIR/flutter_with_commit.sh"

run_sb_dev() {
  (
    cd "$TEMP_DIR"
    PATH="$FAKE_BIN:$PATH" \
      SB_RUNTIME_DIR="$TEST_RUNTIME" \
      SB_DEV_TEST_ARGS="$TEST_ARGS" \
      "$REPO_ROOT/scripts/sb-dev.sh" "$@"
  )
}

cleanup_sb_dev() {
  run_sb_dev stop >/dev/null 2>&1 || true
}

trap 'cleanup_sb_dev; rm -rf "$TEMP_DIR"' EXIT

indexed_scenarios="$TEMP_DIR/indexed-scenarios"
actual_scenarios="$TEMP_DIR/actual-scenarios"

{
  sed -n 's/.*`scenarios\/\([^`]*\.md\)`.*/\1/p' "$SCENARIO_INDEX" |
    sort
} > "$indexed_scenarios"
{
  find "$SKILL_DIR/scenarios" -type f -name '*.md' ! -name README.md \
    -exec basename {} \; |
    sort
} > "$actual_scenarios"

diff "$indexed_scenarios" "$actual_scenarios"

: > "$TEST_ARGS"
special_arg="value with spaces;\$(touch $TEST_SENTINEL)"
run_sb_dev start \
  --app-arg --serial \
  --app-arg --no-account \
  --app-arg "$special_arg"
run_sb_dev restart
run_sb_dev stop

test "$(grep -Fxc -- '--dart-entrypoint-args=--serial' "$TEST_ARGS")" -eq 2
test "$(grep -Fxc -- '--dart-entrypoint-args=--no-account' "$TEST_ARGS")" -eq 2
test "$(grep -Fxc -- "--dart-entrypoint-args=$special_arg" "$TEST_ARGS")" -eq 2
test ! -e "$TEST_SENTINEL"

set +e
missing_value_output="$(run_sb_dev start --app-arg 2>&1)"
missing_value_rc=$?
newline_output="$(run_sb_dev start --app-arg $'bad\nvalue' 2>&1)"
newline_rc=$?
set -e

test "$missing_value_rc" -eq 2
grep -Fq 'Missing value for --app-arg' <<<"$missing_value_output"
test "$newline_rc" -eq 2
grep -Fq 'App arguments cannot contain newlines' <<<"$newline_output"
