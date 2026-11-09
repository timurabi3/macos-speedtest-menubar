import Cocoa
import Combine

/// Runs the bundled probe only while the app is open and measurement is enabled.
final class ProbeMonitor: ObservableObject {
    static let enabledKey = "ContinuousMeasurement"
    @Published private(set) var enabled = UserDefaults.standard.bool(forKey: enabledKey)
    @Published private(set) var status = "Paused"

    private(set) var state = SpeedtestState()
    private(set) var downloadHistory = SpeedHistory()
    private(set) var uploadHistory = SpeedHistory()
    private var child: Process?
    private var lifetimePipe: Pipe?
    private var sessionURL: URL?
    private var nextAttempt = Date.distantPast
    private var stopping = false
    private var launchTime = Date.distantPast

    var currentDownload: Double? { state.downloadMbps }
    var currentUpload: Double? { state.uploadMbps }
    var peakDownload: Double? { state.sessionDownloadPeak }
    var peakUpload: Double? { state.sessionUploadPeak }
    var stale: Bool { enabled && status != "Measuring" }

    func toggle() {
        enabled.toggle()
        UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
        nextAttempt = .distantPast
        if enabled { startIfNeeded() } else { stop() }
    }

    func tick() {
        guard enabled else { return }
        if let sessionURL, !stopping {
            objectWillChange.send()
            state.reload(from: sessionURL.appendingPathComponent("latest.json"))
            if state.status == "running", !state.isStale {
                if status != "Measuring" { status = "Measuring" }
                downloadHistory.append(currentDownload)
                uploadHistory.append(currentUpload)
            } else if Date().timeIntervalSince(launchTime) > 10,
                      Date().timeIntervalSince1970 - state.updatedAt > 10 {
                status = "Restarting probe…"
                nextAttempt = Date().addingTimeInterval(2)
                closeLifetimePipe()
            }
        }
        startIfNeeded()
    }

    func stop() {
        closeLifetimePipe()
        status = "Paused"
        resetReadings()
    }

    func resetPeaks() {
        guard let sessionURL, !stopping, status == "Measuring" else { return }
        do {
            let command = ["command": "reset", "timestamp": Int64(Date().timeIntervalSince1970 * 1_000_000_000)] as [String: Any]
            let data = try JSONSerialization.data(withJSONObject: command)
            try data.write(to: sessionURL.appendingPathComponent("liveprobe-control.json"), options: .atomic)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    private func resetReadings() {
        objectWillChange.send()
        state = SpeedtestState()
        downloadHistory = SpeedHistory()
        uploadHistory = SpeedHistory()
    }

    private func closeLifetimePipe() {
        stopping = child != nil
        try? lifetimePipe?.fileHandleForWriting.close()
        lifetimePipe = nil
    }

    private func startIfNeeded() {
        guard enabled, child == nil, Date() >= nextAttempt else { return }
        let process = Process()
        let pipe = Pipe()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SpeedBar-" + UUID().uuidString, isDirectory: true)
        process.executableURL = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/speedtest-live-probe")
        process.arguments = ["app-run"]
        var environment = ProcessInfo.processInfo.environment
        environment["SPEEDBAR_SESSION_DIR"] = directory.path
        process.environment = environment
        process.standardInput = pipe
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] terminated in
            try? FileManager.default.removeItem(at: directory)
            DispatchQueue.main.async {
                guard let self, self.child === terminated else { return }
                let wasStopping = self.stopping
                self.child = nil
                self.lifetimePipe = nil
                self.sessionURL = nil
                self.stopping = false
                if self.enabled {
                    if !wasStopping {
                        self.status = "Probe exited. Retrying…"
                        self.nextAttempt = Date().addingTimeInterval(5)
                    }
                    self.startIfNeeded()
                }
            }
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            try process.run()
            sessionURL = directory
            lifetimePipe = pipe
            child = process
            launchTime = Date()
            resetReadings()
            status = "Starting probe…"
        } catch {
            try? FileManager.default.removeItem(at: directory)
            status = "Cannot start probe. Retrying…"
            nextAttempt = Date().addingTimeInterval(10)
            NSLog("SpeedBar: %@", error.localizedDescription)
        }
    }
}
