#!/bin/bash
set -euo pipefail

# Build SpeedtestMenuBar.app from the SwiftPM package (no Xcode).
# Output: <package>/build/SpeedtestMenuBar.app

PKG_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$PKG_DIR/version.env"

APP_DIR="$PKG_DIR/build/$APP_NAME.app"
BINARY_SRC="$PKG_DIR/.build/release/$APP_NAME"

echo "═══ Building $APP_NAME v$VERSION ($BUILD_NUMBER) ═══"

swift build -c release --package-path "$PKG_DIR"

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BINARY_SRC" "$APP_DIR/Contents/MacOS/$APP_NAME"

if [ -f "$PKG_DIR/Resources/AppIcon.icns" ]; then
    cp "$PKG_DIR/Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
fi

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>LSUIElement</key><true/>
    <key>NSHumanReadableCopyright</key><string>Personal utility — not for distribution.</string>
</dict></plist>
PLIST

codesign --force --sign - --timestamp=none "$APP_DIR"
codesign --verify --verbose=1 "$APP_DIR"
touch "$APP_DIR"

echo "═══ Done: $APP_DIR ═══"
