# Live Speedtest Menu Bar Design

## Context

Timur wants a macOS menu-bar widget that behaves like a live Speedtest.net readout, not like the passive Stats network widget. The widget should actively measure maximum download and upload speed continuously while connected to Wi-Fi, show clean live Mbps values in the menu bar, and keep working 24/7 after login.

The current project state is partially implemented:

- `/Users/timur_Abi/.local/share/speedtest-menubar/liveprobe` exists and its Go tests pass.
- `/Users/timur_Abi/.local/bin/speedtest-live-probe` exists.
- `/Users/timur_Abi/Library/LaunchAgents/com.timur.speedtestliveprobe.plist` is missing.
- `/Users/timur_Abi/Library/LaunchAgents/com.timur.speedtestmenubar.plist` exists but the service is not running.
- `/Users/timur_Abi/Library/Caches/speedtest-menubar/latest.json` is stale and marked `paused`.
- The current Swift app still contains old runner wiring, overlay-panel positioning, and `ST!` error rendering.

## Goal

Build a reliable 24/7 active-speed menu-bar app:

- Continuously generate download and upload traffic to measure live top speed.
- Update visible download/upload Mbps roughly 5 times per second.
- Show session max download and max upload in the menu.
- Use a clean, minimal two-row menu-bar layout inspired by Stats and Speedtest.net.
- Survive login, Wi-Fi changes, probe errors, and probe restarts without going blank.

## Non-Goals

- Do not modify the upstream Stats app source.
- Do not depend on Ookla CLI for the live engine.
- Do not use a floating overlay panel to fake menu-bar placement.
- Do not show `ST!` as the normal failure UI.
- Do not optimize for low bandwidth use; active saturation is intentional.

## Architecture

Use two cooperating local processes.

### Go Live Probe

`speedtest-live-probe` is the measurement engine. It runs as a LaunchAgent at login, keeps parallel download and upload workers active, computes rolling one-second Mbps values every 200 ms, and writes state atomically to:

`/Users/timur_Abi/Library/Caches/speedtest-menubar/latest.json`

It owns:

- active download probing
- active upload probing
- rolling Mbps calculation
- current session peaks
- pause, resume, and reset commands
- stale/error/offline state
- atomic JSON writes

### Swift Menu-Bar App

`SpeedtestMenuBar.app` is the UI. It runs as a LaunchAgent at login, owns one real `NSStatusItem`, polls `latest.json` every 200 ms, and renders the current values as a compact image in the menu bar.

It owns:

- menu-bar rendering
- tooltip and menu content
- LaunchAgent control actions
- pause/resume/reset actions
- keeping last good values visible when the probe is stale or restarting

## UI Design

The menu-bar item should be minimal and readable:

- two stacked rows
- blue download row
- pink/red upload row
- monospaced digits
- no background card
- no absolute-position overlay window
- no decorative icons beyond compact arrows or direction markers

Primary menu-bar content:

- live download Mbps
- live upload Mbps

Menu content:

- live download Mbps
- live upload Mbps
- session max download Mbps
- session max upload Mbps
- status: running, paused, stale, offline, or error
- last update age
- actions: pause live, resume live, reset peaks, open cache folder, quit

## Data Contract

The probe writes JSON with these fields:

- `mode`
- `status`
- `phase`
- `pid`
- `download_mbps`
- `upload_mbps`
- `download_peak_mbps`
- `upload_peak_mbps`
- `session_download_peak_mbps`
- `session_upload_peak_mbps`
- `updated_at`
- `started_at`
- `error`

Swift treats `download_mbps` and `upload_mbps` as the live visible values. Session peaks are shown in the menu and used as fallback display values when live data becomes stale.

## Failure Behavior

If the probe errors, restarts, or loses network:

- keep last good download/upload values visible
- mark the state as stale/offline/error in tooltip and menu
- let launchd restart the probe
- avoid blank menu-bar content
- avoid replacing values with `ST!`

If the UI app starts before the probe:

- show a compact waiting state
- attempt to kickstart the probe LaunchAgent
- update as soon as fresh JSON appears

If the probe LaunchAgent is missing or unloaded:

- install/load it during implementation
- expose a menu action that can start it again

## LaunchAgents

Install and verify two user LaunchAgents:

- `com.timur.speedtestliveprobe`
- `com.timur.speedtestmenubar`

`com.timur.speedtestliveprobe` runs the Go probe directly and should restart automatically if it exits unexpectedly.

`com.timur.speedtestmenubar` opens `/Users/timur_Abi/Applications/SpeedtestMenuBar.app` at login.

## Implementation Boundaries

Use these source/install paths:

- Source: `/Users/timur_Abi/.local/share/speedtest-menubar/SpeedtestMenuBar.swift`
- Source: `/Users/timur_Abi/.local/share/speedtest-menubar/liveprobe/main.go`
- Source: `/Users/timur_Abi/.local/share/speedtest-menubar/liveprobe/main_test.go`
- Binary: `/Users/timur_Abi/.local/bin/speedtest-live-probe`
- App: `/Users/timur_Abi/Applications/SpeedtestMenuBar.app`
- LaunchAgent: `/Users/timur_Abi/Library/LaunchAgents/com.timur.speedtestliveprobe.plist`
- LaunchAgent: `/Users/timur_Abi/Library/LaunchAgents/com.timur.speedtestmenubar.plist`
- Runtime state: `/Users/timur_Abi/Library/Caches/speedtest-menubar/latest.json`

Do not edit `/Users/timur_Abi/Desktop/Stats-source` for this feature.

## Verification

The implementation is done only when these checks pass:

- `go test ./...` passes in the liveprobe module.
- `swiftc -typecheck` passes for `SpeedtestMenuBar.swift`.
- `plutil -lint` passes for both LaunchAgent plist files.
- `launchctl print gui/$(id -u)/com.timur.speedtestliveprobe` shows the probe service loaded.
- `launchctl print gui/$(id -u)/com.timur.speedtestmenubar` shows the menu-bar service loaded.
- `latest.json` has a fresh mtime and changing Mbps values.
- `pgrep -fl 'speedtest-live-probe|SpeedtestMenuBar'` shows both processes when live mode is enabled.
- The menu-bar widget is visible as a real status item and does not appear in the wrong screen position.

## Recommended Implementation Path

1. Harden the Go probe only if tests or runtime checks reveal issues.
2. Add the missing live probe LaunchAgent.
3. Rewrite the Swift app wiring around `speedtest-live-probe` and `latest.json`.
4. Remove overlay-panel placement and old Python runner control paths.
5. Rebuild and codesign the app ad hoc.
6. Load/kickstart both LaunchAgents.
7. Verify live changing values and visible menu-bar behavior.
