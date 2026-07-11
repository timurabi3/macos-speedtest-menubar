# Live Speedtest Menu Bar Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the currently misplaced/invisible Speedtest menu-bar widget with a real macOS status item backed by the active live speed probe.

**Architecture:** Keep the existing Go `speedtest-live-probe` as the active throughput engine and run it through a user LaunchAgent. Replace the Swift app's old runner/overlay wiring with a real `NSStatusItem` that polls `latest.json`, keeps last good values visible, and controls the probe through `launchctl` and the probe CLI.

**Tech Stack:** macOS AppKit Swift compiled with `/usr/bin/swiftc`; Go helper compiled with `/opt/homebrew/bin/go`; user LaunchAgents; JSON state under `/Users/timur_Abi/Library/Caches/speedtest-menubar/latest.json`.

## Global Constraints

- Continuously generate download and upload traffic to measure live top speed.
- Update visible download/upload Mbps roughly 5 times per second.
- Show session max download and max upload in the menu.
- Use a clean, minimal two-row menu-bar layout inspired by Stats and Speedtest.net.
- Survive login, Wi-Fi changes, probe errors, and probe restarts without going blank.
- Do not modify the upstream Stats app source.
- Do not depend on Ookla CLI for the live engine.
- Do not use a floating overlay panel to fake menu-bar placement.
- Do not show `ST!` as the normal failure UI.
- Do not optimize for low bandwidth use; active saturation is intentional.

---

## File Structure

- Modify: `/Users/timur_Abi/.local/share/speedtest-menubar/SpeedtestMenuBar.swift`
  - Replace old Python runner and overlay-panel UI with a single AppKit status-item app.
- Create: `/Users/timur_Abi/Library/LaunchAgents/com.timur.speedtestliveprobe.plist`
  - Load the active Go probe at login and keep it alive.
- Modify: `/Users/timur_Abi/Library/LaunchAgents/com.timur.speedtestmenubar.plist`
  - Keep launching `/Users/timur_Abi/Applications/SpeedtestMenuBar.app`.
- Build output: `/Users/timur_Abi/Applications/SpeedtestMenuBar.app/Contents/MacOS/SpeedtestMenuBar`
  - Compiled Swift app.
- Existing binary: `/Users/timur_Abi/.local/bin/speedtest-live-probe`
  - Go active probe.

---

### Task 1: Install Live Probe LaunchAgent

**Files:**
- Create: `/Users/timur_Abi/Library/LaunchAgents/com.timur.speedtestliveprobe.plist`
- Read: `/Users/timur_Abi/.local/bin/speedtest-live-probe`
- Runtime: `/Users/timur_Abi/Library/Caches/speedtest-menubar/latest.json`

**Interfaces:**
- Consumes: `/Users/timur_Abi/.local/bin/speedtest-live-probe run`
- Produces: user launchd service `gui/$(id -u)/com.timur.speedtestliveprobe`

- [ ] **Step 1: Verify the Go probe still passes tests**

Run:

```bash
cd /Users/timur_Abi/.local/share/speedtest-menubar/liveprobe
/opt/homebrew/bin/go test ./...
```

Expected: `ok speedtest-live-probe`.

- [ ] **Step 2: Create the LaunchAgent plist**

Create `/Users/timur_Abi/Library/LaunchAgents/com.timur.speedtestliveprobe.plist` with:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.timur.speedtestliveprobe</string>
  <key>ProgramArguments</key>
  <array>
    <string>/Users/timur_Abi/.local/bin/speedtest-live-probe</string>
    <string>run</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>/Users/timur_Abi/Library/Caches/speedtest-menubar/liveprobe.out.log</string>
  <key>StandardErrorPath</key>
  <string>/Users/timur_Abi/Library/Caches/speedtest-menubar/liveprobe.err.log</string>
</dict>
</plist>
```

- [ ] **Step 3: Lint and load the LaunchAgent**

Run:

```bash
/usr/bin/plutil -lint /Users/timur_Abi/Library/LaunchAgents/com.timur.speedtestliveprobe.plist
uid="$(id -u)"
/bin/launchctl bootout "gui/$uid" /Users/timur_Abi/Library/LaunchAgents/com.timur.speedtestliveprobe.plist 2>/dev/null || true
/bin/launchctl bootstrap "gui/$uid" /Users/timur_Abi/Library/LaunchAgents/com.timur.speedtestliveprobe.plist
/bin/launchctl kickstart -k "gui/$uid/com.timur.speedtestliveprobe"
```

Expected: `plutil` says `OK`; `launchctl print gui/$uid/com.timur.speedtestliveprobe` can find the service.

- [ ] **Step 4: Verify fresh live JSON**

Run:

```bash
for i in 1 2 3; do
  stat -f '%Sm %N' /Users/timur_Abi/Library/Caches/speedtest-menubar/latest.json
  /usr/bin/plutil -p /Users/timur_Abi/Library/Caches/speedtest-menubar/latest.json
  sleep 1
