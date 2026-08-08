#!/bin/bash
set -euo pipefail

# Build the Go probe, install it to ~/.local/bin, (re)load its LaunchAgent, verify.

PKG_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BIN_NAME="speedtest-live-probe"
DEST_BIN="$HOME/.local/bin/$BIN_NAME"
AGENT_LABEL="com.timur.speedtestliveprobe"
AGENT_PLIST="$HOME/Library/LaunchAgents/$AGENT_LABEL.plist"
UID_NUM="$(id -u)"

echo "═══ Building $BIN_NAME ═══"
# -buildvcs=false: this tree is often checked out as a git worktree, where Go's
# VCS stamping fails with "error obtaining VCS status".
go -C "$PKG_DIR" build -buildvcs=false -trimpath -o "$PKG_DIR/build/$BIN_NAME" .

echo "→ Installing binary to $DEST_BIN"
mkdir -p "$HOME/.local/bin" "$HOME/Library/Caches/speedtest-menubar"
# Stop the running probe before replacing the binary it is executing.
launchctl bootout "gui/$UID_NUM/$AGENT_LABEL" 2>/dev/null || true
sleep 1
install -m 0755 "$PKG_DIR/build/$BIN_NAME" "$DEST_BIN"

echo "→ Installing LaunchAgent"
sed "s|__HOME__|$HOME|g" "$PKG_DIR/LaunchAgents/$AGENT_LABEL.plist.template" > "$AGENT_PLIST"
plutil -lint "$AGENT_PLIST"
launchctl bootstrap "gui/$UID_NUM" "$AGENT_PLIST"

sleep 3
echo "→ Verifying"
pgrep -f "$DEST_BIN run" >/dev/null && echo "  probe: RUNNING" || { echo "  probe: NOT RUNNING"; exit 1; }

echo "═══ Probe installed. ═══"
