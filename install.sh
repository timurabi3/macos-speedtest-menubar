#!/bin/bash
set -euo pipefail

# Install the whole stack: Go probe first (it produces the data), then the Swift
# menu bar app (it consumes it).

ROOT="$(cd "$(dirname "$0")" && pwd)"

"$ROOT/LiveProbe/Scripts/install.sh"
"$ROOT/SpeedtestMenuBarApp/Scripts/install.sh"

echo
echo "═══ Full stack installed ═══"
echo "  probe : $HOME/.local/bin/speedtest-live-probe"
echo "  app   : $HOME/Applications/SpeedtestMenuBar.app"
echo "  state : $HOME/Library/Caches/speedtest-menubar/latest.json"
