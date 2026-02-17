#!/bin/bash
set -euo pipefail

if (( $# != 2 )); then
  echo "Usage: $0 <version> <base_url>" >&2
  echo "Example: $0 2026.02.16 https://raw.githubusercontent.com/OWNER/REPO/main/dist" >&2
  exit 1
fi

VERSION="$1"
BASE_URL="${2%/}"

if [[ ! "$VERSION" =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "Invalid version '$VERSION'. Use only letters, digits, dot, underscore, dash." >&2
  exit 1
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC_DIR="$ROOT_DIR/source"
DIST_DIR="$ROOT_DIR/dist"
TEMPLATE="$ROOT_DIR/zfs.autosnapshot.plg.in"

PKG_FILE="zfs-autosnapshot-${VERSION}-noarch-1.txz"
PKG_PATH="$DIST_DIR/$PKG_FILE"
PLG_PATH="$DIST_DIR/zfs.autosnapshot.plg"

mkdir -p "$DIST_DIR"

if [[ ! -d "$SRC_DIR" ]]; then
  echo "Missing source directory: $SRC_DIR" >&2
  exit 1
fi

if [[ ! -f "$TEMPLATE" ]]; then
  echo "Missing plugin template: $TEMPLATE" >&2
  exit 1
fi

STAGING_DIR="$(mktemp -d)"
cleanup() {
  rm -rf "$STAGING_DIR"
}
trap cleanup EXIT

cp -a "$SRC_DIR/." "$STAGING_DIR/"

# Strip common macOS Finder metadata from release payloads.
find "$STAGING_DIR" -name ".DS_Store" -delete

# Package as .txz (tar + xz), compatible with Unraid upgradepkg/removepkg flow.
tar -C "$STAGING_DIR" -cJf "$PKG_PATH" .

if command -v md5sum >/dev/null 2>&1; then
  PKG_MD5="$(md5sum "$PKG_PATH" | awk '{print $1}')"
else
  PKG_MD5="$(md5 -q "$PKG_PATH")"
fi

BUILD_DATE="$(date +%Y-%m-%d)"

sed \
  -e "s|__VERSION__|$VERSION|g" \
  -e "s|__BASE_URL__|$BASE_URL|g" \
  -e "s|__PKG_MD5__|$PKG_MD5|g" \
  -e "s|__BUILD_DATE__|$BUILD_DATE|g" \
  "$TEMPLATE" > "$PLG_PATH"

cp -f "$PLG_PATH" "$ROOT_DIR/zfs.autosnapshot.plg"

cat <<MSG
Built release artifacts:
  $PKG_PATH
  $PLG_PATH
  $ROOT_DIR/zfs.autosnapshot.plg

Package MD5:
  $PKG_MD5
MSG