done
```

Expected: file mtime changes and `download_mbps` or `upload_mbps` changes while the probe is running.

- [ ] **Step 5: Commit service wiring**

Run in `/Users/timur_Abi/All Codex Ai Projects/32_macOS_Speedtest_Menu_Bar`:

```bash
git add docs/superpowers/plans/2026-07-11-live-speedtest-menubar.md
git commit -m "docs: add live speedtest implementation plan"
```

Expected: commit succeeds. Runtime plist lives outside the repo and is not committed here.

---

### Task 2: Replace Swift UI With Real Status Item

**Files:**
- Modify: `/Users/timur_Abi/.local/share/speedtest-menubar/SpeedtestMenuBar.swift`
- Build output: `/Users/timur_Abi/Applications/SpeedtestMenuBar.app/Contents/MacOS/SpeedtestMenuBar`

**Interfaces:**
- Consumes: `/Users/timur_Abi/Library/Caches/speedtest-menubar/latest.json`
- Consumes: `/Users/timur_Abi/.local/bin/speedtest-live-probe reset|pause`
- Consumes: `launchctl kickstart -k gui/<uid>/com.timur.speedtestliveprobe`
- Produces: native `NSStatusItem` with no overlay window

- [ ] **Step 1: Typecheck the current Swift file before editing**

Run:

```bash
/usr/bin/swiftc -typecheck /Users/timur_Abi/.local/share/speedtest-menubar/SpeedtestMenuBar.swift
```

Expected: succeeds or shows only pre-existing errors to fix in this task.

- [ ] **Step 2: Replace the Swift app source**

Replace `/Users/timur_Abi/.local/share/speedtest-menubar/SpeedtestMenuBar.swift` with a single AppKit app that:

```swift
import Cocoa
import Foundation

