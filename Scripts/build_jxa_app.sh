#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="CLIProxyAPI Pool Monitor"
APP_DIR="$ROOT_DIR/dist/$APP_NAME.app"

mkdir -p "$ROOT_DIR/dist"
rm -rf "$APP_DIR"
osacompile -l JavaScript -o "$APP_DIR" "$ROOT_DIR/JXA/CPAQuotaBar.jxa"

/usr/libexec/PlistBuddy -c "Set :LSUIElement true" "$APP_DIR/Contents/Info.plist" 2>/dev/null || \
  /usr/libexec/PlistBuddy -c "Add :LSUIElement bool true" "$APP_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier local.cpa.quota-bar" "$APP_DIR/Contents/Info.plist" 2>/dev/null || \
  /usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string local.cpa.quota-bar" "$APP_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName $APP_NAME" "$APP_DIR/Contents/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $APP_NAME" "$APP_DIR/Contents/Info.plist" 2>/dev/null || true

echo "$APP_DIR"
