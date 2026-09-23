#!/bin/bash
# Builds Bill via SwiftPM and assembles a real Bill.app bundle (no Xcode.app required).
set -euo pipefail

CONFIG="${1:-debug}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Bill"
BUILD_DIR="$ROOT_DIR/.build/$CONFIG"
APP_BUNDLE="$ROOT_DIR/$APP_NAME.app"

echo "==> Building ($CONFIG)"
swift build -c "$CONFIG" --package-path "$ROOT_DIR"

echo "==> Assembling $APP_BUNDLE"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
cp "$BUILD_DIR/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp "$ROOT_DIR/Resources/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
cp "$ROOT_DIR/Resources/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"

# Copy any SwiftPM resource bundles the target produced (fonts, asset catalogs, etc.)
for bundle in "$BUILD_DIR"/*.bundle; do
  [ -d "$bundle" ] && cp -R "$bundle" "$APP_BUNDLE/Contents/Resources/"
done

echo "==> Ad-hoc codesigning"
codesign --force --deep -s - "$APP_BUNDLE"

echo "==> Done: $APP_BUNDLE"
