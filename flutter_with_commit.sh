#!/usr/bin/env bash
set -e

# --- Load local env file if present (not used in CI) ---
if [ -f .env.dev ]; then
  set -a
  source .env.dev
  set +a
fi

COMMIT=$(git rev-parse HEAD 2>/dev/null || echo unknown)
COMMIT_SHORT=$(git rev-parse --short HEAD 2>/dev/null || echo unknown)
BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)
BUILD_TIME=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# --- Optional secrets from environment ---
# Note: env var is FEEDBACK_TOKEN (not GITHUB_*) because GitHub Actions
# reserves the GITHUB_ prefix for its own variables.
FEEDBACK_TOKEN_DEFINE=()
if [ -n "$FEEDBACK_TOKEN" ]; then
  FEEDBACK_TOKEN_DEFINE=(--dart-define=GITHUB_FEEDBACK_TOKEN="$FEEDBACK_TOKEN")
fi

# --- Extract version from git tag ---
# Get the most recent tag (if any), strip 'v' prefix if present
TAG=$(git describe --tags --abbrev=0 2>/dev/null || echo "")
if [ -z "$TAG" ]; then
  VERSION="0.0.0-dev"
else
  VERSION="${TAG#v}"
fi

# --- Build number from commit count on main (monotonically increasing) ---
# Use origin/main so feature branches don't inflate the version code
BUILD_NUMBER=$(git rev-list --count origin/main 2>/dev/null || echo "1")

# --- Build name: semver part only (strip pre-release suffix for native platforms) ---
# e.g. "1.2.3-beta.1" -> build-name "1.2.3", but VERSION dart-define keeps the full string
BUILD_NAME="${VERSION%%-*}"

SKIP_SKINS=false
FILTERED_ARGS=()
for arg in "$@"; do
  if [ "$arg" = "--skip-skins" ]; then
    SKIP_SKINS=true
  else
    FILTERED_ARGS+=("$arg")
  fi
done
set -- "${FILTERED_ARGS[@]}"

# --- Command required ---
if [ $# -lt 1 ]; then
  echo "Usage: $0 [--skip-skins] <flutter command> [arguments...]"
  exit 1
fi

COMMAND="$1"
shift

EXTRA_ARGS=("$@")

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ "$SKIP_SKINS" = true ]; then
  echo "Skipping skin bundling (--skip-skins)"
elif [ -f "$SCRIPT_DIR/bundle_skins.sh" ]; then
  echo "Bundling skins..."
  bash "$SCRIPT_DIR/bundle_skins.sh"
fi

if [ "$COMMAND" = "build" ]; then
    if [ ${#EXTRA_ARGS[@]} -lt 1 ]; then
      echo "Error: flutter build requires a target (e.g., macos)"
      exit 1
    fi

    TARGET="${EXTRA_ARGS[0]}"
    REMAINDER=("${EXTRA_ARGS[@]:1}")

    flutter build "$TARGET" \
      --build-name="$BUILD_NAME" \
      --build-number="$BUILD_NUMBER" \
      --dart-define=COMMIT="$COMMIT" \
      --dart-define=COMMIT_SHORT="$COMMIT_SHORT" \
      --dart-define=BRANCH="$BRANCH" \
      --dart-define=BUILD_TIME="$BUILD_TIME" \
      --dart-define=VERSION="$VERSION" \
      --dart-define=BUILD_NUMBER="$BUILD_NUMBER" \
      "${FEEDBACK_TOKEN_DEFINE[@]}" \
      "${REMAINDER[@]}"

    exit $?
fi

exec flutter "$COMMAND" \
  --dart-define=COMMIT="$COMMIT" \
  --dart-define=COMMIT_SHORT="$COMMIT_SHORT" \
  --dart-define=BRANCH="$BRANCH" \
  --dart-define=BUILD_TIME="$BUILD_TIME" \
  --dart-define=VERSION="$VERSION" \
  --dart-define=BUILD_NUMBER="$BUILD_NUMBER" \
  "${FEEDBACK_TOKEN_DEFINE[@]}" \
  "${EXTRA_ARGS[@]}"