final class SpeedtestMenuBar: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let home = FileManager.default.homeDirectoryForCurrentUser
    private let statusItemWidth: CGFloat = 78
    private let statusItemHeight: CGFloat = 22
    private let pollInterval: TimeInterval = 0.2
    private var timer: Timer?
    private var state: [String: Any] = [:]
    private var lastGoodDownload: Double?
    private var lastGoodUpload: Double?
    private var lastGoodSessionDownload: Double?
    private var lastGoodSessionUpload: Double?

    private lazy var cacheURL = home.appendingPathComponent("Library/Caches/speedtest-menubar/latest.json")
    private lazy var cacheFolderURL = home.appendingPathComponent("Library/Caches/speedtest-menubar")
    private lazy var probeURL = home.appendingPathComponent(".local/bin/speedtest-live-probe")
    private lazy var probePlistURL = home.appendingPathComponent("Library/LaunchAgents/com.timur.speedtestliveprobe.plist")

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem.autosaveName = NSStatusItem.AutosaveName("SpeedtestMenuBarStatusItem")
        statusItem.length = statusItemWidth
        statusItem.isVisible = true

        if let button = statusItem.button {
            button.imagePosition = .imageOnly
            button.toolTip = "Live Speedtest Mbps"
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
        }

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        kickstartProbe()
        update()
        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.update()
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        update()
        rebuildMenu(menu)
    }

    private func update() {
        state = loadState()
        rememberGoodValues()
        renderStatusItem()
    }

    private func loadState() -> [String: Any] {
        guard let data = try? Data(contentsOf: cacheURL),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any] else {
            return [:]
        }
        return dict
    }

    private func rememberGoodValues() {
        if let value = number("download_mbps"), value > 0 { lastGoodDownload = value }
        if let value = number("upload_mbps"), value > 0 { lastGoodUpload = value }
        if let value = number("session_download_peak_mbps") ?? number("download_peak_mbps"), value > 0 { lastGoodSessionDownload = value }
        if let value = number("session_upload_peak_mbps") ?? number("upload_peak_mbps"), value > 0 { lastGoodSessionUpload = value }
    }

    private func renderStatusItem() {
        statusItem.length = statusItemWidth
        guard let button = statusItem.button else { return }
        let image = statusImage()
        image.isTemplate = false
        button.image = image
        button.title = ""
        button.toolTip = tooltip()
    }

    private func statusImage() -> NSImage {
        let size = NSSize(width: statusItemWidth, height: statusItemHeight)
        let image = NSImage(size: size)
        image.lockFocus()
        defer { image.unlockFocus() }

        NSColor.clear.setFill()
        NSRect(origin: .zero, size: size).fill()

        drawRow(label: "↓", value: displayDownload(), y: 10.9, color: NSColor(calibratedRed: 0.12, green: 0.58, blue: 1.0, alpha: 1.0))
        drawRow(label: "↑", value: displayUpload(), y: 0.8, color: NSColor(calibratedRed: 1.0, green: 0.27, blue: 0.33, alpha: 1.0))

        if isStale {
            let dot = NSBezierPath(ovalIn: NSRect(x: statusItemWidth - 6.5, y: statusItemHeight - 6.5, width: 4, height: 4))
            NSColor.systemYellow.setFill()
            dot.fill()
        }

        return image
    }

    private func drawRow(label: String, value: Double?, y: CGFloat, color: NSColor) {
        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: 2.5, y: y + 2.5, width: 5.5, height: 5.5)).fill()

        let text = "\(label) \(formatMbps(value))"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 9.8, weight: .semibold),
            .foregroundColor: NSColor.white.withAlphaComponent(0.96)
        ]
        text.draw(at: NSPoint(x: 11.5, y: y - 0.9), withAttributes: attributes)
    }

    private func rebuildMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        addDisabled(menu, "Live Speedtest")
        addDisabled(menu, "Download: \(formatMbps(displayDownload())) Mbps")
        addDisabled(menu, "Upload: \(formatMbps(displayUpload())) Mbps")
        addDisabled(menu, "Session max down: \(formatMbps(lastGoodSessionDownload)) Mbps")
        addDisabled(menu, "Session max up: \(formatMbps(lastGoodSessionUpload)) Mbps")
        addDisabled(menu, "Status: \(statusText)")
        addDisabled(menu, "Updated: \(updatedAgeText)")
        if let error = string("error") {
            addDisabled(menu, "Error: \(error)")
        }
        menu.addItem(NSMenuItem.separator())
        menu.addItem(item("Start Live Probe", #selector(startLiveProbe)))
        menu.addItem(item("Pause Live Probe", #selector(pauseLiveProbe)))
        menu.addItem(item("Reset Peaks", #selector(resetPeaks)))
        menu.addItem(item("Open Cache Folder", #selector(openCacheFolder)))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(item("Quit", #selector(quit)))
    }

    private func addDisabled(_ menu: NSMenu, _ title: String) {
        let menuItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        menuItem.isEnabled = false
        menu.addItem(menuItem)
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: "")
        menuItem.target = self
        return menuItem
    }

    @objc private func startLiveProbe() {
        kickstartProbe()
    }

    @objc private func pauseLiveProbe() {
        runProbeCommand(["pause"])
    }

    @objc private func resetPeaks() {
        runProbeCommand(["reset"])
    }

    @objc private func openCacheFolder() {
        NSWorkspace.shared.open(cacheFolderURL)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func kickstartProbe() {
        let uid = String(getuid())
        runCommand("/bin/launchctl", ["kickstart", "-k", "gui/\(uid)/com.timur.speedtestliveprobe"])
    }

    private func runProbeCommand(_ args: [String]) {
        runCommand(probeURL.path, args)
    }

    private func runCommand(_ path: String, _ args: [String]) {
        DispatchQueue.global(qos: .utility).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = args
            process.standardOutput = FileHandle(forWritingAtPath: "/dev/null")
            process.standardError = FileHandle(forWritingAtPath: "/dev/null")
            try? process.run()
            process.waitUntilExit()
        }
    }

    private func displayDownload() -> Double? {
        number("download_mbps") ?? lastGoodDownload ?? number("download_peak_mbps")
    }

    private func displayUpload() -> Double? {
        number("upload_mbps") ?? lastGoodUpload ?? number("upload_peak_mbps")
    }

    private var isStale: Bool {
        guard let updated = number("updated_at") else { return true }
        return Date().timeIntervalSince1970 - updated > 3
    }

    private var statusText: String {
        if isStale { return "stale" }
        return string("status") ?? "waiting"
    }

    private var updatedAgeText: String {
        guard let updated = number("updated_at") else { return "never" }
        let seconds = max(0, Int(Date().timeIntervalSince1970 - updated))
        if seconds < 60 { return "\(seconds)s ago" }
        return "\(seconds / 60)m ago"
    }

    private func tooltip() -> String {
        [
            "Live Speedtest",
            "Download: \(formatMbps(displayDownload())) Mbps",
            "Upload: \(formatMbps(displayUpload())) Mbps",
            "Status: \(statusText)",
            "Updated: \(updatedAgeText)"
        ].joined(separator: "\n")
    }

    private func number(_ key: String) -> Double? {
        guard let value = state[key], !(value is NSNull) else { return nil }
        if let value = value as? Double { return value }
        if let value = value as? Int { return Double(value) }
        if let value = value as? NSNumber { return value.doubleValue }
        return nil
    }

    private func string(_ key: String) -> String? {
        guard let value = state[key], !(value is NSNull) else { return nil }
        let text = String(describing: value).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private func formatMbps(_ value: Double?) -> String {
        guard let value else { return "--" }
        if value >= 100 { return String(format: "%.0f", value) }
        if value >= 10 { return String(format: "%.1f", value) }
        let text = String(format: "%.2f", value)
        return text.replacingOccurrences(of: #"0+$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\.$"#, with: "", options: .regularExpression)
    }
}

let app = NSApplication.shared
let delegate = SpeedtestMenuBar()
app.delegate = delegate
app.run()
```

- [ ] **Step 3: Typecheck the replacement**

Run:

```bash
/usr/bin/swiftc -typecheck /Users/timur_Abi/.local/share/speedtest-menubar/SpeedtestMenuBar.swift
```

Expected: no Swift compiler errors.

---

### Task 3: Build, Install, Reload, and Verify

**Files:**
- Read: `/Users/timur_Abi/.local/share/speedtest-menubar/SpeedtestMenuBar.swift`
- Modify: `/Users/timur_Abi/Applications/SpeedtestMenuBar.app/Contents/MacOS/SpeedtestMenuBar`
- Verify: `/tmp/speedtest-menubar-final.png`

**Interfaces:**
- Consumes: Swift source from Task 2
- Produces: running menu-bar app and visible status item

- [ ] **Step 1: Build and install the Swift app**

Run:

```bash
/usr/bin/swiftc -O /Users/timur_Abi/.local/share/speedtest-menubar/SpeedtestMenuBar.swift -o /tmp/SpeedtestMenuBar.new
/usr/bin/install -m 755 /tmp/SpeedtestMenuBar.new /Users/timur_Abi/Applications/SpeedtestMenuBar.app/Contents/MacOS/SpeedtestMenuBar
/usr/bin/codesign --force --deep --sign - /Users/timur_Abi/Applications/SpeedtestMenuBar.app
```

Expected: build and ad-hoc codesign succeed.

- [ ] **Step 2: Lint LaunchAgents**

Run:

```bash
/usr/bin/plutil -lint /Users/timur_Abi/Library/LaunchAgents/com.timur.speedtestliveprobe.plist
/usr/bin/plutil -lint /Users/timur_Abi/Library/LaunchAgents/com.timur.speedtestmenubar.plist
```

Expected: both files are `OK`.

- [ ] **Step 3: Restart the app and probe**

Run:

```bash
uid="$(id -u)"
/usr/bin/pkill -f '/Users/timur_Abi/Applications/SpeedtestMenuBar.app/Contents/MacOS/SpeedtestMenuBar' 2>/dev/null || true
/bin/launchctl kickstart -k "gui/$uid/com.timur.speedtestliveprobe"
/usr/bin/open -g -a /Users/timur_Abi/Applications/SpeedtestMenuBar.app
sleep 3
```

Expected: both app and probe are running.

- [ ] **Step 4: Verify processes and fresh data**

Run:

```bash
/usr/bin/pgrep -fl 'speedtest-live-probe|SpeedtestMenuBar'
for i in 1 2 3; do
  /usr/bin/plutil -p /Users/timur_Abi/Library/Caches/speedtest-menubar/latest.json
  sleep 1
done
```

Expected: `speedtest-live-probe` and `SpeedtestMenuBar` appear; JSON has a fresh `updated_at` and changing Mbps values.

- [ ] **Step 5: Capture final screenshot**

Run:

```bash
/usr/sbin/screencapture -x /tmp/speedtest-menubar-final.png
```

Expected: the top-right menu bar contains the speedtest item as a normal menu-bar item, not as misplaced blue overlay text near the notch.

- [ ] **Step 6: Commit plan state**

Run in `/Users/timur_Abi/All Codex Ai Projects/32_macOS_Speedtest_Menu_Bar`:

```bash
git add docs/superpowers/plans/2026-07-11-live-speedtest-menubar.md
git commit -m "docs: finalize live speedtest execution plan"
```

Expected: commit succeeds if the plan changed since the previous commit.
