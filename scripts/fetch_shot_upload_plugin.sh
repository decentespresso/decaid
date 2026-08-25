#!/usr/bin/env bash
set -euo pipefail

pinned_version="v0.2.1"
pinned_sha256="f404eca097c162c0ca17f828badeff1d5c8c831c49d2e38faa72ad2e7b1a1fdd"
pinned_api_version="1"

repo="${SHOT_UPLOAD_REPO:-decentespresso/shot-upload}"
version="${SHOT_UPLOAD_VERSION:-$pinned_version}"
expected_sha256="${SHOT_UPLOAD_SHA256:-$pinned_sha256}"
expected_api_version="${SHOT_UPLOAD_API_VERSION:-$pinned_api_version}"
plugins_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/assets/plugins"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

gh release download "$version" \
  --repo "$repo" --pattern 'shot-upload.reaplugin-*.zip' --dir "$tmp"

zip="$(find "$tmp" -maxdepth 1 -type f -name '*.zip' -print -quit)"
if [ -z "$zip" ]; then
  echo "fetch_shot_upload_plugin: no shot-upload.reaplugin-*.zip asset in $repo $version" >&2
  exit 1
fi

if command -v shasum >/dev/null 2>&1; then
  actual_sha256="$(shasum -a 256 "$zip" | cut -d ' ' -f 1)"
else
  actual_sha256="$(sha256sum "$zip" | cut -d ' ' -f 1)"
fi
if [ "$actual_sha256" != "$expected_sha256" ]; then
  echo "fetch_shot_upload_plugin: checksum mismatch for $(basename "$zip")" >&2
  echo "  expected: $expected_sha256" >&2
  echo "  actual:   $actual_sha256" >&2
  exit 1
fi

mkdir -p "$plugins_dir"
rm -rf "$plugins_dir/shot-upload.reaplugin"
if command -v unzip >/dev/null 2>&1; then
  unzip -q "$zip" -d "$plugins_dir"
else
  tar -xf "$zip" -C "$plugins_dir"
fi

manifest="$plugins_dir/shot-upload.reaplugin/manifest.json"
plugin_js="$plugins_dir/shot-upload.reaplugin/plugin.js"

for f in "$manifest" "$plugin_js"; do
  if [ ! -s "$f" ]; then
    echo "fetch_shot_upload_plugin: $(basename "$zip") is missing $(basename "$f")" >&2
    exit 1
  fi
done

manifest_id="$(jq -r '.id' "$manifest")"
if [ "$manifest_id" != "shot-upload.reaplugin" ]; then
  echo "fetch_shot_upload_plugin: manifest.json id is '$manifest_id', expected 'shot-upload.reaplugin'" >&2
  exit 1
fi

manifest_version="$(jq -r '.version' "$manifest")"
expected_manifest_version="${version#v}"
if [ "$manifest_version" != "$expected_manifest_version" ]; then
  echo "fetch_shot_upload_plugin: manifest.json version is '$manifest_version', expected '$expected_manifest_version'" >&2
  exit 1
fi

manifest_api_version="$(jq -r '.apiVersion' "$manifest")"
if [ "$manifest_api_version" != "$expected_api_version" ]; then
  echo "fetch_shot_upload_plugin: manifest.json apiVersion is '$manifest_api_version', expected '$expected_api_version'" >&2
  exit 1
fi

for permission in log api emit pluginStorage proxy.decent_api.write events.machine events.shots; do
  if ! jq -e --arg permission "$permission" '.permissions | index($permission) != null' "$manifest" >/dev/null; then
    echo "fetch_shot_upload_plugin: manifest.json is missing permission '$permission'" >&2
    exit 1
  fi
done

if ! grep -q 'createPlugin' "$plugin_js"; then
  echo "fetch_shot_upload_plugin: plugin.js has no 'createPlugin' entry point" >&2
  exit 1
fi

echo "fetch_shot_upload_plugin: installed $(basename "$zip") -> $plugins_dir/shot-upload.reaplugin"
