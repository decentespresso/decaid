#!/usr/bin/env bash
# Usage: verify_macos_signature.sh <Decaid.app> [team-id] [post-staple]
set -euo pipefail

APP="${1:?usage: verify_macos_signature.sh <Decaid.app> [team-id] [post-staple]}"
TEAM_ID="${2:-XLS3XF57J8}"
POST_STAPLE="${3:-0}"

echo "== Gate 1: codesign --verify --deep --strict =="
codesign --verify --deep --strict --verbose=4 "$APP"

echo "== Gate 2: host Team ID + Hardened Runtime =="
HOST_DETAILS="$(codesign -d --entitlements :- --verbose=4 "$APP" 2>&1 || true)"
echo "$HOST_DETAILS" | grep -q "TeamIdentifier=$TEAM_ID" \
  || { echo "FAIL: host TeamIdentifier is not $TEAM_ID"; echo "$HOST_DETAILS"; exit 1; }
echo "$HOST_DETAILS" | grep -q "runtime" \
  || { echo "FAIL: host lacks Hardened Runtime"; echo "$HOST_DETAILS"; exit 1; }

echo "== Gate 3: host entitlements (sandbox, network, Sparkle mach names) =="
echo "$HOST_DETAILS" | grep -q "com.apple.security.app-sandbox" \
  || { echo "FAIL: host missing App Sandbox"; exit 1; }
echo "$HOST_DETAILS" | grep -q "com.apple.security.network.client" \
  || { echo "FAIL: host missing network client"; exit 1; }
echo "$HOST_DETAILS" | grep -q "net.tadel.reaprime-spks" \
  || { echo "FAIL: host missing net.tadel.reaprime-spks mach exception"; exit 1; }
echo "$HOST_DETAILS" | grep -q "net.tadel.reaprime-spki" \
  || { echo "FAIL: host missing net.tadel.reaprime-spki mach exception"; exit 1; }
if echo "$HOST_DETAILS" | grep -q 'PRODUCT_BUNDLE_IDENTIFIER'; then
  echo "FAIL: unexpanded PRODUCT_BUNDLE_IDENTIFIER leaked into entitlements"
  exit 1
fi

echo "== Gate 4: all embedded frameworks signed by the Team =="
# Ad-hoc-signed frameworks pass codesign --verify but fail notarization;
# every framework must carry the Developer ID Team ID.
while IFS= read -r -d '' fw; do
  DETAILS="$(codesign -d --verbose=4 "$fw" 2>&1 || true)"
  echo "$DETAILS" | grep -q "TeamIdentifier=$TEAM_ID" \
    || { echo "FAIL: $fw not signed by $TEAM_ID"; echo "$DETAILS"; exit 1; }
done < <(find "$APP/Contents/Frameworks" -mindepth 1 -maxdepth 1 -name "*.framework" -print0)

echo "== Gate 4b: Sparkle nested helpers present and signed by the Team =="
FRAMEWORK="$APP/Contents/Frameworks/Sparkle.framework/Versions/Current"
for component in \
  "$FRAMEWORK/XPCServices/Installer.xpc" \
  "$FRAMEWORK/XPCServices/Downloader.xpc" \
  "$FRAMEWORK/Updater.app" \
  "$FRAMEWORK/Autoupdate"; do
  [ -e "$component" ] || { echo "FAIL: missing $component"; exit 1; }
  DETAILS="$(codesign -d --verbose=4 "$component" 2>&1 || true)"
  echo "$DETAILS" | grep -q "TeamIdentifier=$TEAM_ID" \
    || { echo "FAIL: $component not signed by $TEAM_ID"; echo "$DETAILS"; exit 1; }
done

echo "== Gate 5: no get-task-allow in any Sparkle component =="
for component in \
  "$FRAMEWORK/XPCServices/Installer.xpc" \
  "$FRAMEWORK/XPCServices/Downloader.xpc" \
  "$FRAMEWORK/Updater.app" \
  "$FRAMEWORK/Autoupdate"; do
  if codesign -d --entitlements :- "$component" 2>/dev/null | grep -q "get-task-allow"; then
    echo "FAIL: $component retains get-task-allow in a distribution build"
    exit 1
  fi
done

if [ "$POST_STAPLE" = "1" ]; then
  echo "== Gate 6: spctl assessment =="
  spctl --assess --type execute --verbose=4 "$APP" \
    || { echo "FAIL: spctl rejected the app"; exit 1; }
  echo "== Gate 7: stapler validate =="
  xcrun stapler validate "$APP" \
    || { echo "FAIL: stapler validation failed"; exit 1; }
fi

echo "== All signing gates passed =="
