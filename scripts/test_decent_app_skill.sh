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
trap 'rm -rf "$TEMP_DIR"' EXIT

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
