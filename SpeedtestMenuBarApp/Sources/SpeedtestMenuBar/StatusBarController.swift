import Cocoa

/// Owns the NSStatusItem lifecycle. Handles sleep/wake/display transitions that
/// kill menu bar extras by detecting the dead item and re-registering it.
///
final class StatusBarController: NSObject, NSMenuDelegate {

    private let probe: ProbeMonitor
    private let openWindow: () -> Void
    private let pollInterval: TimeInterval = 0.2
    private let healthInterval: TimeInterval = 10.0
    private let minWidth: CGFloat = 76
    private let maxWidth: CGFloat = 92
    /// Minimum spacing between forced re-registrations, so a flapping
    /// WindowServer doesn't make us thrash create/remove in a tight loop.
    private let reRegisterCooldown: TimeInterval = 2.0

    private var statusItem: NSStatusItem?
    private var pollTimer: Timer?
    private var healthTimer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var lastRegisterAt: TimeInterval = 0

    init(probe: ProbeMonitor, openWindow: @escaping () -> Void) {
        self.probe = probe
        self.openWindow = openWindow
        super.init()
    }

    // MARK: - Lifecycle

    func start() {
        registerStatusItem(force: true)
        probe.tick()
        startTimers()
        subscribeToSystemNotifications()
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        healthTimer?.invalidate()
        healthTimer = nil
        unsubscribeSystemNotifications()
        removeStatusItem()
    }

    private func startTimers() {
        pollTimer?.invalidate()
        healthTimer?.invalidate()

        let poll = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        poll.tolerance = pollInterval * 0.25
        pollTimer = poll

        let health = Timer.scheduledTimer(withTimeInterval: healthInterval, repeats: true) { [weak self] _ in
            self?.healthCheck()
        }
        health.tolerance = 2.0
        healthTimer = health
    }

    // MARK: - Liveness

    /// Cheap per-tick check: a status item whose backing window was destroyed
    /// reports window == nil or windowNumber <= 0.
    private var itemLooksAlive: Bool {
        guard let button = statusItem?.button, let window = button.window else { return false }
        return window.windowNumber > 0
    }

    /// Deep check: the item's window exists but is not drawn anywhere.
    /// occlusionState loses .visible when the WindowServer drops the item
    /// (sleep/wake, display changes). It ALSO drops it while a fullscreen app
    /// hides the menu bar, so a single miss is not proof of death — callers
    /// require consecutive misses (strike counting) before re-registering.
    /// (CGWindowList is NOT usable here: on macOS 26 status-item windows are
    /// composited out-of-process and never appear in the owner's window list.)
    private var itemLooksOccluded: Bool {
        guard let window = statusItem?.button?.window else { return true }
        return !window.occlusionState.contains(.visible)
    }

    private var occlusionStrikes = 0
    private let maxOcclusionStrikes = 3

    // MARK: - Status Item

    private func registerStatusItem(force: Bool = false) {
        let now = Date().timeIntervalSince1970
        if !force && now - lastRegisterAt < reRegisterCooldown { return }
        lastRegisterAt = now

        removeStatusItem()

        let item = NSStatusBar.system.statusItem(withLength: minWidth)
        // macOS 26's Control Center manages third-party item visibility PER
        // autosave name ("NSStatusItem VisibleCC <name>"). An unnamed item gets
        // the generic name "Item-0", which the system treats as unknown and
        // suppresses entirely — the window is never created. The stable name
        // also carries the persisted preferred position (974).
        item.autosaveName = "SpeedtestMenuBarStatusItem"
        item.isVisible = true
        // Reinforce the persisted visibility flags in our own defaults domain.
        // A Cmd-drag removal writes these to false and macOS then suppresses
        // the item on every future launch — force them back to visible so a
        // single accidental drag-off can never hide the widget permanently.
        let defaults = UserDefaults.standard
        defaults.set(true, forKey: "NSStatusItem Visible SpeedtestMenuBarStatusItem")
        defaults.set(true, forKey: "NSStatusItem VisibleCC SpeedtestMenuBarStatusItem")

        if let button = item.button {
            button.imagePosition = .noImage
            button.toolTip = "Live Speedtest Mbps"
            button.alignment = .center
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
        }

        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu

        statusItem = item
        render()
    }

    private func removeStatusItem() {
        guard let item = statusItem else { return }
        item.button?.attributedTitle = NSAttributedString(string: "")
        item.button?.image = nil
        item.menu = nil
        NSStatusBar.system.removeStatusItem(item)
        statusItem = nil
    }

    /// Recover a missing/dead status item. Called from health checks and
    /// wake/display notifications.
    func ensureVisible() {
        if itemLooksAlive {
            statusItem?.isVisible = true
            render()
            return
        }

        registerStatusItem()
    }

    private func healthCheck() {
        if pollTimer == nil {
            startTimers()
        }
        if itemLooksOccluded {
            occlusionStrikes += 1
            if occlusionStrikes >= maxOcclusionStrikes {
                fputs("SpeedtestMenuBar: item occluded \(occlusionStrikes)x in a row, re-registering\n", stderr)
                occlusionStrikes = 0
                registerStatusItem(force: true)
                return
            }
        } else {
            occlusionStrikes = 0
        }
        ensureVisible()
    }

    // MARK: - System Notifications

