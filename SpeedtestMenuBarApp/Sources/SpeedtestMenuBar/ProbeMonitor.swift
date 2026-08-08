import Cocoa

/// Monitors the speedtest-live-probe health — reads latest.json, detects staleness,
/// and can restart the probe via launchctl.
final class ProbeMonitor {
    let cacheURL: URL
    let probeBinURL: URL
    private(set) var state = SpeedtestState()
    private(set) var downloadHistory = SpeedHistory()
    private(set) var uploadHistory = SpeedHistory()

    /// These hold the last known good values so the display doesn't flicker to "--" on stale reads.
    private var lastGoodDownload: Double?
    private var lastGoodUpload: Double?
    private var lastGoodPeakDownload: Double?
    private var lastGoodPeakUpload: Double?

    private let home = FileManager.default.homeDirectoryForCurrentUser

    /// Serializes probe restarts.
    ///
    /// `launchctl kickstart -k` SIGTERMs the running probe before restarting it, and
    /// launchd enforces a 10s minimum runtime, so a throttled kickstart blocks ~10s.
    /// Calling this from the 0.2s poll timer killed the probe ~5x/second and piled up
    /// ~50 blocked launchctl processes: the probe never lived long enough to write a
    /// sample, so the staleness that triggered the restart became permanent and the
    /// recovery path was itself the thing preventing recovery. (Diagnosed 2026-08-08:
    /// probe dead since 2026-07-31, widget frozen on that day's numbers.)
    /// One restart in flight at a time, at most one per `kickstartCooldown`.
    private let kickstartQueue = DispatchQueue(label: "com.timur.speedtest3.kickstart")
    private var kickstartInFlightSince: TimeInterval?
    private var lastKickstartAt: TimeInterval = 0
    private let kickstartCooldown: TimeInterval = 30.0
    /// If launchctl ever wedges, don't disable recovery forever.
    private let kickstartStuckTimeout: TimeInterval = 120.0

    init() {
        cacheURL = home.appendingPathComponent("Library/Caches/speedtest-menubar/latest.json")
        probeBinURL = home.appendingPathComponent(".local/bin/speedtest-live-probe")
    }

    private var lastSampleAt: TimeInterval = 0

    func tick() {
        state.reload(from: cacheURL)
        rememberGood()
        // The probe publishes once a second; this polls five times a second.
        // Appending every poll would pad the sparkline with four duplicates per
        // real sample, so the graph would scroll five times too fast and show a
        // fifth of the history it appears to.
        guard state.updatedAt != lastSampleAt else { return }
        lastSampleAt = state.updatedAt
        downloadHistory.append(state.downloadMbps ?? lastGoodDownload)
        uploadHistory.append(state.uploadMbps ?? lastGoodUpload)
    }

    private func rememberGood() {
        if let v = state.downloadMbps, v > 0 { lastGoodDownload = v }
        if let v = state.uploadMbps, v > 0 { lastGoodUpload = v }
        if let v = state.sessionDownloadPeak ?? state.downloadPeak, v > 0 { lastGoodPeakDownload = v }
        if let v = state.sessionUploadPeak ?? state.uploadPeak, v > 0 { lastGoodPeakUpload = v }
    }

    /// Passive utilisation — what the link is carrying right now. Legitimately
    /// 0 on an idle machine, so this must NOT fall back to the last good value
    /// the way a capacity reading would.
    var currentDownload: Double? { state.downloadMbps ?? lastGoodDownload }
    var currentUpload: Double? { state.uploadMbps ?? lastGoodUpload }

    /// Result of the last active capacity test — the "how fast is this line"
    /// number, refreshed on a timer rather than continuously.
    var capacityDownload: Double? { state.capacityDownload }
    var capacityUpload: Double? { state.capacityUpload }
    var peakDownload: Double? { state.sessionDownloadPeak ?? state.downloadPeak ?? lastGoodPeakDownload ?? currentDownload }
    var peakUpload: Double? { state.sessionUploadPeak ?? state.uploadPeak ?? lastGoodPeakUpload ?? currentUpload }

    /// Restart the probe LaunchAgent. Rate-limited — see `kickstartQueue`.
    /// `force` (an explicit user action) skips the cooldown but still refuses to
    /// stack on a restart that is already in flight.
    /// Returns false when the request was suppressed.
    @discardableResult
    func kickstart(force: Bool = false) -> Bool {
        let now = Date().timeIntervalSince1970
        var proceed = false

        kickstartQueue.sync {
            if let since = kickstartInFlightSince, now - since < kickstartStuckTimeout { return }
            if !force, now - lastKickstartAt < kickstartCooldown { return }
            kickstartInFlightSince = now
            lastKickstartAt = now
            proceed = true
        }

        guard proceed else { return false }

        let uid = String(getuid())
        runCommand("/bin/launchctl", ["kickstart", "-k", "gui/\(uid)/com.timur.speedtestliveprobe"]) { [weak self] in
            guard let self else { return }
            self.kickstartQueue.sync { self.kickstartInFlightSince = nil }
        }
        return true
    }

    func runProbe(_ args: [String]) {
        runCommand(probeBinURL.path, args)
    }

    /// `completion` always fires, including on launch failure — callers use it to
    /// clear in-flight state, so swallowing it would wedge them permanently.
    private func runCommand(_ path: String, _ args: [String], completion: (() -> Void)? = nil) {
        DispatchQueue.global(qos: .utility).async {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: path)
            proc.arguments = args
            proc.standardOutput = FileHandle(forWritingAtPath: "/dev/null")
            proc.standardError = FileHandle(forWritingAtPath: "/dev/null")
            do {
                try proc.run()
                proc.waitUntilExit()
            } catch {
                fputs("SpeedtestMenuBar: \(path) failed to launch: \(error)\n", stderr)
            }
            completion?()
        }
    }
}
