#!/usr/bin/env bash
# Sign Decaid.app with Developer ID for distribution WITHOUT `codesign --deep`.
# Sparkle's nested helpers (Installer.xpc, Downloader.xpc, Updater.app,
# Autoupdate) must be signed deepest-first, each keeping its own embedded
# entitlements. `codesign --deep` (especially with --entitlements) rewrites
# nested code with the host's entitlements, which strips the sandboxed
# Installer XPC service of what it needs. See
# doc/plans/archive/521-macos-auto-update-sparkle/521-macos-auto-update-sparkle.md.
# Usage: sign_macos_deepest_first.sh <Decaid.app> [identity] [entitlements]
set -euo pipefail

APP="${1:?usage: sign_macos_deepest_first.sh <Decaid.app> [identity] [entitlements]}"
IDENTITY="${2:-Developer ID Application}"
ENTITLEMENTS="${3:-macos/Runner/Release.entitlements}"

# codesign does not expand Xcode build variables; expand the bundle id so the
# signed app carries literal net.tadel.reaprime-spks/-spki mach names.
TMP_ENTITLEMENTS="$(mktemp)"
trap 'rm -f "$TMP_ENTITLEMENTS"' EXIT
sed "s/\$(PRODUCT_BUNDLE_IDENTIFIER)/net.tadel.reaprime/g" "$ENTITLEMENTS" > "$TMP_ENTITLEMENTS"

FRAMEWORK="$APP/Contents/Frameworks/Sparkle.framework/Versions/Current"

echo "== Signing Sparkle nested helpers deepest-first =="
codesign --force --options runtime --timestamp --sign "$IDENTITY" \
  "$FRAMEWORK/XPCServices/Installer.xpc"
codesign --force --options runtime --timestamp --sign "$IDENTITY" \
  "$FRAMEWORK/XPCServices/Downloader.xpc"
codesign --force --options runtime --timestamp --sign "$IDENTITY" \
  "$FRAMEWORK/Updater.app"
codesign --force --options runtime --timestamp --sign "$IDENTITY" \
  "$FRAMEWORK/Autoupdate"

echo "== Signing Sparkle.framework =="
codesign --force --options runtime --timestamp --sign "$IDENTITY" \
  "$APP/Contents/Frameworks/Sparkle.framework"

echo "== Signing remaining embedded frameworks =="
# Flutter's build leaves these ad-hoc signed; notarization requires Developer
# ID + timestamp on every embedded framework, not just Sparkle's.
while IFS= read -r -d '' fw; do
  codesign --force --options runtime --timestamp --sign "$IDENTITY" "$fw"
done < <(find "$APP/Contents/Frameworks" -mindepth 1 -maxdepth 1 \
  -name "*.framework" ! -name "Sparkle.framework" -print0)

echo "== Signing host app =="
codesign --force --options runtime --timestamp \
  --entitlements "$TMP_ENTITLEMENTS" --sign "$IDENTITY" \
  "$APP"

echo "== Done =="
