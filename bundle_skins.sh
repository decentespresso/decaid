#!/usr/bin/env bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="$SCRIPT_DIR/skin_sources.json"
CACHE_DIR="$SCRIPT_DIR/.skin_cache"
OUTPUT_DIR="$SCRIPT_DIR/assets/bundled_skins"

if [ ! -f "$CONFIG" ]; then
  echo "Warning: skin_sources.json not found, skipping skin bundling"
  exit 0
fi

if ! command -v jq &> /dev/null; then
  echo "Warning: jq not found, skipping skin bundling (install with: brew install jq)"
  exit 0
fi

CACHE_TTL=3600

mkdir -p "$CACHE_DIR" "$OUTPUT_DIR"

# Clear stale bundled zips so removed/renamed skin_sources entries don't linger.
# Cache dir is preserved to avoid re-downloading unchanged sources.
rm -f "$OUTPUT_DIR"/*.zip "$OUTPUT_DIR"/manifest.json

# Authenticate GitHub API requests when a token is available. Unauthenticated
# api.github.com is rate-limited to 60 req/hr per IP, which is shared across
# GitHub-hosted runners and routinely exhausted — leading to silent fetch
# failures and empty manifests. GITHUB_TOKEN is auto-injected in Actions; locally
# set GITHUB_TOKEN or GH_TOKEN if you hit rate limits.
GH_AUTH_HEADER=()
GH_TOKEN_VALUE="${GITHUB_TOKEN:-${GH_TOKEN:-}}"
# Fall back to gh CLI auth token if no env var set
if [ -z "$GH_TOKEN_VALUE" ] && command -v gh &>/dev/null; then
  GH_TOKEN_VALUE=$(gh auth token 2>/dev/null || true)
fi
if [ -n "$GH_TOKEN_VALUE" ]; then
  GH_AUTH_HEADER=(-H "Authorization: Bearer $GH_TOKEN_VALUE")
fi

# Track failures so we can exit non-zero if anything went wrong. Prior behavior
# was to `continue` past every failure and emit an empty manifest, which
# surfaced as a confusing test failure in `webui_storage_bundled_test.dart`
# rather than a clear bundle-step failure.
FAILED_SOURCES=()

COUNT=$(jq length "$CONFIG")

for ((i=0; i<COUNT; i++)); do
  TYPE=$(jq -r ".[$i].type" "$CONFIG")
  REPO=$(jq -r ".[$i].repo" "$CONFIG")
  REPO_NAME=$(echo "$REPO" | cut -d'/' -f2)

  echo "--- Processing source $((i+1))/$COUNT: $TYPE $REPO ---"

  case "$TYPE" in
    github_release)
      ASSET=$(jq -r ".[$i].asset // empty" "$CONFIG")
      PRERELEASE=$(jq -r ".[$i].prerelease // false" "$CONFIG")

      if [ "$PRERELEASE" = "true" ]; then
        RELEASE_JSON=$(curl -sfL "https://api.github.com/repos/$REPO/releases" \
          -H "Accept: application/vnd.github.v3+json" \
          -H "User-Agent: Decent-Build" \
          "${GH_AUTH_HEADER[@]}" 2>/dev/null) || { echo "Warning: Failed to fetch releases for $REPO"; FAILED_SOURCES+=("$REPO"); continue; }
        RELEASE_JSON=$(echo "$RELEASE_JSON" | jq '.[0]')
      else
        RELEASE_JSON=$(curl -sfL "https://api.github.com/repos/$REPO/releases/latest" \
          -H "Accept: application/vnd.github.v3+json" \
          -H "User-Agent: Decent-Build" \
          "${GH_AUTH_HEADER[@]}" 2>/dev/null) || { echo "Warning: Failed to fetch latest release for $REPO"; FAILED_SOURCES+=("$REPO"); continue; }
      fi

      TAG=$(echo "$RELEASE_JSON" | jq -r '.tag_name')

      if [ -n "$ASSET" ]; then
        DOWNLOAD_URL=$(echo "$RELEASE_JSON" | jq -r ".assets[] | select(.name == \"$ASSET\") | .browser_download_url")
      else
        DOWNLOAD_URL=$(echo "$RELEASE_JSON" | jq -r '.assets[] | select(.name | endswith(".zip")) | .browser_download_url' | head -1)
      fi

      if [ -z "$DOWNLOAD_URL" ] || [ "$DOWNLOAD_URL" = "null" ]; then
        echo "Warning: No download URL found for $REPO, skipping"
        FAILED_SOURCES+=("$REPO")
        continue
      fi

      CACHE_KEY=$(echo "$REPO_NAME-$TAG" | tr '/' '-')
      CACHE_FILE="$CACHE_DIR/$CACHE_KEY.zip"
      SKIN_ID="$REPO_NAME"

      if [ -f "$CACHE_FILE" ]; then
        echo "Using cached: $CACHE_FILE"
      else
        echo "Downloading: $DOWNLOAD_URL"
        curl -sfL -o "$CACHE_FILE" "$DOWNLOAD_URL" || { echo "Warning: Download failed for $REPO"; FAILED_SOURCES+=("$REPO"); continue; }
      fi

      cp "$CACHE_FILE" "$OUTPUT_DIR/$SKIN_ID.zip"
      echo "Bundled skin: $SKIN_ID"
      ;;

    github_branch)
      BRANCH=$(jq -r ".[$i].branch // \"main\"" "$CONFIG")
      URL="https://github.com/$REPO/archive/refs/heads/$BRANCH.zip"
      SKIN_ID="${REPO_NAME}-${BRANCH}"
      CACHE_FILE="$CACHE_DIR/${SKIN_ID}.zip"

      if [ -f "$CACHE_FILE" ]; then
        FILE_AGE=$(( $(date +%s) - $(stat -f %m "$CACHE_FILE" 2>/dev/null || stat -c %Y "$CACHE_FILE" 2>/dev/null || echo 0) ))
        if [ "$FILE_AGE" -lt "$CACHE_TTL" ]; then
          echo "Using cached (${FILE_AGE}s old): $CACHE_FILE"
          cp "$CACHE_FILE" "$OUTPUT_DIR/$SKIN_ID.zip"
          echo "Bundled skin: $SKIN_ID"
          continue
        fi
      fi

      echo "Downloading: $URL"
      curl -sfL -o "$CACHE_FILE" "$URL" || { echo "Warning: Download failed for $REPO/$BRANCH"; FAILED_SOURCES+=("$REPO/$BRANCH"); continue; }

      cp "$CACHE_FILE" "$OUTPUT_DIR/$SKIN_ID.zip"
      echo "Bundled skin: $SKIN_ID"
      ;;

    *)
      echo "Warning: Unknown source type '$TYPE', skipping"
      FAILED_SOURCES+=("$REPO ($TYPE)")
      continue
      ;;
  esac
done

if command -v zip &> /dev/null && command -v zipinfo &> /dev/null; then
  for ZIP in "$OUTPUT_DIR"/*.zip; do
    [ -f "$ZIP" ] || continue
    if zipinfo -1 "$ZIP" 2>/dev/null | grep -q node_modules; then
      echo "Stripping node_modules from $(basename "$ZIP")"
      zip -qd "$ZIP" "*/node_modules/*"
    fi
  done
fi

echo "[" > "$OUTPUT_DIR/manifest.json"
FIRST=true
for ZIP in "$OUTPUT_DIR"/*.zip; do
  [ -f "$ZIP" ] || continue
  SKIN_NAME=$(basename "$ZIP" .zip)
  if [ "$FIRST" = true ]; then FIRST=false; else echo "," >> "$OUTPUT_DIR/manifest.json"; fi
  printf '  "%s"' "$SKIN_NAME" >> "$OUTPUT_DIR/manifest.json"
done
echo "" >> "$OUTPUT_DIR/manifest.json"
echo "]" >> "$OUTPUT_DIR/manifest.json"

BUNDLED_COUNT=$(ls -1 "$OUTPUT_DIR"/*.zip 2>/dev/null | wc -l | tr -d ' ')
echo "--- Done: $BUNDLED_COUNT skins bundled ---"

if [ "${#FAILED_SOURCES[@]}" -gt 0 ]; then
  echo "ERROR: ${#FAILED_SOURCES[@]} of $COUNT skin source(s) failed:"
  for SRC in "${FAILED_SOURCES[@]}"; do
    echo "  - $SRC"
  done
  if [ -z "$GH_TOKEN_VALUE" ]; then
    echo "Hint: set GITHUB_TOKEN or GH_TOKEN to avoid GitHub API rate limits."
  fi
  exit 1
fi
