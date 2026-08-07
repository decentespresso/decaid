#!/bin/bash
set -e

PATH="${PATH}:$FLUTTER_ROOT/bin:${PUB_CACHE}/bin:$HOME/.pub-cache/bin"

PATH_TO_CRASHLYTICS_UPLOAD_SCRIPT=""

if [ -n "$PODS_ROOT" ] && [ -f "$PODS_ROOT/FirebaseCrashlytics/run" ]; then
  PATH_TO_CRASHLYTICS_UPLOAD_SCRIPT="$PODS_ROOT/FirebaseCrashlytics/run"
fi

if [ -z "$PATH_TO_CRASHLYTICS_UPLOAD_SCRIPT" ]; then
  DERIVED_FROM_BUILD_ROOT="$(echo "$BUILD_ROOT" | sed -E 's|(.*DerivedData/[^/]+).*|\1|')"
  for candidate in \
    "${BUILD_DIR%/Build/*}/SourcePackages/checkouts/firebase-ios-sdk/Crashlytics/run" \
    "${DERIVED_FROM_BUILD_ROOT}/SourcePackages/checkouts/firebase-ios-sdk/Crashlytics/run"; do
    if [ -f "$candidate" ]; then
      PATH_TO_CRASHLYTICS_UPLOAD_SCRIPT="$candidate"
      break
    fi
  done
fi

if [ -z "$PATH_TO_CRASHLYTICS_UPLOAD_SCRIPT" ]; then
  for root in \
    "$BUILD_DIR" \
    "${BUILD_DIR%/Build/*}" \
    "$BUILD_ROOT" \
    "${BUILD_ROOT%/Build/*}" \
    "$OBJROOT" \
    "$SYMROOT" \
    "${SRCROOT}/../build" \
    "${PROJECT_DIR}/../build" \
    "$HOME/Library/Developer/Xcode/DerivedData"; do
    [ -n "$root" ] && [ -d "$root" ] || continue
    found=$(find "$root" \
      -path "*SourcePackages/checkouts/firebase-ios-sdk/Crashlytics/run" \
      -print -quit 2>/dev/null || true)
    if [ -n "$found" ]; then
      PATH_TO_CRASHLYTICS_UPLOAD_SCRIPT="$found"
      break
    fi
  done
fi

if [ -z "$PATH_TO_CRASHLYTICS_UPLOAD_SCRIPT" ] || [ ! -f "$PATH_TO_CRASHLYTICS_UPLOAD_SCRIPT" ]; then
  echo "error: firebase-ios-sdk Crashlytics 'run' script not found in Pods or SPM SourcePackages." >&2
  echo "  PODS_ROOT=$PODS_ROOT" >&2
  echo "  BUILD_DIR=$BUILD_DIR" >&2
  echo "  BUILD_ROOT=$BUILD_ROOT" >&2
  exit 1
fi

PLATFORM_FLAG="${1:-ios}"

flutterfire upload-crashlytics-symbols \
  --upload-symbols-script-path="$PATH_TO_CRASHLYTICS_UPLOAD_SCRIPT" \
  --platform="$PLATFORM_FLAG" \
  --apple-project-path="${SRCROOT}" \
  --env-platform-name="${PLATFORM_NAME}" \
  --env-configuration="${CONFIGURATION}" \
  --env-project-dir="${PROJECT_DIR}" \
  --env-built-products-dir="${BUILT_PRODUCTS_DIR}" \
  --env-dwarf-dsym-folder-path="${DWARF_DSYM_FOLDER_PATH}" \
  --env-dwarf-dsym-file-name="${DWARF_DSYM_FILE_NAME}" \
  --env-infoplist-path="${INFOPLIST_PATH}" \
  --default-config=default
