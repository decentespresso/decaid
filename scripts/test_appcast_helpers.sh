#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/appcast_helpers.sh

FAILURES=0
fail() { echo "FAIL: $1"; FAILURES=$((FAILURES + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/fixture.xml" <<'XML'
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Decaid Changelog</title>
    <item>
      <title>Version 2.0.0</title>
      <sparkle:version>101</sparkle:version>
      <sparkle:channel>beta</sparkle:channel>
      <enclosure url="https://github.com/decentespresso/decaid/releases/download/v2.0.0/decaid-macos-2.0.0.zip"
                 sparkle:edSignature="AA==" type="application/octet-stream"/>
    </item>
    <item>
      <title>Version 1.9.0</title>
      <sparkle:version>100</sparkle:version>
      <enclosure url="https://github.com/decentespresso/decaid/releases/download/v1.9.0/decaid-macos-1.9.0.zip"
                 sparkle:edSignature="BB==" type="application/octet-stream"/>
    </item>
  </channel>
</rss>
XML

MAX="$(appcast_max_build "$TMP/fixture.xml")"
[ "$MAX" = "101" ] || fail "appcast_max_build expected 101, got '$MAX'"
echo "ok: appcast_max_build = $MAX"

assert_build_increasing 102 101 && echo "ok: 102 > 101 accepted"
if assert_build_increasing 101 101 >/dev/null 2>&1; then
  fail "assert_build_increasing accepted equal build 101"
fi
if assert_build_increasing 100 101 >/dev/null 2>&1; then
  fail "assert_build_increasing accepted lower build 100"
fi

mkdir -p "$TMP/zip/Decaid.app/Contents"
cat > "$TMP/zip/Decaid.app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleShortVersionString</key><string>2.1.0</string>
  <key>CFBundleVersion</key><string>102</string>
</dict></plist>
PLIST
ditto -c -k --keepParent "$TMP/zip/Decaid.app" "$TMP/decaid-macos-2.1.0.zip"

BUILD="$(zip_read_build "$TMP/decaid-macos-2.1.0.zip")"
[ "$BUILD" = "102" ] || fail "zip_read_build expected 102, got '$BUILD'"
echo "ok: zip_read_build = $BUILD"

appcast_assert_item "$TMP/fixture.xml" 101 \
  "https://github.com/decentespresso/decaid/releases/download/v2.0.0/decaid-macos-2.0.0.zip" \
  "beta" && echo "ok: beta item assertions pass"

# --- Growth assertions ---
# Old fixture: 2 items (1 default + 1 beta). A stable publication must add
# one default item (3 total, 2 default); a beta one adds a beta item (3
# total, 1 default).
cat > "$TMP/grown-stable.xml" <<'XML'
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <item><sparkle:version>101</sparkle:version><sparkle:channel>beta</sparkle:channel></item>
    <item><sparkle:version>100</sparkle:version></item>
    <item><sparkle:version>102</sparkle:version></item>
  </channel>
</rss>
XML
cat > "$TMP/grown-beta.xml" <<'XML'
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <item><sparkle:version>101</sparkle:version><sparkle:channel>beta</sparkle:channel></item>
    <item><sparkle:version>100</sparkle:version></item>
    <item><sparkle:version>102</sparkle:version><sparkle:channel>beta</sparkle:channel></item>
  </channel>
</rss>
XML
assert_feed_grew "2 1" "$TMP/grown-stable.xml" "" \
  && echo "ok: stable growth (3 total, 2 default) accepted"
assert_feed_grew "2 1" "$TMP/grown-beta.xml" "beta" \
  && echo "ok: beta growth (3 total, 1 default) accepted"
if assert_feed_grew "2 1" "$TMP/fixture.xml" "" >/dev/null 2>&1; then
  fail "assert_feed_grew accepted unchanged item counts"
fi
if assert_feed_grew "2 1" "$TMP/grown-beta.xml" "" >/dev/null 2>&1; then
  fail "assert_feed_grew accepted a beta item as a stable one"
fi

assert_old_items_preserved "$TMP/fixture.xml" "$TMP/grown-stable.xml" \
  && echo "ok: old items preserved in grown feed"
# A feed that dropped item 100 while adding 102 must be rejected even though
# its counts grew.
cat > "$TMP/dropped.xml" <<'XML'
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <item><sparkle:version>101</sparkle:version><sparkle:channel>beta</sparkle:channel></item>
    <item><sparkle:version>102</sparkle:version></item>
  </channel>
</rss>
XML
if assert_old_items_preserved "$TMP/fixture.xml" "$TMP/dropped.xml" >/dev/null 2>&1; then
  fail "assert_old_items_preserved accepted a feed that dropped item 100"
fi
echo "ok: dropped item rejected"

if appcast_assert_item "$TMP/fixture.xml" 101 \
  "https://github.com/decentespresso/decaid/releases/download/v2.0.0/decaid-macos-2.0.0.zip" \
  "stable" >/dev/null 2>&1; then
  fail "appcast_assert_item accepted a beta item as stable"
fi

if appcast_assert_item "$TMP/fixture.xml" 100 \
  "https://example.com/wrong.zip" "stable" >/dev/null 2>&1; then
  fail "appcast_assert_item accepted a wrong enclosure URL"
fi

if [ "$FAILURES" -ne 0 ]; then
  echo "$FAILURES assertion(s) failed"
  exit 1
fi
echo "All appcast helper tests passed"
