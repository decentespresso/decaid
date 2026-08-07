#!/usr/bin/env bash

# Largest sparkle:version (CFBundleVersion) among all appcast items.
appcast_max_build() {
  local appcast="$1"
  xmllint --xpath \
    '//*[local-name()="item"]/*[local-name()="version"]/text()' \
    "$appcast" 2>/dev/null | tr ' ' '\n' | sort -n | tail -1
}

# Refuse publishing an update Sparkle can never select (equal/lower build).
assert_build_increasing() {
  local new="$1" existing="$2"
  if [ -n "$existing" ] && [ "$new" -le "$existing" ]; then
    echo "FAIL: new CFBundleVersion $new is not greater than existing $existing"
    return 1
  fi
}

zip_read_build() {
  local zip="$1"
  unzip -p "$zip" "Decaid.app/Contents/Info.plist" \
    | plutil -extract CFBundleVersion raw -
}

appcast_item_counts() {
  local appcast="$1"
  local total default_count
  total=$(xmllint --xpath 'count(//*[local-name()="item"])' "$appcast" 2>/dev/null)
  default_count=$(xmllint --xpath \
    'count(//*[local-name()="item"][not(*[local-name()="channel"])])' "$appcast" 2>/dev/null)
  echo "$total $default_count"
}

assert_feed_grew() {
  local old_pair="$1" appcast="$2" channel="$3"
  local old_total old_default new_total new_default
  read -r old_total old_default <<< "$old_pair"
  read -r new_total new_default <<< "$(appcast_item_counts "$appcast")"
  [ "$new_total" -eq $((old_total + 1)) ] || {
    echo "FAIL: feed must grow by exactly one item ($old_total -> $new_total)"; return 1; }
  local expected_default
  if [ -z "$channel" ]; then
    expected_default=$((old_default + 1))
  else
    expected_default=$old_default
  fi
  [ "$new_default" -eq "$expected_default" ] || {
    echo "FAIL: default-channel items expected $expected_default, got $new_default"; return 1; }
}

# The old (version, channel) set must be a subset of the new feed: a beta
# publication can never erase stable or historical items, and an existing
# item's channel must not change.
assert_old_items_preserved() {
  local old_feed="$1" new_feed="$2"
  local old_versions new_versions v old_ch new_ch
  old_versions=$(xmllint --xpath \
    '//*[local-name()="item"]/*[local-name()="version"]/text()' \
    "$old_feed" 2>/dev/null | tr ' ' '\n')
  new_versions=$(xmllint --xpath \
    '//*[local-name()="item"]/*[local-name()="version"]/text()' \
    "$new_feed" 2>/dev/null | tr ' ' '\n')
  for v in $old_versions; do
    grep -qx "$v" <<< "$new_versions" || {
      echo "FAIL: version $v missing from the new feed"; return 1; }
    old_ch=$(xmllint --xpath \
      "string(//*[local-name()=\"item\"][*[local-name()=\"version\"]=\"$v\"]/*[local-name()=\"channel\"])" \
      "$old_feed" 2>/dev/null)
    new_ch=$(xmllint --xpath \
      "string(//*[local-name()=\"item\"][*[local-name()=\"version\"]=\"$v\"]/*[local-name()=\"channel\"])" \
      "$new_feed" 2>/dev/null)
    [ "$old_ch" = "$new_ch" ] || {
      echo "FAIL: version $v channel changed ('$old_ch' -> '$new_ch')"; return 1; }
  done
}

appcast_assert_item() {
  local appcast="$1" build="$2" expected_url="$3" expected_channel="$4"

  local url sig
  url=$(xmllint --xpath \
    "string(//*[local-name()=\"item\"][*[local-name()=\"version\"]=\"$build\"]/*[local-name()=\"enclosure\"]/@url)" \
    "$appcast" 2>/dev/null)
  [ "$url" = "$expected_url" ] || {
    echo "FAIL: item $build url '$url' != '$expected_url'"; return 1; }

  sig=$(xmllint --xpath \
    "string(//*[local-name()=\"item\"][*[local-name()=\"version\"]=\"$build\"]/*[local-name()=\"enclosure\"]/@*[local-name()=\"edSignature\"])" \
    "$appcast" 2>/dev/null)
  [ -n "$sig" ] || {
    echo "FAIL: item $build has no edSignature"; return 1; }

  local channel_count
  channel_count=$(xmllint --xpath \
    "count(//*[local-name()=\"item\"][*[local-name()=\"version\"]=\"$build\"]/*[local-name()=\"channel\"])" \
    "$appcast" 2>/dev/null)
  if [ -z "$expected_channel" ]; then
    [ "$channel_count" = "0" ] || {
      echo "FAIL: stable item $build must not carry a sparkle:channel"; return 1; }
  else
    [ "$channel_count" = "1" ] || {
      echo "FAIL: item $build must carry exactly one sparkle:channel"; return 1; }
    local actual
    actual=$(xmllint --xpath \
      "string(//*[local-name()=\"item\"][*[local-name()=\"version\"]=\"$build\"]/*[local-name()=\"channel\"])" \
      "$appcast" 2>/dev/null)
    [ "$actual" = "$expected_channel" ] || {
      echo "FAIL: item $build channel '$actual' != '$expected_channel'"; return 1; }
  fi
}
