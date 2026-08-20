#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: $0 <appimage> <x86-64|aarch64>" >&2
  exit 2
}

APPIMAGE="${1:-}"
ARCH_PATTERN="${2:-}"
[ -n "$APPIMAGE" ] && [ -n "$ARCH_PATTERN" ] || usage

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

file "$APPIMAGE" | grep -q "$ARCH_PATTERN"

APPIMAGE_EXTRACT_AND_RUN=1 xvfb-run -a "$APPIMAGE" --print-storage-paths

cd "$WORK"
"$APPIMAGE" --appimage-extract >/dev/null

test -x squashfs-root/AppRun
test -f squashfs-root/net.tadel.reaprime.desktop
test -e squashfs-root/net.tadel.reaprime.png
desktop-file-validate squashfs-root/net.tadel.reaprime.desktop
test -x squashfs-root/usr/lib/decaid/decaid
test -f squashfs-root/usr/lib/decaid/data/flutter_assets/AssetManifest.json \
  -o -f squashfs-root/usr/lib/decaid/data/flutter_assets/AssetManifest.bin

echo "OK: $APPIMAGE ($(du -h "$APPIMAGE" | cut -f1))"
