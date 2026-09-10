#!/usr/bin/env bash
set -euo pipefail

pinned_version="v1.1.0"
pinned_sha256="adcd5b8e1b03c707d15e6aee854244e9e0a9b8f439adf232a366b9b9d8997882"
pinned_api_version="1"

repo="${WEATHER_REPO:-ChampionDesigns/decaid-weather-plugin}"
version="${WEATHER_VERSION:-$pinned_version}"
expected_sha256="${WEATHER_SHA256:-$pinned_sha256}"
expected_api_version="${WEATHER_API_VERSION:-$pinned_api_version}"
plugins_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/assets/plugins"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

gh release download "$version" \
  --repo "$repo" --pattern 'weather.reaplugin-*.zip' --dir "$tmp"

zip="$(ls "$tmp"/*.zip 2>/dev/null | head -n 1)"
if [ -z "$zip" ]; then
  echo "fetch_weather_plugin: no weather.reaplugin-*.zip asset in $repo $version" >&2
  exit 1
fi

if command -v shasum >/dev/null 2>&1; then
  actual_sha256="$(shasum -a 256 "$zip" | cut -d ' ' -f 1)"
else
  actual_sha256="$(sha256sum "$zip" | cut -d ' ' -f 1)"
fi
if [ "$actual_sha256" != "$expected_sha256" ]; then
  echo "fetch_weather_plugin: checksum mismatch for $(basename "$zip")" >&2
  echo "  expected: $expected_sha256" >&2
  echo "  actual:   $actual_sha256" >&2
  exit 1
fi

mkdir -p "$plugins_dir"
rm -rf "$plugins_dir/weather.reaplugin"
if command -v unzip >/dev/null 2>&1; then
  unzip -q "$zip" -d "$plugins_dir"
else
  tar -xf "$zip" -C "$plugins_dir"
fi

manifest="$plugins_dir/weather.reaplugin/manifest.json"
plugin_js="$plugins_dir/weather.reaplugin/plugin.js"

for f in "$manifest" "$plugin_js"; do
  if [ ! -s "$f" ]; then
    echo "fetch_weather_plugin: $(basename "$zip") is missing $(basename "$f")" >&2
    exit 1
  fi
done

manifest_id="$(jq -r '.id' "$manifest")"
if [ "$manifest_id" != "weather.reaplugin" ]; then
  echo "fetch_weather_plugin: manifest.json id is '$manifest_id', expected 'weather.reaplugin'" >&2
  exit 1
fi

manifest_version="$(jq -r '.version' "$manifest")"
expected_manifest_version="${version#v}"
if [ "$manifest_version" != "$expected_manifest_version" ]; then
  echo "fetch_weather_plugin: manifest.json version is '$manifest_version', expected '$expected_manifest_version'" >&2
  exit 1
fi

manifest_api_version="$(jq -r '.apiVersion' "$manifest")"
if [ "$manifest_api_version" != "$expected_api_version" ]; then
  echo "fetch_weather_plugin: manifest.json apiVersion is '$manifest_api_version', expected '$expected_api_version'" >&2
  exit 1
fi

for permission in log api emit pluginStorage; do
  if ! jq -e --arg permission "$permission" '.permissions | index($permission) != null' "$manifest" >/dev/null; then
    echo "fetch_weather_plugin: manifest.json is missing permission '$permission'" >&2
    exit 1
  fi
done

if ! grep -q 'createPlugin' "$plugin_js"; then
  echo "fetch_weather_plugin: plugin.js has no 'createPlugin' entry point" >&2
  exit 1
fi

echo "fetch_weather_plugin: installed $(basename "$zip") -> $plugins_dir/weather.reaplugin"
