#!/bin/bash
set -euo pipefail

PKG_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$PKG_DIR/version.env"
BUILD_DIR="$PKG_DIR/build"
APP_DIR="$BUILD_DIR/$APP_NAME.app"
PROBE_NAME=speedtest-live-probe

mkdir -p "$BUILD_DIR"
STAGE="$(mktemp -d "$BUILD_DIR/.bundle.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
APP="$STAGE/$APP_NAME.app"
BIN="$APP/Contents/MacOS"
RES="$APP/Contents/Resources"
mkdir -p "$BIN" "$RES"

for architecture in arm64 x86_64; do
    scratch="$PKG_DIR/.build/$architecture"
    swift_args=(--package-path "$PKG_DIR" --scratch-path "$scratch" --arch "$architecture" -c release)
    swift build "${swift_args[@]}"
    swift_bin="$(swift build "${swift_args[@]}" --show-bin-path)"
    cp "$swift_bin/$EXECUTABLE" "$STAGE/app-$architecture"
    go_arch="$architecture"
    if [ "$architecture" = x86_64 ]; then go_arch=amd64; fi
    GOOS=darwin GOARCH="$go_arch" CGO_ENABLED=0 go -C "$PKG_DIR/../LiveProbe" \
        build -buildvcs=false -trimpath -o "$STAGE/probe-$architecture" .
done

lipo -create "$STAGE/app-arm64" "$STAGE/app-x86_64" -output "$BIN/$EXECUTABLE"
lipo -create "$STAGE/probe-arm64" "$STAGE/probe-x86_64" -output "$BIN/$PROBE_NAME"
chmod 755 "$BIN/"*
cp "$PKG_DIR/Resources/AppIcon.icns" "$RES/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>CFBundleExecutable</key><string>$EXECUTABLE</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>NSHumanReadableCopyright</key><string>All rights reserved.</string>
</dict></plist>
PLIST

sign_args=(--force --sign "${SPEEDBAR_SIGN_IDENTITY:--}")
if [ "${SPEEDBAR_SIGN_IDENTITY:--}" = - ]; then
    sign_args+=(--timestamp=none)
else
    sign_args+=(--options runtime --timestamp)
fi
codesign "${sign_args[@]}" "$BIN/$PROBE_NAME"
codesign "${sign_args[@]}" "$APP"
codesign --verify --deep --strict "$APP"
for binary in "$BIN/$EXECUTABLE" "$BIN/$PROBE_NAME"; do
    archs="$(lipo -archs "$binary")"
    case "$archs" in
        "arm64 x86_64"|"x86_64 arm64") echo "$(basename "$binary"): $archs" ;;
        *) echo "Expected a universal binary: $binary ($archs)" >&2; exit 1 ;;
    esac
done
plutil -lint "$APP/Contents/Info.plist"

rm -rf "$APP_DIR"
mv "$APP" "$APP_DIR"
echo "$APP_DIR"