    private func subscribeToSystemNotifications() {
        let workspace = NSWorkspace.shared.notificationCenter

        observers.append(workspace.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.retryEnsureVisible(delays: [1.0, 2.5, 5.0])
            DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) { [weak self] in
                self?.startTimers()
            }
        })

        observers.append(workspace.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.pollTimer?.invalidate()
            self?.pollTimer = nil
            self?.healthTimer?.invalidate()
            self?.healthTimer = nil
        })

        observers.append(workspace.addObserver(
            forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.retryEnsureVisible(delays: [0.5, 2.0, 4.0])
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.5) { [weak self] in
                self?.startTimers()
            }
        })

        // Display topology changes (USB-C dock/display plug, resolution change)
        // also destroy status item windows — same recovery as wake.
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.retryEnsureVisible(delays: [1.0, 3.0])
        })

        // Session unlock: the lock screen can eat status items too.
        observers.append(DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main
        ) { [weak self] _ in
            self?.retryEnsureVisible(delays: [0.5, 2.0])
        })
    }

    private func retryEnsureVisible(delays: [TimeInterval]) {
        ensureVisible()
        for delay in delays {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.ensureVisible()
            }
        }
    }

    private func unsubscribeSystemNotifications() {
        let workspace = NSWorkspace.shared.notificationCenter
        for obs in observers {
            workspace.removeObserver(obs)
            NotificationCenter.default.removeObserver(obs)
            DistributedNotificationCenter.default().removeObserver(obs)
        }
        observers.removeAll()
    }

    // MARK: - Tick

    private func tick() {
        if pollTimer == nil {
            startTimers()
            return
        }
        probe.tick()
        render()

        if !itemLooksAlive {
            ensureVisible()
        }
    }

    // MARK: - Rendering

    private func render() {
        guard let button = statusItem?.button else { return }

        if !probe.enabled {
            statusItem?.length = NSStatusItem.squareLength
            button.attributedTitle = NSAttributedString(string: "")
            button.image = NSImage(systemSymbolName: "speedometer", accessibilityDescription: "SpeedBar paused")
            button.imagePosition = .imageOnly
            button.toolTip = "SpeedBar — paused"
            return
        }
        let title = buildTitle()
        let width = min(max(ceil(title.size().width) + 10, minWidth), maxWidth)
        statusItem?.length = width
        button.image = nil
        button.imagePosition = .noImage
        button.attributedTitle = title
        button.toolTip = buildTooltip()
    }

    private func buildTitle() -> NSAttributedString {
        let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 10.6, weight: .semibold)
        let graphFont = NSFont.monospacedDigitSystemFont(ofSize: 7.8, weight: .bold)
        let spacerFont = NSFont.monospacedDigitSystemFont(ofSize: 8.8, weight: .medium)

        let result = NSMutableAttributedString()

        result.append(NSAttributedString(
            string: Sparkline.glyphs(values: probe.downloadHistory.values, fallback: probe.currentDownload),
            attributes: [.font: graphFont, .foregroundColor: Colors.down]
        ))
        result.append(NSAttributedString(
            string: Format.compact(probe.currentDownload),
            attributes: [.font: valueFont, .foregroundColor: Colors.down]
        ))
        result.append(NSAttributedString(
            string: " ",
            attributes: [.font: spacerFont, .foregroundColor: Colors.dim]
        ))
        result.append(NSAttributedString(
            string: Sparkline.glyphs(values: probe.uploadHistory.values, fallback: probe.currentUpload),
            attributes: [.font: graphFont, .foregroundColor: Colors.up]
        ))
        result.append(NSAttributedString(
            string: Format.compact(probe.currentUpload),
            attributes: [.font: valueFont, .foregroundColor: Colors.up]
        ))

        if probe.stale {
            result.append(NSAttributedString(
                string: " !",
                attributes: [.font: spacerFont, .foregroundColor: Colors.warning]
            ))
        }

        return result
    }

    private func buildTooltip() -> String {
        [
            "Live Speedtest",
            "Max down: \(Format.mbps(probe.peakDownload)) Mbps",
            "Max up: \(Format.mbps(probe.peakUpload)) Mbps",
            "Live down: \(Format.mbps(probe.currentDownload)) Mbps",
            "Live up: \(Format.mbps(probe.currentUpload)) Mbps",
            "Status: \(probe.status)",
            "Updated: \(probe.state.updatedAt > 0 ? probe.state.ageText : "—")"
        ].joined(separator: "\n")
    }

    // MARK: - NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        probe.tick()
        render()
        rebuildMenu(menu)
    }

    private func rebuildMenu(_ menu: NSMenu) {
        menu.removeAllItems()

        func disabled(_ title: String) {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }

        func action(_ title: String, _ sel: Selector) {
            let item = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }

        action("Open SpeedBar", #selector(showWindow))
        menu.addItem(NSMenuItem.separator())
        disabled("Live down: \(Format.mbps(probe.currentDownload)) Mbps")
        disabled("Live up: \(Format.mbps(probe.currentUpload)) Mbps")
        disabled("Max down: \(Format.mbps(probe.peakDownload)) Mbps")
        disabled("Max up: \(Format.mbps(probe.peakUpload)) Mbps")
        disabled("Status: \(probe.status)")
        if probe.state.updatedAt > 0 { disabled("Updated: \(probe.state.ageText)") }

        if let error = probe.state.error {
            disabled("Error: \(error)")
        }

        menu.addItem(NSMenuItem.separator())
        action(probe.enabled ? "Pause Test" : "Start Continuous Test", #selector(toggleTest))
        if probe.enabled { action("Reset Peaks", #selector(resetPeaks)) }
        action("Quit SpeedBar", #selector(quitApp))
    }

    @objc private func showWindow() { openWindow() }
    @objc private func toggleTest() { probe.toggle(); render() }
    @objc private func resetPeaks() { probe.resetPeaks() }
    @objc private func quitApp() { NSApp.terminate(nil) }
}
