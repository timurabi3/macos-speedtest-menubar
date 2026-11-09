#!/bin/bash
set -euo pipefail

PKG_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$PKG_DIR/version.env"
DEST="$HOME/Applications/$APP_NAME.app"
if [ -e "$DEST" ] || [ -L "$DEST" ] || [ -e "/Applications/$APP_NAME.app" ]; then
    echo "Quit SpeedBar and replace the existing app manually after building with Scripts/package_app.sh." >&2
    exit 1
fi
"$PKG_DIR/Scripts/package_app.sh"
mkdir -p "$HOME/Applications"
ditto "$PKG_DIR/build/$APP_NAME.app" "$DEST"
open "$DEST"
