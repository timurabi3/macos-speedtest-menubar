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

    private var lastAutomaticRestart: TimeInterval = 0

    func kickstart() {
        let now = Date().timeIntervalSince1970
        guard now - lastAutomaticRestart >= 30 else { return }
        lastAutomaticRestart = now
        runCommand("/bin/launchctl", ["kickstart", "-k", "gui/\(getuid())/com.timur.speedtestliveprobe"])
    }

    func restartProbe(completion: @escaping (String?) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let domain = "gui/\(getuid())"
            let label = "com.timur.speedtestliveprobe"
            let plist = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(label).plist").path
            func command(_ arguments: [String]) -> (Int32, String) {
                let process = Process()
                let pipe = Pipe()
                process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
                process.arguments = arguments
                process.standardOutput = pipe; process.standardError = pipe
                do {
                    try process.run()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
                } catch { return (-1, error.localizedDescription) }
            }
            let enabled = command(["enable", "\(domain)/\(label)"])
            let result: (Int32, String)
            if enabled.0 != 0 { result = enabled }
            else if command(["print", "\(domain)/\(label)"]).0 == 0 {
                result = command(["kickstart", "-k", "\(domain)/\(label)"])
            } else { result = command(["bootstrap", domain, plist]) }
            DispatchQueue.main.async { completion(result.0 == 0 ? nil : result.1) }
        }
    }

    func runProbe(_ args: [String]) {
        DispatchQueue.global(qos: .utility).async { [self] in
            let proc = Process()
            proc.executableURL = probeBinURL
            proc.arguments = args
            proc.standardOutput = FileHandle(forWritingAtPath: "/dev/null")
            proc.standardError = FileHandle(forWritingAtPath: "/dev/null")
            do { try proc.run(); proc.waitUntilExit() } catch { fputs("Probe command failed: \(error)\n", stderr) }
        }
    }

    private func runCommand(_ path: String, _ args: [String]) {
        DispatchQueue.global(qos: .utility).async {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: path)
            proc.arguments = args
            proc.standardOutput = FileHandle(forWritingAtPath: "/dev/null")
            proc.standardError = FileHandle(forWritingAtPath: "/dev/null")
            do { try proc.run(); proc.waitUntilExit() } catch { fputs("Probe command failed: \(error)\n", stderr) }
        }
    }
}
