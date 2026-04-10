#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION_FILE="$ROOT_DIR/VERSION"
VERIFY_SCRIPT="$ROOT_DIR/scripts/verify-release.sh"

usage() {
  cat >&2 <<'EOF'
Usage:
  build-release.sh <version> <base_url>
  build-release.sh <base_url>

When <version> is omitted, the script reads it from ./VERSION.
Example:
  ./scripts/build-release.sh 2026.02.16 https://raw.githubusercontent.com/OWNER/REPO/main/dist
  ./scripts/build-release.sh https://raw.githubusercontent.com/OWNER/REPO/main/dist
EOF
  exit 1
}

case $# in
  1)
    if [[ ! -f "$VERSION_FILE" ]]; then
      echo "Missing version file: $VERSION_FILE" >&2
      exit 1
    fi
    VERSION="$(tr -d '[:space:]' < "$VERSION_FILE")"
    BASE_URL="${1%/}"
    ;;
  2)
    VERSION="$1"
    BASE_URL="${2%/}"
    ;;
  *)
    usage
    ;;
esac

if [[ ! "$VERSION" =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "Invalid version '$VERSION'. Use only letters, digits, dot, underscore, dash." >&2
  exit 1
fi

SRC_DIR="$ROOT_DIR/source"
DIST_DIR="$ROOT_DIR/dist"
TEMPLATE="$ROOT_DIR/zfs.autosnapshot.plg.in"

PKG_FILE="zfs-autosnapshot-${VERSION}-noarch-1.txz"
PKG_PATH="$DIST_DIR/$PKG_FILE"
PLG_PATH="$DIST_DIR/zfs.autosnapshot.plg"
ICON_SRC="$SRC_DIR/usr/local/emhttp/plugins/zfs.autosnapshot/images/zfs-autosnapshot.png"
ICON_DIST_PATH="$DIST_DIR/zfs-autosnapshot.png"

mkdir -p "$DIST_DIR"

if [[ ! -d "$SRC_DIR" ]]; then
  echo "Missing source directory: $SRC_DIR" >&2
  exit 1
fi

if [[ ! -f "$TEMPLATE" ]]; then
  echo "Missing plugin template: $TEMPLATE" >&2
  exit 1
fi

if [[ ! -f "$ICON_SRC" ]]; then
  echo "Missing icon file: $ICON_SRC" >&2
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
find "$STAGING_DIR" -name "._*" -delete
find "$STAGING_DIR" -name ".AppleDouble" -type d -prune -exec rm -rf {} +

build_txz() {
  if tar --version 2>/dev/null | grep -qi "bsdtar"; then
    # macOS bsdtar can embed AppleDouble metadata unless explicitly disabled.
    local bsdtar_args=(
      --uid 0
      --gid 0
      --uname root
      --gname root
      -C "$STAGING_DIR"
      -cJf "$PKG_PATH"
      .
    )
    if ! COPYFILE_DISABLE=1 COPY_EXTENDED_ATTRIBUTES_DISABLE=1 tar --no-mac-metadata "${bsdtar_args[@]}" 2>/dev/null; then
      COPYFILE_DISABLE=1 COPY_EXTENDED_ATTRIBUTES_DISABLE=1 tar "${bsdtar_args[@]}"
    fi
  else
    tar \
      --owner=0 \
      --group=0 \
      --numeric-owner \
      -C "$STAGING_DIR" \
      -cJf "$PKG_PATH" \
      .
  fi
}

# Package as .txz (tar + xz), compatible with Unraid upgradepkg/removepkg flow.
build_txz

if [[ -x "$VERIFY_SCRIPT" ]]; then
  "$VERIFY_SCRIPT" "$PKG_PATH" "$ROOT_DIR"
fi

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
cp -f "$ICON_SRC" "$ICON_DIST_PATH"

cat <<MSG
Built release artifacts:
  $PKG_PATH
  $PLG_PATH
  $ICON_DIST_PATH
  $ROOT_DIR/zfs.autosnapshot.plg

Package MD5:
  $PKG_MD5
MSG
