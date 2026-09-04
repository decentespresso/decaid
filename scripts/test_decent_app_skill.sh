#!/usr/bin/env bash

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKILL_DIR="$REPO_ROOT/.agents/skills/decent-app"
SKILL_FILE="$SKILL_DIR/SKILL.md"
SCENARIO_INDEX="$SKILL_DIR/scenarios/README.md"

[[ "$(head -n 1 "$SKILL_FILE")" == "---" ]]
grep -qx 'name: decent-app' "$SKILL_FILE"
grep -q '^description: .\+$' "$SKILL_FILE"

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
  sed -n 's/^enum SimulatedDevicesTypes { \(.*\) }$/\1/p' \
    "$REPO_ROOT/lib/src/settings/settings_service.dart"
)"
grep -Fq "\`$simulated_types\`" "$SKILL_DIR/simulated-devices.md"

mapfile -t indexed_scenarios < <(
  sed -n 's/.*`scenarios\/\([^`]*\.md\)`.*/\1/p' "$SCENARIO_INDEX" |
    sort
)
mapfile -t actual_scenarios < <(
  find "$SKILL_DIR/scenarios" -maxdepth 1 -type f -name '*.md' \
    ! -name README.md -printf '%f\n' |
    sort
)

diff \
  <(printf '%s\n' "${indexed_scenarios[@]}") \
  <(printf '%s\n' "${actual_scenarios[@]}")
