import Cocoa
import CoreGraphics

/// Owns the NSStatusItem lifecycle. Handles sleep/wake/display transitions that
/// kill menu bar extras by detecting the dead item and re-registering it.
///
/// KEY DESIGN 1: No autosaveName. SystemUIServer's autosaveName caching returns
/// stale/dead item references after sleep/wake, making in-process re-registration
/// silently fail. Without autosaveName, every registerStatusItem() call gets a
/// genuinely fresh item from the system.
///
/// KEY DESIGN 2: A status item can die while `statusItem` and `button` are both
/// still non-nil — the backing WindowServer window is destroyed (sleep/wake,
/// display plug/unplug, WindowServer pressure) and the process never gets an
/// error. The ONLY reliable liveness signals are the button window's
/// windowNumber and the WindowServer's own window list, so both are checked.
///
/// KEY DESIGN 3: Watchdog exits use exit(1). The LaunchAgent keeps
/// KeepAlive = {SuccessfulExit=false, Crashed=true}, so exit(1) → launchd
/// restarts a fresh process, while a user Quit (exit 0) stays quit.
/// (v2 used exit(0) here — launchd never restarted it: the "gone forever" bug.)
///
/// KEY DESIGN 4: Probe restarts are rate-limited inside ProbeMonitor, never here.
/// `launchctl kickstart -k` KILLS the running probe first, so calling it from the
/// 0.2s poll timer (as v3.0.0 did) SIGTERMed the probe ~5x/second — it could never
/// live long enough to write a sample, the state stayed stale forever, and ~50
/// throttle-blocked launchctl processes piled up. The staleness remedy caused the
/// staleness. Any new restart trigger must go through ProbeMonitor.kickstart().
final class StatusBarController: NSObject, NSMenuDelegate {

    private let probe: ProbeMonitor
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

    /// Counts consecutive failed recoveries to trigger the launchd-restart exit.
    private var failedRecreations = 0
    private let maxFailedRecreations = 6

    init(probe: ProbeMonitor) {
        self.probe = probe
        super.init()
    }

    // MARK: - Lifecycle

    func start() {
        registerStatusItem(force: true)
        probe.kickstart()
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

    // MARK: - Status Item (NO autosaveName — SystemUIServer caching is the enemy)

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
            failedRecreations = 0
            statusItem?.isVisible = true
            render()
            return
        }

        failedRecreations += 1
        if failedRecreations > maxFailedRecreations {
            // Stuck beyond in-process repair — exit NON-zero so launchd
            // (KeepAlive.Crashed=true) restarts a clean process.
            fputs("SpeedtestMenuBar: ensureVisible failed \(failedRecreations)x, exit(1) for launchd restart\n", stderr)
            exit(1)
        }
        fputs("SpeedtestMenuBar: status item dead (attempt \(failedRecreations)), re-registering\n", stderr)
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
            self?.probe.kickstart()
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

        // Reached at 5 Hz while stale; ProbeMonitor.kickstart() rate-limits it to one
        // restart per 30s. Never call launchctl directly from here — `kickstart -k`
        // SIGTERMs the probe, so an ungated call from this timer makes the staleness
        // it reacts to permanent (see KEY DESIGN 4).
        if probe.state.isStale, Date().timeIntervalSince1970 - probe.state.updatedAt > 10 {
            probe.kickstart()
        }

        if !itemLooksAlive {
            ensureVisible()
        }
    }

    // MARK: - Rendering

    private func render() {
        guard let button = statusItem?.button else { return }

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
            string: Sparkline.glyphs(values: probe.downloadHistory.values, fallback: probe.headlineDownload),
            attributes: [.font: graphFont, .foregroundColor: Colors.down]
        ))
        result.append(NSAttributedString(
            string: Format.compact(probe.headlineDownload),
            attributes: [.font: valueFont, .foregroundColor: Colors.down]
        ))
        result.append(NSAttributedString(
            string: " ",
            attributes: [.font: spacerFont, .foregroundColor: Colors.dim]
        ))
        result.append(NSAttributedString(
            string: Sparkline.glyphs(values: probe.uploadHistory.values, fallback: probe.headlineUpload),
            attributes: [.font: graphFont, .foregroundColor: Colors.up]
        ))
        result.append(NSAttributedString(
            string: Format.compact(probe.headlineUpload),
            attributes: [.font: valueFont, .foregroundColor: Colors.up]
        ))

        if probe.state.isStale {
            result.append(NSAttributedString(
                string: " !",
                attributes: [.font: spacerFont, .foregroundColor: Colors.warning]
            ))
        }

        return result
    }

    private func buildTooltip() -> String {
        [
            "SpeedBar",
            "In use: ↓ \(Format.mbps(probe.currentDownload)) ↑ \(Format.mbps(probe.currentUpload)) Mbps",
            "Line speed: ↓ \(Format.mbps(probe.capacityDownload)) ↑ \(Format.mbps(probe.capacityUpload)) Mbps",
            "Tested \(probe.state.lastTestText), next \(probe.state.nextTestText)",
            "Status: \(probe.state.isStale ? "stale" : probe.state.status)",
            "Updated: \(probe.state.ageText)"
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

        disabled("SpeedBar")
        // Two different quantities, and conflating them is the easiest way to
        // misread this menu: "in use" is measured passively and is 0 when you are
        // not doing anything; "line speed" is what the last active test achieved.
        disabled("In use   ↓ \(Format.mbps(probe.currentDownload))  ↑ \(Format.mbps(probe.currentUpload)) Mbps")
        disabled("Line speed  ↓ \(Format.mbps(probe.capacityDownload))  ↑ \(Format.mbps(probe.capacityUpload)) Mbps")
        disabled("Best seen  ↓ \(Format.mbps(probe.peakDownload))  ↑ \(Format.mbps(probe.peakUpload)) Mbps")

        menu.addItem(NSMenuItem.separator())
        if probe.state.isTesting {
            disabled("Testing line speed…")
        } else {
            disabled("Tested \(probe.state.lastTestText), next \(probe.state.nextTestText)")
        }
        disabled("Status: \(probe.state.isStale ? "stale" : probe.state.status)")

        if let error = probe.state.error {
            disabled("Error: \(error)")
        }

        menu.addItem(NSMenuItem.separator())
        action("Run Speed Test Now", #selector(runSpeedTest))
        action("Kickstart Probe", #selector(kickstartProbe))
        action("Reset Peaks", #selector(resetPeaks))
        action("Reinstall Probe", #selector(reinstallProbe))
        action("Quit", #selector(quitApp))
    }

    @objc private func runSpeedTest() { probe.runProbe(["test"]) }

    @objc private func kickstartProbe() { probe.kickstart(force: true) }

    /// Force the .app's bundled probe over the installed one. Needed after
    /// replacing the .app with a newer release, since the automatic installer
    /// deliberately never overwrites an existing probe.
    @objc private func reinstallProbe() {
        DispatchQueue.global(qos: .userInitiated).async { ProbeInstaller.reinstall() }
    }
    @objc private func resetPeaks() { probe.runProbe(["reset"]) }
    @objc private func quitApp() { NSApp.terminate(nil) }
}
