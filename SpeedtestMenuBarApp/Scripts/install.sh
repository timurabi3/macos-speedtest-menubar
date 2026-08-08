#!/bin/bash
set -euo pipefail

# Build, install to ~/Applications, (re)load the LaunchAgent, verify liveness.

PKG_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$PKG_DIR/version.env"

"$PKG_DIR/Scripts/package_app.sh"

DEST="$HOME/Applications/$APP_NAME.app"
AGENT_LABEL="com.timur.speedtestmenubar"
AGENT_PLIST="$HOME/Library/LaunchAgents/$AGENT_LABEL.plist"
UID_NUM="$(id -u)"

echo "→ Installing to $DEST"
launchctl bootout "gui/$UID_NUM/$AGENT_LABEL" 2>/dev/null || true
pkill -x "$APP_NAME" 2>/dev/null || true
sleep 1
rm -rf "$DEST"
cp -R "$PKG_DIR/build/$APP_NAME.app" "$DEST"

echo "→ Installing LaunchAgent"
sed "s|__HOME__|$HOME|g" "$PKG_DIR/LaunchAgents/$AGENT_LABEL.plist.template" > "$AGENT_PLIST"
plutil -lint "$AGENT_PLIST"
launchctl bootstrap "gui/$UID_NUM" "$AGENT_PLIST"

sleep 3
echo "→ Verifying"
pgrep -x "$APP_NAME" >/dev/null && echo "  process: RUNNING" || { echo "  process: NOT RUNNING"; exit 1; }
launchctl print "gui/$UID_NUM/$AGENT_LABEL" | grep -E "state = " | head -1

echo "═══ Installed. Check the menu bar. ═══"
