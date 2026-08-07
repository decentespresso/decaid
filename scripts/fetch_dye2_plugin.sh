#!/usr/bin/env bash
# Usage:
#   DYE2_VERSION     Release tag to install (default: pinned version below).
#   DYE2_API_VERSION Expected manifest.json apiVersion (default: pinned value below).
set -euo pipefail

pinned_version="v0.1.4"
pinned_sha256="fd8e43afa7d953c48ad23ca74aa76cb5314fde5602d07149f954e8e3497b81a6"
pinned_api_version="1"

repo="${DYE2_REPO:-allofmeng/dye2}"
version="${DYE2_VERSION:-$pinned_version}"
expected_sha256="${DYE2_SHA256:-$pinned_sha256}"
expected_api_version="${DYE2_API_VERSION:-$pinned_api_version}"
plugins_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/assets/plugins"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

gh release download "$version" \
  --repo "$repo" --pattern 'dye2.reaplugin-*.zip' --dir "$tmp"

zip="$(ls "$tmp"/*.zip 2>/dev/null | head -n 1)"
if [ -z "$zip" ]; then
  echo "fetch_dye2_plugin: no dye2.reaplugin-*.zip asset in $repo $version" >&2
  exit 1
fi

if command -v shasum >/dev/null 2>&1; then
  actual_sha256="$(shasum -a 256 "$zip" | cut -d ' ' -f 1)"
else
  actual_sha256="$(sha256sum "$zip" | cut -d ' ' -f 1)"
fi
if [ "$actual_sha256" != "$expected_sha256" ]; then
  echo "fetch_dye2_plugin: checksum mismatch for $(basename "$zip")" >&2
  echo "  expected: $expected_sha256" >&2
  echo "  actual:   $actual_sha256" >&2
  exit 1
fi

mkdir -p "$plugins_dir"
rm -rf "$plugins_dir/dye2.reaplugin"
# ponytail: unzip on ubuntu/macos, bsdtar on windows runners (no unzip there).
if command -v unzip >/dev/null 2>&1; then
  unzip -q "$zip" -d "$plugins_dir"
else
  tar -xf "$zip" -C "$plugins_dir"
fi

manifest="$plugins_dir/dye2.reaplugin/manifest.json"
plugin_js="$plugins_dir/dye2.reaplugin/plugin.js"

for f in "$manifest" "$plugin_js"; do
  if [ ! -s "$f" ]; then
    echo "fetch_dye2_plugin: $(basename "$zip") is missing $(basename "$f")" >&2
    exit 1
  fi
done

manifest_id="$(jq -r '.id' "$manifest")"
if [ "$manifest_id" != "dye2.reaplugin" ]; then
  echo "fetch_dye2_plugin: manifest.json id is '$manifest_id', expected 'dye2.reaplugin'" >&2
  exit 1
fi

manifest_version="$(jq -r '.version' "$manifest")"
expected_manifest_version="${version#v}"
if [ "$manifest_version" != "$expected_manifest_version" ]; then
  echo "fetch_dye2_plugin: manifest.json version is '$manifest_version', expected '$expected_manifest_version'" >&2
  exit 1
fi

manifest_api_version="$(jq -r '.apiVersion' "$manifest")"
if [ "$manifest_api_version" != "$expected_api_version" ]; then
  echo "fetch_dye2_plugin: manifest.json apiVersion is '$manifest_api_version', expected '$expected_api_version'" >&2
  exit 1
fi

for permission in log api; do
  if ! jq -e --arg permission "$permission" '.permissions | index($permission) != null' "$manifest" >/dev/null; then
    echo "fetch_dye2_plugin: manifest.json is missing permission '$permission'" >&2
    exit 1
  fi
done

if ! grep -q 'createPlugin' "$plugin_js"; then
  echo "fetch_dye2_plugin: plugin.js has no 'createPlugin' entry point" >&2
  exit 1
fi

echo "fetch_dye2_plugin: installed $(basename "$zip") -> $plugins_dir/dye2.reaplugin"
