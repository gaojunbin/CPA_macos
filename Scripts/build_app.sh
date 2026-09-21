#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="CPA"
BUNDLE_ID="local.cpa.statusbar"
BUILD_CONFIG="${BUILD_CONFIG:-release}"
ICON_FILE="$ROOT_DIR/Resources/AppIcon.icns"
DIST_DIR="${DIST_DIR:-$ROOT_DIR/dist}"
BUILD_DIR="${BUILD_DIR:-/tmp/cpa-macos-build}"
APP_VERSION="${VERSION:-1.5.0}"
APP_VERSION="${APP_VERSION#v}"
if [[ ! "$APP_VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
  echo "Expected a stable semantic version, got: $APP_VERSION" >&2
  exit 2
fi
read -r -a BUILD_ARCHS <<< "${ARCHS:-arm64 x86_64}"
BUILD_ARGS=()
for arch in "${BUILD_ARCHS[@]}"; do BUILD_ARGS+=(--arch "$arch"); done

cd "$ROOT_DIR"
swift build -c "$BUILD_CONFIG" --scratch-path "$BUILD_DIR" "${BUILD_ARGS[@]}"
BIN_DIR="$(swift build -c "$BUILD_CONFIG" --scratch-path "$BUILD_DIR" "${BUILD_ARGS[@]}" --show-bin-path)"

BINARY="$BIN_DIR/CPAStatusBar"
APP_DIR="$DIST_DIR/$APP_NAME.app"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
STAGE_APP="$TMP_DIR/$APP_NAME.app"
CONTENTS="$STAGE_APP/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"
HELPERS="$CONTENTS/Helpers"

mkdir -p "$DIST_DIR"
rm -rf "$APP_DIR"
mkdir -p "$MACOS" "$RESOURCES" "$HELPERS"
cp "$BIN_DIR/CPAUpdateInstaller" "$HELPERS/CPAUpdateInstaller"
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
  <string>$APP_VERSION</string>
  <key>CFBundleVersion</key>
  <string>9</string>
  <key>CPAUpdateProtocol</key>
  <integer>1</integer>
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
