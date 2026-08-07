#!/usr/bin/env bash
# Publish the Sparkle appcast for a tagged macOS release.
# Usage:
#   publish_appcast.sh <zip> <release-notes.md> <download-url-prefix> <channel> <key-file> <output> [previous-feed]
#   <channel>        "beta" or "stable" (no channel is written for stable).
#   <key-file>       Path to the EdDSA private key, or "-" to read it from
#                    standard input (for a GitHub Actions secret).
#   <output>         Where the generated appcast.xml is written.
#   [previous-feed]  The durable feed (gh-pages branch) to merge into. When
#                    absent, a fresh feed is generated; that one-time bootstrap
#                    must be authorized by the caller (see release.yml).
# The previous feed is the source of truth, read through git (not the Pages
# CDN), so a transient Pages/TLS failure can never be mistaken for a first
# publication. Fails unless the ZIP's CFBundleVersion is strictly greater than
# every item already in the feed, and unless item counts never decrease.
set -euo pipefail
source "$(dirname "$0")/appcast_helpers.sh"

ZIP="${1:?usage: publish_appcast.sh <zip> <notes.md> <url-prefix> <channel> <key-file> <output> [previous-feed]}"
NOTES="${2:?}"
PREFIX="${3:?}"
CHANNEL="${4:?}"
KEY_FILE="${5:?}"
OUTPUT="${6:?}"
PREVIOUS_FEED="${7:-}"

STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT

cp "$ZIP" "$STAGING/"
ZIP_BASENAME="$(basename "$ZIP")"
cp "$NOTES" "$STAGING/${ZIP_BASENAME%.zip}.md"

BUILD="$(zip_read_build "$ZIP")"
[ -n "$BUILD" ] || { echo "FAIL: could not read CFBundleVersion from $ZIP"; exit 1; }
echo "Release CFBundleVersion: $BUILD"

BOOTSTRAP=0
if [ -n "$PREVIOUS_FEED" ] && [ -s "$PREVIOUS_FEED" ]; then
  cp "$PREVIOUS_FEED" "$STAGING/appcast.xml"
  MAX="$(appcast_max_build "$STAGING/appcast.xml")"
  echo "Previous feed max CFBundleVersion: ${MAX:-none}"
  assert_build_increasing "$BUILD" "$MAX"
  OLD_COUNTS="$(appcast_item_counts "$STAGING/appcast.xml")"
else
  BOOTSTRAP=1
  echo "No previous feed; generating a fresh feed (bootstrap)"
fi

ARGS=(generate_appcast
  --ed-key-file "$KEY_FILE"
  --download-url-prefix "$PREFIX"
  --embed-release-notes
  --versions "$BUILD"
  --maximum-deltas 0
  --maximum-versions 0)
if [ "$CHANNEL" = "beta" ]; then
  ARGS+=(--channel beta)
elif [ "$CHANNEL" != "stable" ]; then
  echo "FAIL: unknown channel '$CHANNEL' (expected 'stable' or 'beta')" >&2
  exit 1
fi

EXPECTED_CHANNEL=""
[ "$CHANNEL" = "beta" ] && EXPECTED_CHANNEL="beta"

echo "Running generate_appcast (channel: $CHANNEL)..."
"${ARGS[@]}" "$STAGING"

if [ "$BOOTSTRAP" = "0" ]; then
  assert_feed_grew "$OLD_COUNTS" "$STAGING/appcast.xml" "$EXPECTED_CHANNEL"
  assert_old_items_preserved "$PREVIOUS_FEED" "$STAGING/appcast.xml"
fi

appcast_assert_item "$STAGING/appcast.xml" "$BUILD" "${PREFIX}${ZIP_BASENAME}" "$EXPECTED_CHANNEL"
xmllint --noout "$STAGING/appcast.xml"
echo "Feed validated: version $BUILD, channel '${CHANNEL}'"

mkdir -p "$(dirname "$OUTPUT")"
cp "$STAGING/appcast.xml" "$OUTPUT"
echo "Appcast written to $OUTPUT"
