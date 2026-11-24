#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# "<artifact path prefix>:<extension>" for every versioned release artifact.
ARTIFACT_STEMS=(
  "android-apk/decaid-android:apk"
  "macos-app/decaid-macos:zip"
  "macos-app/decaid-macos:dmg"
  "linux-app/decaid-linux-x64:tar.gz"
  "linux-app/decaid-linux-x86_64:AppImage"
  "raspberrypi-linux-arm64-app/decaid-linux-arm64:tar.gz"
  "raspberrypi-linux-arm64-app/decaid-linux-aarch64:AppImage"
  "windows-app/decaid-windows-x64:zip"
  "ios-ipa-unsigned/decaid-ios-unsigned:ipa"
)

exercise_tag() {
  local tag="$1"
  local artifacts="$TMP/$tag/release-artifacts"
  local manifest="$TMP/$tag/decaid-latest-SHA256SUMS.txt"
  local sources=()
  local aliases=()

  for stem in "${ARTIFACT_STEMS[@]}"; do
    local prefix="${stem%%:*}"
    local extension="${stem#*:}"
    sources+=("${prefix}-${tag}.${extension}")
    aliases+=("${prefix}-latest.${extension}")
  done

  for source in "${sources[@]}"; do
    mkdir -p "$(dirname "$artifacts/$source")"
    printf '%s\n' "$source" > "$artifacts/$source"
  done

  scripts/create_release_aliases.sh "$artifacts" "$tag" >/dev/null

  [ -f "$manifest" ] || { echo "FAIL: missing $manifest"; exit 1; }
  for i in "${!sources[@]}"; do
    local source="$artifacts/${sources[$i]}"
    local alias="$artifacts/${aliases[$i]}"
    [ -f "$alias" ] || { echo "FAIL: missing $alias"; exit 1; }
    cmp -s "$source" "$alias" || { echo "FAIL: $alias differs from $source"; exit 1; }
  done

  local expected_names="$TMP/$tag/expected-names.txt"
  local actual_names="$TMP/$tag/actual-names.txt"
  for alias in "${aliases[@]}"; do
    basename "$alias"
  done | sort > "$expected_names"
  awk '{print $2}' "$manifest" | sort > "$actual_names"
  diff -u "$expected_names" "$actual_names"

  local download="$TMP/$tag/download"
  mkdir -p "$download"
  for alias in "${aliases[@]}"; do
    cp "$artifacts/$alias" "$download/"
  done
  (cd "$download" && sha256sum -c "$manifest" >/dev/null)

  echo "ok: stable aliases derived from tag $tag"
}

exercise_tag v1.2.3
exercise_tag v0.9.4-beta.1

EMPTY="$TMP/empty/release-artifacts"
mkdir -p "$EMPTY"
if scripts/create_release_aliases.sh "$EMPTY" v1.2.3 >/dev/null 2>&1; then
  echo "FAIL: empty artifact set was accepted"
  exit 1
fi

BARE="$TMP/bare/release-artifacts"
mkdir -p "$BARE/macos-app"
printf 'x\n' > "$BARE/macos-app/decaid-macos-1.2.3.zip"
if scripts/create_release_aliases.sh "$BARE" v1.2.3 >/dev/null 2>&1; then
  echo "FAIL: version-only artifact names were accepted for tag v1.2.3"
  exit 1
fi
echo "ok: version-only artifact names rejected"

echo "All release alias tests passed"
