#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT/.build/app"
APP="$BUILD_DIR/SwiftFind.app"

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

python3 "$ROOT/Resources/AppIcon.iconset/generate_icon.py"
iconutil -c icns "$ROOT/Resources/AppIcon.iconset" -o "$BUILD_DIR/AppIcon.icns"

swift build -c release --product SwiftFind
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/.build/out/Products/Release/SwiftFind" "$APP/Contents/MacOS/SwiftFind"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$BUILD_DIR/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

chmod +x "$APP/Contents/MacOS/SwiftFind"
codesign --force --deep --sign - "$APP" >/dev/null

echo "Built: $APP"
