#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="${APP_NAME:-CPA}"
APP_VARIANT="${APP_VARIANT:-jxa}"
DIST_DIR="$ROOT_DIR/dist"
OUTPUT_DIR="${OUTPUT_DIR:-$DIST_DIR/github}"
APP_DIR="$DIST_DIR/$APP_NAME.app"
WORK_DIR="$(mktemp -d)"
SIGNED_APP_DIR="$WORK_DIR/$APP_NAME.app"
DMG_STAGE_DIR="$WORK_DIR/dmg"
trap 'rm -rf "$WORK_DIR"' EXIT

usage() {
  cat <<USAGE
Usage: Scripts/package_github_release.sh

Environment:
  VERSION=1.0.0                 Version used in artifact names. Defaults to tag,
                                app Info.plist version, or git commit.
  APP_VARIANT=jxa|native        App bundle builder to use. Defaults to jxa.
  OUTPUT_DIR=dist/github        Directory for release artifacts.
  CODESIGN_IDENTITY=-           Signing identity. Defaults to ad-hoc signing.
  SKIP_CODESIGN=1               Skip signing.

Outputs:
  <OUTPUT_DIR>/CPA-<version>-macOS.dmg
  <OUTPUT_DIR>/CPA-<version>-macOS.zip
  <OUTPUT_DIR>/CPA-<version>-macOS-SHA256.txt
USAGE
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

case "$APP_VARIANT" in
  jxa)
    "$ROOT_DIR/Scripts/build_jxa_app.sh" >/dev/null
    ;;
  native)
    "$ROOT_DIR/Scripts/build_app.sh" >/dev/null
    ;;
  *)
    echo "Unsupported APP_VARIANT: $APP_VARIANT" >&2
    echo "Expected 'jxa' or 'native'." >&2
    exit 2
    ;;
esac

if [[ ! -d "$APP_DIR" ]]; then
  echo "Expected app bundle was not built: $APP_DIR" >&2
  exit 1
fi

if [[ -z "${VERSION:-}" ]]; then
  if git -C "$ROOT_DIR" describe --tags --exact-match >/dev/null 2>&1; then
    VERSION="$(git -C "$ROOT_DIR" describe --tags --exact-match)"
  else
    VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_DIR/Contents/Info.plist" 2>/dev/null || true)"
  fi
fi

if [[ -z "${VERSION:-}" ]]; then
  if git -C "$ROOT_DIR" rev-parse --short HEAD >/dev/null 2>&1; then
    VERSION="0.0.0-$(git -C "$ROOT_DIR" rev-parse --short HEAD)"
  else
    VERSION="0.0.0-$(date +%Y%m%d%H%M%S)"
  fi
fi

VERSION="${VERSION#v}"
SAFE_VERSION="$(printf "%s" "$VERSION" | tr -c "[:alnum:]._" "-")"
ARTIFACT_BASENAME="${ARTIFACT_BASENAME:-$APP_NAME-$SAFE_VERSION-macOS}"
DMG_PATH="$OUTPUT_DIR/$ARTIFACT_BASENAME.dmg"
ZIP_PATH="$OUTPUT_DIR/$ARTIFACT_BASENAME.zip"
CHECKSUM_PATH="$OUTPUT_DIR/$ARTIFACT_BASENAME-SHA256.txt"

mkdir -p "$OUTPUT_DIR"
ditto --norsrc "$APP_DIR" "$SIGNED_APP_DIR"

if command -v xattr >/dev/null 2>&1; then
  find "$SIGNED_APP_DIR" -exec xattr -d com.apple.FinderInfo {} + 2>/dev/null || true
  find "$SIGNED_APP_DIR" -exec xattr -d com.apple.ResourceFork {} + 2>/dev/null || true
  find "$SIGNED_APP_DIR" -exec xattr -d 'com.apple.fileprovider.fpfs#P' {} + 2>/dev/null || true
fi

if [[ "${SKIP_CODESIGN:-0}" != "1" && -x /usr/bin/codesign ]]; then
  CODESIGN_IDENTITY="${CODESIGN_IDENTITY:--}"
  if ! /usr/bin/codesign --force --deep --options runtime --sign "$CODESIGN_IDENTITY" "$SIGNED_APP_DIR" >/dev/null 2>&1; then
    /usr/bin/codesign --force --deep --sign "$CODESIGN_IDENTITY" "$SIGNED_APP_DIR" >/dev/null
  fi
  /usr/bin/codesign --verify --deep --strict "$SIGNED_APP_DIR" >/dev/null
fi

rm -f "$DMG_PATH" "$ZIP_PATH" "$CHECKSUM_PATH"
(
  cd "$WORK_DIR"
  ditto -c -k --keepParent --sequesterRsrc "$APP_NAME.app" "$ZIP_PATH"
)

mkdir -p "$DMG_STAGE_DIR"
ditto --norsrc "$SIGNED_APP_DIR" "$DMG_STAGE_DIR/$APP_NAME.app"
ln -s /Applications "$DMG_STAGE_DIR/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$DMG_STAGE_DIR" -ov -format UDZO "$DMG_PATH" >/dev/null

(
  cd "$OUTPUT_DIR"
  shasum -a 256 "$(basename "$DMG_PATH")" "$(basename "$ZIP_PATH")" > "$(basename "$CHECKSUM_PATH")"
)

echo "Created:"
echo "  $DMG_PATH"
echo "  $ZIP_PATH"
echo "  $CHECKSUM_PATH"
