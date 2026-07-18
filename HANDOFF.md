# 🏃 HANDOFF — Replace ugly D/U Speedtest menubar design with compact graph UI

> Auto-written by **Baton**. Any agent (Claude Code / Codex) reads this to continue where the last one stopped.
> **Do not hand-edit while an agent is mid-task** — call `baton_pass` instead.

| | |
|---|---|
| **Status** | done |
| **Last agent** | codex |
| **Updated** | 2026-07-11T20:30:20.383Z |
| **Baton #** | 2 |

## 🎯 Goal
Keep Timur's macOS Speedtest menu-bar widget polished, compact, visible, and live.

## 🛑 Where it stopped (read this first)
Reworked the menubar design after user said D/U looked ugly. Used Baton MCP, tool discovery, Figma MCP check (not enabled in app), and baseline-ui skill constraints. Final design is text-rendered Unicode mini-sparklines, not image+title, because macOS kept placing the image+title variant under the Clock. Final visible title form is like '▁▅█517 █▅▁42': green 3-bar download mini graph + compact download max, red 3-bar upload mini graph + compact upload max. Position is stable with defaults domain com.timur.speedtestmenubar, key NSStatusItem Preferred Position SpeedtestMenuBarStatusItem=974. Final Accessibility position was x=957, size 94x24, title ▁▅█517 █▅▁42. Live cache was fresh and speedtest-live-probe was running.

## ✅ Done
- Patched /Users/timur_Abi/.local/share/speedtest-menubar/SpeedtestMenuBar.swift to use sharp attributed menubar text like D53.6 U34.6 instead of an image-only status item that was visually blank.
- Rebuilt /Users/timur_Abi/Applications/SpeedtestMenuBar.app/Contents/MacOS/SpeedtestMenuBar with swiftc -O -framework Cocoa and ad-hoc signed the app.
- Set persistent status item position in the real bundle defaults domain: com.timur.speedtestmenubar -> NSStatusItem Preferred Position SpeedtestMenuBarStatusItem=974.
- Verified Go liveprobe tests pass and Swift typecheck passes.
- Verified speedtest-live-probe LaunchAgent is running, SpeedtestMenuBar process is running, latest.json updates every second, and Accessibility reports visible title/position: x about 969, 82x24, title D53.6 U34.6.
- Captured final proof screenshot /tmp/speedtest-menubar-visible-crop.png and full screenshot /tmp/speedtest-menubar-visible-full.png.
- Captured real 8s screen recording /tmp/speedtest-menubar-live-recording.mov and extracted /tmp/speedtest-menubar-recording-start.png plus /tmp/speedtest-menubar-recording-end.png showing the widget visible on the live desktop.
- Patched /Users/timur_Abi/.local/share/speedtest-menubar/SpeedtestMenuBar.swift to replace D/U letters with green/red Unicode mini-sparklines plus compact max speed numbers.
- Added live rolling history arrays for download/upload so the mini graph changes with recent live samples while numbers remain max speed values.
- Added compact menu-bar formatting via formatMenuMbps so the item stays small enough for the free slot before Stats.
- Rebuilt /Users/timur_Abi/Applications/SpeedtestMenuBar.app/Contents/MacOS/SpeedtestMenuBar with swiftc -O -framework Cocoa and ad-hoc signed it.
- Verified Swift typecheck passes, Go liveprobe tests pass, app signature is valid, LaunchAgent plists lint OK, speedtest-live-probe LaunchAgent is running, and SpeedtestMenuBar app process is running.
- Verified live tick samples: updated_at stayed under about 1.1s old, live D/U changed, sparkline title changed, max numbers persisted.
- Captured visual proof: /tmp/speedtest-graph-final2-crop.png, /tmp/speedtest-graph-final2-full.png, /tmp/speedtest-graph-final-recording.mov, /tmp/speedtest-graph-final-recording-end.png.

## ⏭️ Next steps (pick up here)
- If the user dislikes Unicode block style, next best stable variant is a shorter pure text arrow/bar version; avoid image+title hybrid unless willing to fight macOS menu-bar ordering again.
- If the item shifts later, set defaults write com.timur.speedtestmenubar 'NSStatusItem Preferred Position SpeedtestMenuBarStatusItem' -int 974 and relaunch SpeedtestMenuBar.

## ❓ Open questions
_(none)_

## ⚠️ Watch out (gotchas learned)
- Do not use the old /Users/timur_Abi/All Codex Ai Projects/32_macOS_Speedtest_Menu_Bar path; current project folder is /Users/timur_Abi/All Codex Ai Projects/4_macOS_Speedtest_Menu_Bar.
- The app LaunchAgent uses /usr/bin/open and therefore launchctl reports state 'not running' after open exits; this is expected. The real proof is the SpeedtestMenuBar process and visible NSStatusItem.
- The status item showed up blank when button.attributedTitle was set and then button.title was cleared; do not re-add button.title = ''.
- The app bundle ID/defaults domain is lowercase com.timur.speedtestmenubar.
- Figma MCP returned setup instructions because Dev Mode MCP Server is not enabled in the Figma desktop app; do not claim Figma design context was used.
- The image+title hybrid looked promising but was repeatedly placed at x around 1391/1421 under the Clock; final design is text-only for stable placement.
- Do not reintroduce D/U letters unless the user explicitly asks; current request was to replace them with something more creative.
- LaunchAgent com.timur.speedtestmenubar reports not running because it uses /usr/bin/open; actual SpeedtestMenuBar process is the runtime proof.

## 📂 Key files
_(none)_

---
*Pick up the baton:* call `baton_pick_up` (MCP) or just read this file. *Pass it back:* `baton_pass`.
