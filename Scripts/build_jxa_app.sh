#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="CPA"
DIST_DIR="$ROOT_DIR/dist"
APP_DIR="$ROOT_DIR/dist/$APP_NAME.app"
ICON_FILE="$ROOT_DIR/Resources/AppIcon.icns"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
STAGE_APP="$TMP_DIR/$APP_NAME.app"

mkdir -p "$DIST_DIR"
rm -rf "$APP_DIR"
osacompile -l JavaScript -o "$STAGE_APP" "$ROOT_DIR/JXA/CPAQuotaBar.jxa"
mkdir -p "$STAGE_APP/Contents/Resources"
cp "$ICON_FILE" "$STAGE_APP/Contents/Resources/AppIcon.icns"

INFO_PLIST="$STAGE_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :LSUIElement true" "$INFO_PLIST" 2>/dev/null || \
  /usr/libexec/PlistBuddy -c "Add :LSUIElement bool true" "$INFO_PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier local.cpa.quota-bar" "$INFO_PLIST" 2>/dev/null || \
  /usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string local.cpa.quota-bar" "$INFO_PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleName $APP_NAME" "$INFO_PLIST" 2>/dev/null || \
  /usr/libexec/PlistBuddy -c "Add :CFBundleName string $APP_NAME" "$INFO_PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $APP_NAME" "$INFO_PLIST" 2>/dev/null || \
  /usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string $APP_NAME" "$INFO_PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleIconFile AppIcon" "$INFO_PLIST" 2>/dev/null || \
  /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$INFO_PLIST"
/usr/libexec/PlistBuddy -c "Delete :CFBundleIconName" "$INFO_PLIST" 2>/dev/null || true

if command -v xattr >/dev/null 2>&1; then
  xattr -cr "$STAGE_APP" 2>/dev/null || true
fi
rm -rf "$STAGE_APP/Contents/_CodeSignature"
ditto "$STAGE_APP" "$APP_DIR"
if command -v xattr >/dev/null 2>&1; then
  find "$APP_DIR" -exec xattr -d com.apple.FinderInfo {} + 2>/dev/null || true
  find "$APP_DIR" -exec xattr -d com.apple.ResourceFork {} + 2>/dev/null || true
  find "$APP_DIR" -exec xattr -d 'com.apple.fileprovider.fpfs#P' {} + 2>/dev/null || true
fi

echo "$APP_DIR"
