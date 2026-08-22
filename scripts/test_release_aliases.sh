#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

VERSION=1.2.3
ARTIFACTS="$TMP/release-artifacts"
MANIFEST="$TMP/decaid-latest-SHA256SUMS.txt"
SOURCE_PATHS=(
  "android-apk/decaid-android-${VERSION}.apk"
  "macos-app/decaid-macos-${VERSION}.zip"
  "macos-app/decaid-macos-${VERSION}.dmg"
  "linux-app/decaid-linux-x64-${VERSION}.tar.gz"
  "linux-app/decaid-linux-x86_64-${VERSION}.AppImage"
  "raspberrypi-linux-arm64-app/decaid-linux-arm64-${VERSION}.tar.gz"
  "raspberrypi-linux-arm64-app/decaid-linux-aarch64-${VERSION}.AppImage"
  "windows-app/decaid-windows-x64-${VERSION}.zip"
  "ios-ipa-unsigned/decaid-ios-unsigned-${VERSION}.ipa"
)
ALIAS_PATHS=(
  "android-apk/decaid-android-latest.apk"
  "macos-app/decaid-macos-latest.zip"
  "macos-app/decaid-macos-latest.dmg"
  "linux-app/decaid-linux-x64-latest.tar.gz"
  "linux-app/decaid-linux-x86_64-latest.AppImage"
  "raspberrypi-linux-arm64-app/decaid-linux-arm64-latest.tar.gz"
  "raspberrypi-linux-arm64-app/decaid-linux-aarch64-latest.AppImage"
  "windows-app/decaid-windows-x64-latest.zip"
  "ios-ipa-unsigned/decaid-ios-unsigned-latest.ipa"
)

for i in "${!SOURCE_PATHS[@]}"; do
  source="$ARTIFACTS/${SOURCE_PATHS[$i]}"
  mkdir -p "$(dirname "$source")"
  printf '%s\n' "${SOURCE_PATHS[$i]}" > "$source"
done

scripts/create_release_aliases.sh "$ARTIFACTS" "$VERSION" >/dev/null

[ -f "$MANIFEST" ] || { echo "FAIL: missing $MANIFEST"; exit 1; }
for i in "${!SOURCE_PATHS[@]}"; do
  source="$ARTIFACTS/${SOURCE_PATHS[$i]}"
  alias="$ARTIFACTS/${ALIAS_PATHS[$i]}"
  [ -f "$alias" ] || { echo "FAIL: missing $alias"; exit 1; }
  cmp -s "$source" "$alias" || { echo "FAIL: $alias differs from $source"; exit 1; }
done

EXPECTED_NAMES="$TMP/expected-names.txt"
ACTUAL_NAMES="$TMP/actual-names.txt"
for alias in "${ALIAS_PATHS[@]}"; do
  basename "$alias"
done | sort > "$EXPECTED_NAMES"
awk '{print $2}' "$MANIFEST" | sort > "$ACTUAL_NAMES"
diff -u "$EXPECTED_NAMES" "$ACTUAL_NAMES"

DOWNLOAD="$TMP/download"
mkdir "$DOWNLOAD"
for alias in "${ALIAS_PATHS[@]}"; do
  cp "$ARTIFACTS/$alias" "$DOWNLOAD/"
done
(cd "$DOWNLOAD" && sha256sum -c "$MANIFEST" >/dev/null)

EMPTY="$TMP/empty/release-artifacts"
mkdir -p "$EMPTY"
if scripts/create_release_aliases.sh "$EMPTY" "$VERSION" >/dev/null 2>&1; then
  echo "FAIL: empty artifact set was accepted"
  exit 1
fi

echo "All release alias tests passed"
