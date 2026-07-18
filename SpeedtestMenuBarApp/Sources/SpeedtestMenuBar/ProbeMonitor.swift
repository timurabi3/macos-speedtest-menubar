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

    init() {
        cacheURL = home.appendingPathComponent("Library/Caches/speedtest-menubar/latest.json")
        probeBinURL = home.appendingPathComponent(".local/bin/speedtest-live-probe")
    }

    func tick() {
        state.reload(from: cacheURL)
        rememberGood()
        downloadHistory.append(state.downloadMbps ?? lastGoodDownload)
        uploadHistory.append(state.uploadMbps ?? lastGoodUpload)
    }

    private func rememberGood() {
        if let v = state.downloadMbps, v > 0 { lastGoodDownload = v }
        if let v = state.uploadMbps, v > 0 { lastGoodUpload = v }
        if let v = state.sessionDownloadPeak ?? state.downloadPeak, v > 0 { lastGoodPeakDownload = v }
        if let v = state.sessionUploadPeak ?? state.uploadPeak, v > 0 { lastGoodPeakUpload = v }
    }

    var currentDownload: Double? { state.downloadMbps ?? lastGoodDownload }
    var currentUpload: Double? { state.uploadMbps ?? lastGoodUpload }
    var peakDownload: Double? { state.sessionDownloadPeak ?? state.downloadPeak ?? lastGoodPeakDownload ?? currentDownload }
    var peakUpload: Double? { state.sessionUploadPeak ?? state.uploadPeak ?? lastGoodPeakUpload ?? currentUpload }

    func kickstart() {
        let uid = String(getuid())
        runCommand("/bin/launchctl", ["kickstart", "-k", "gui/\(uid)/com.timur.speedtestliveprobe"])
    }

    func runProbe(_ args: [String]) {
        DispatchQueue.global(qos: .utility).async { [self] in
            let proc = Process()
            proc.executableURL = probeBinURL
            proc.arguments = args
            proc.standardOutput = FileHandle(forWritingAtPath: "/dev/null")
            proc.standardError = FileHandle(forWritingAtPath: "/dev/null")
            try? proc.run()
            proc.waitUntilExit()
        }
    }

    private func runCommand(_ path: String, _ args: [String]) {
        DispatchQueue.global(qos: .utility).async {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: path)
            proc.arguments = args
            proc.standardOutput = FileHandle(forWritingAtPath: "/dev/null")
            proc.standardError = FileHandle(forWritingAtPath: "/dev/null")
            try? proc.run()
            proc.waitUntilExit()
        }
    }
}
