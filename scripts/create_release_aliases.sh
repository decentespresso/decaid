#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "Usage: $0 <artifact-directory> <version>" >&2
  exit 1
fi

ARTIFACTS_DIR="$1"
VERSION="$2"
[ -d "$ARTIFACTS_DIR" ] || { echo "FAIL: missing $ARTIFACTS_DIR" >&2; exit 1; }

ARTIFACTS_DIR="$(cd "$ARTIFACTS_DIR" && pwd)"
MANIFEST="$(dirname "$ARTIFACTS_DIR")/decaid-latest-SHA256SUMS.txt"
cd "$ARTIFACTS_DIR"

SOURCES=()
while IFS= read -r -d '' source; do
  SOURCES+=("$source")
done < <(find . -type f -name "*-${VERSION}.*" -print0 | sort -z)

[ "${#SOURCES[@]}" -gt 0 ] || {
  echo "FAIL: no versioned release artifacts found for $VERSION" >&2
  exit 1
}

ALIASES=()
for source in "${SOURCES[@]}"; do
  alias="${source/-${VERSION}/-latest}"
  cp "$source" "$alias"
  cmp -s "$source" "$alias" || { echo "FAIL: $alias differs from $source" >&2; exit 1; }
  ALIASES+=("$alias")
done

{
  for alias in "${ALIASES[@]}"; do
    sha256sum "$alias"
  done
} | sed 's| \./[^/]*/| |' > "$MANIFEST"
cat "$MANIFEST"
