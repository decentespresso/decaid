#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
BIN="$TMP/bin"
mkdir -p "$BIN"

cat > "$BIN/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$FAKE_LOG/gh-$1-$2"
if [ "$2" = download ]; then
  while [ $# -gt 0 ]; do [ "$1" = -D ] && { touch "$2/SideStepWizard.dmg"; exit 0; }; shift; done
  exit 1
fi
echo v9.9.9
EOF

cat > "$BIN/hdiutil" <<'EOF'
#!/usr/bin/env bash
[ "$1" = attach ] || exit 0
while [ $# -gt 0 ]; do [ "$1" = -mountpoint ] && mnt="$2"; shift; done
mkdir -p "$mnt/SideStepWizard.app/Contents"
cat > "$mnt/SideStepWizard.app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict><key>CFBundleShortVersionString</key><string>9.9.9</string></dict></plist>
PLIST
EOF

cat > "$BIN/xcrun" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

cat > "$BIN/codesign" <<'EOF'
#!/usr/bin/env bash
[ "$1" = -dv ] && echo "TeamIdentifier=CDZD6VH5KL" >&2
exit 0
EOF

cat > "$BIN/spctl" <<'EOF'
#!/usr/bin/env bash
echo "$FAKE_SPCTL_OUTPUT"
exit "$FAKE_SPCTL_STATUS"
EOF

chmod +x "$BIN"/*

NOTARIZED="accepted
source=Notarized Developer ID"

run() {
  local name="$1" status="$2" output="$3" tag="$4"
  local case_dir="$TMP/$name"
  mkdir -p "$case_dir/log"
  PATH="$BIN:$PATH" FAKE_LOG="$case_dir/log" FAKE_SPCTL_STATUS="$status" FAKE_SPCTL_OUTPUT="$output" \
    scripts/build_ipad_installer.sh "$case_dir/out" 924199754 "$tag" > "$case_dir/stdout" 2>&1
}

expect_pass() {
  if ! run "$@"; then
    echo "FAIL: $1 should have passed"; cat "$TMP/$1/stdout"; exit 1
  fi
  [ -f "$TMP/$1/out/ios/decaid-ipad-installer.zip" ] \
    || { echo "FAIL: $1 produced no installer zip"; exit 1; }
}

expect_fail() {
  if run "$@"; then
    echo "FAIL: $1 should have failed"; cat "$TMP/$1/stdout"; exit 1
  fi
  [ ! -e "$TMP/$1/out/ios/decaid-ipad-installer.zip" ] \
    || { echo "FAIL: $1 failed but still produced an installer zip"; exit 1; }
}

expect_pass notarized 0 "$NOTARIZED" ""
unzip -l "$TMP/notarized/out/ios/decaid-ipad-installer.zip" | grep "Decaid installer (10XqZe).app/" >/dev/null \
  || { echo "FAIL: installer is not named for repo id 10XqZe"; exit 1; }

expect_fail spctl_rejects_with_notarized_text 3 "$NOTARIZED" ""
grep -q "FAIL: spctl rejected" "$TMP/spctl_rejects_with_notarized_text/stdout" \
  || { echo "FAIL: spctl rejection was not reported"; exit 1; }

expect_fail spctl_accepts_not_notarized 0 "accepted
source=Developer ID" ""

expect_pass explicit_tag 0 "$NOTARIZED" "v0.2.72"
[ "$(head -3 "$TMP/explicit_tag/log/gh-release-download")" = "release
download
v0.2.72" ] || { echo "FAIL: gh did not receive the tag as one argument"; exit 1; }

expect_fail option_tag 0 "$NOTARIZED" "--repo=evil/repo"
expect_fail substitution_tag 0 "$NOTARIZED" "v1\$(touch $TMP/pwned)"
for name in option_tag substitution_tag; do
  [ ! -e "$TMP/$name/log/gh-release-download" ] \
    || { echo "FAIL: $name reached gh"; exit 1; }
done
[ ! -e "$TMP/pwned" ] || { echo "FAIL: tag was executed"; exit 1; }

echo "build_ipad_installer gate tests passed"
