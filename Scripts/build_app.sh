#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="CPA"
BUNDLE_ID="local.cpa.statusbar"
BUILD_CONFIG="${BUILD_CONFIG:-release}"
ICON_FILE="$ROOT_DIR/Resources/AppIcon.icns"
DIST_DIR="$ROOT_DIR/dist"

cd "$ROOT_DIR"
swift build -c "$BUILD_CONFIG" --product CPAStatusBar

BINARY="$ROOT_DIR/.build/$BUILD_CONFIG/CPAStatusBar"
APP_DIR="$DIST_DIR/$APP_NAME.app"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
STAGE_APP="$TMP_DIR/$APP_NAME.app"
CONTENTS="$STAGE_APP/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"

mkdir -p "$DIST_DIR"
rm -rf "$APP_DIR"
mkdir -p "$MACOS" "$RESOURCES"
cp "$BINARY" "$MACOS/$APP_NAME"
chmod +x "$MACOS/$APP_NAME"
cp "$ICON_FILE" "$RESOURCES/AppIcon.icns"

cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundleDisplayName</key>
  <string>$APP_NAME</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
PLIST

ditto "$STAGE_APP" "$APP_DIR"
if command -v xattr >/dev/null 2>&1; then
  find "$APP_DIR" -exec xattr -d com.apple.FinderInfo {} + 2>/dev/null || true
  find "$APP_DIR" -exec xattr -d com.apple.ResourceFork {} + 2>/dev/null || true
  find "$APP_DIR" -exec xattr -d 'com.apple.fileprovider.fpfs#P' {} + 2>/dev/null || true
fi

echo "$APP_DIR"
