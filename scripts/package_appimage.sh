#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: $0 <flutter-bundle> <x86_64|aarch64> <version> <out-dir>" >&2
  exit 2
}

BUNDLE="${1:-}"
ARCH="${2:-}"
VERSION="${3:-}"
OUTDIR="${4:-}"

[ -n "$BUNDLE" ] && [ -n "$ARCH" ] && [ -n "$VERSION" ] && [ -n "$OUTDIR" ] || usage
case "$ARCH" in
  x86_64 | aarch64) ;;
  *) usage ;;
esac

LINUXDEPLOY_TAG="1-alpha-20251107-1"
LINUXDEPLOY_URL="https://github.com/linuxdeploy/linuxdeploy/releases/download/${LINUXDEPLOY_TAG}/linuxdeploy-${ARCH}.AppImage"
case "$ARCH" in
  x86_64) LINUXDEPLOY_SHA256="c20cd71e3a4e3b80c3483cef793cda3f4e990aca14014d23c544ca3ce1270b4d" ;;
  aarch64) LINUXDEPLOY_SHA256="620095110d693282b8ebeb244a95b5e911cf8f65f76c88b4b47d16ae6346fcff" ;;
esac
GTK_PLUGIN_COMMIT="7a3fbc31a9e5075073ff8790f26effbac5f84453"
GTK_PLUGIN_URL="https://raw.githubusercontent.com/linuxdeploy/linuxdeploy-plugin-gtk/${GTK_PLUGIN_COMMIT}/linuxdeploy-plugin-gtk.sh"
GTK_PLUGIN_SHA256="b0f4cbc684a0103a9651f0955b635eaea0096b3a66c0f5a2c2aa337960375171"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ICON="${REPO_ROOT}/macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_512.png"
DESKTOP="${REPO_ROOT}/linux/packaging/net.tadel.reaprime.desktop"
APPRUN="${REPO_ROOT}/linux/packaging/AppRun"

for required in "${BUNDLE}/decaid" "${ICON}" "${DESKTOP}" "${APPRUN}"; do
  [ -f "${required}" ] || { echo "missing ${required}" >&2; exit 1; }
done

mkdir -p "${OUTDIR}"
OUTDIR="$(cd "${OUTDIR}" && pwd)"

CACHE_DIR="${XDG_CACHE_HOME:-${HOME}/.cache}/decaid-appimage"
TOOLS_DIR="${CACHE_DIR}/tools-${ARCH}"
mkdir -p "${CACHE_DIR}"

fetch_verified() {
  local url="$1" dest="$2" sha256="$3"
  if [ ! -f "${dest}" ]; then
    curl -fsSL --retry 3 -o "${dest}.part" "${url}"
    mv "${dest}.part" "${dest}"
  fi
  echo "${sha256}  ${dest}" | sha256sum -c --quiet
}

fetch_verified "${LINUXDEPLOY_URL}" "${CACHE_DIR}/linuxdeploy-${ARCH}.AppImage" "${LINUXDEPLOY_SHA256}"
fetch_verified "${GTK_PLUGIN_URL}" "${CACHE_DIR}/linuxdeploy-plugin-gtk.sh" "${GTK_PLUGIN_SHA256}"
chmod +x "${CACHE_DIR}/linuxdeploy-plugin-gtk.sh"

if [ ! -x "${TOOLS_DIR}/linuxdeploy/AppRun" ]; then
  rm -rf "${TOOLS_DIR}"
  mkdir -p "${TOOLS_DIR}"
  (cd "${TOOLS_DIR}" && "${CACHE_DIR}/linuxdeploy-${ARCH}.AppImage" --appimage-extract >/dev/null)
  mv "${TOOLS_DIR}/squashfs-root" "${TOOLS_DIR}/linuxdeploy"
fi

mkdir -p "${TOOLS_DIR}/bin"
ln -sf "${TOOLS_DIR}/linuxdeploy/AppRun" "${TOOLS_DIR}/bin/linuxdeploy"
ln -sf "${CACHE_DIR}/linuxdeploy-plugin-gtk.sh" "${TOOLS_DIR}/bin/linuxdeploy-plugin-gtk"
export PATH="${TOOLS_DIR}/bin:${PATH}"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "${WORK_DIR}"' EXIT

APPDIR="${WORK_DIR}/Decaid.AppDir"
mkdir -p "${APPDIR}/usr/lib/decaid"
cp -a "${BUNDLE}/." "${APPDIR}/usr/lib/decaid/"
install -m 0755 "${APPRUN}" "${APPDIR}/AppRun"
install -m 0644 "${ICON}" "${APPDIR}/.DirIcon"

OUTPUT="${OUTDIR}/decaid-linux-${ARCH}-${VERSION}.AppImage"
export ARCH
export DEPLOY_GTK_VERSION=3
export OUTPUT
(cd "${WORK_DIR}" && linuxdeploy \
  --appdir "${APPDIR}" \
  --executable "${APPDIR}/usr/lib/decaid/decaid" \
  --desktop-file "${DESKTOP}" \
  --icon-file "${ICON}" \
  --icon-filename "net.tadel.reaprime" \
  --plugin gtk \
  --output appimage)

[ -s "${OUTPUT}" ] || { echo "AppImage build produced no output" >&2; exit 1; }
echo "BUILT ${OUTPUT} ($(du -h "${OUTPUT}" | cut -f1))"
