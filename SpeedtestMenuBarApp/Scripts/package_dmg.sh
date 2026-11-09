#!/bin/bash
set -euo pipefail

SCRIPTS="$(cd "$(dirname "$0")" && pwd)"
PKG_DIR="$(dirname "$SCRIPTS")"
source "$PKG_DIR/version.env"
"$SCRIPTS/package_app.sh"
BUILD_DIR="$PKG_DIR/build"
APP="$BUILD_DIR/$APP_NAME.app"
STAGE="$(mktemp -d "$BUILD_DIR/.dmg.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
DMG="$STAGE/$APP_NAME.dmg"

swift "$SCRIPTS/dmg/background.swift" "$STAGE/background.png" 1
swift "$SCRIPTS/dmg/background.swift" "$STAGE/background@2x.png" 2
uvx --from 'dmgbuild==1.6.7' dmgbuild -s "$SCRIPTS/dmg/settings.py" \
    -D "app=$APP" -D "background=$STAGE/background.png" "$APP_NAME" "$DMG"

if [ "${SPEEDBAR_SIGN_IDENTITY:--}" != - ]; then
    codesign --force --sign "$SPEEDBAR_SIGN_IDENTITY" --timestamp "$DMG"
fi
if [ -n "${SPEEDBAR_NOTARY_PROFILE:-}" ]; then
    : "${SPEEDBAR_SIGN_IDENTITY:?A Developer ID Application identity is required for notarization}"
    xcrun notarytool submit "$DMG" --keychain-profile "$SPEEDBAR_NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
    xcrun stapler validate "$DMG"
fi
hdiutil verify "$DMG"
mv -f "$DMG" "$BUILD_DIR/$APP_NAME.dmg"
(
    cd "$BUILD_DIR"
    shasum -a 256 "$APP_NAME.dmg" > "$APP_NAME.dmg.sha256"
)
echo "$BUILD_DIR/$APP_NAME.dmg"
