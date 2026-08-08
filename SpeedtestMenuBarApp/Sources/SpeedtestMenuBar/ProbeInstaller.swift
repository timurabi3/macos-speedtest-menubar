import Cocoa

/// Makes a downloaded .app self-sufficient.
///
/// The menu bar app only *renders* data; the Go probe *produces* it. Someone who
/// downloads the released .app has no probe and no LaunchAgent, so without this the
/// readout would sit at "--" forever and the app would look broken. A packaged .app
/// therefore carries the probe in Contents/MacOS and its LaunchAgent template in
/// Contents/Resources, and installs them on launch.
///
/// `ensureInstalled()` is deliberately non-destructive: it only fills in what is
/// missing. A source install (Scripts/install.sh) stays authoritative, and a probe
/// the user built themselves is never silently replaced. `reinstall()` is the
/// explicit, user-triggered override used after updating the .app.
enum ProbeInstaller {

    static let agentLabel = "com.timur.speedtestliveprobe"

    private static let home = FileManager.default.homeDirectoryForCurrentUser

    static var installedBinaryURL: URL {
        home.appendingPathComponent(".local/bin/speedtest-live-probe")
    }

    private static var agentPlistURL: URL {
        home.appendingPathComponent("Library/LaunchAgents/\(agentLabel).plist")
    }

    /// Present only in a packaged .app — nil for `swift run` during development.
    private static var bundledBinaryURL: URL? {
        let url = Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS/speedtest-live-probe")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    private static var bundledTemplateURL: URL? {
        Bundle.main.url(forResource: "\(agentLabel).plist", withExtension: "template")
    }

    // MARK: - Public

    /// Fill in whatever is missing. Safe to call on every launch.
    @discardableResult
    static func ensureInstalled() -> Bool {
        var changed = false
        if !FileManager.default.isExecutableFile(atPath: installedBinaryURL.path) {
            changed = installBinary(overwrite: false) || changed
        }
        if !FileManager.default.fileExists(atPath: agentPlistURL.path) {
            changed = installAgentPlist() || changed
        }
        // Bootstrap when the job is unknown to launchd — either we just wrote the
        // plist, or a previous session booted it out.
        if changed || run("/bin/launchctl", ["list", agentLabel]) != 0 {
            bootstrapAgent()
        }
        return changed
    }

    /// Force the bundled probe and plist over whatever is installed, then restart
    /// the agent. Used by the "Reinstall Probe" menu item after an .app update.
    static func reinstall() {
        let uid = String(getuid())
        run("/bin/launchctl", ["bootout", "gui/\(uid)/\(agentLabel)"])
        installBinary(overwrite: true)
        installAgentPlist()
        bootstrapAgent()
    }

    // MARK: - Steps

    @discardableResult
    private static func installBinary(overwrite: Bool) -> Bool {
        guard let source = bundledBinaryURL else { return false }
        let fm = FileManager.default
        let destination = installedBinaryURL
        do {
            try fm.createDirectory(at: destination.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            if fm.fileExists(atPath: destination.path) {
                guard overwrite else { return false }
                try fm.removeItem(at: destination)
            }
            try fm.copyItem(at: source, to: destination)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
            fputs("SpeedtestMenuBar: installed probe to \(destination.path)\n", stderr)
            return true
        } catch {
            fputs("SpeedtestMenuBar: probe install failed: \(error)\n", stderr)
            return false
        }
    }

    @discardableResult
    private static func installAgentPlist() -> Bool {
        guard let template = bundledTemplateURL,
              let text = try? String(contentsOf: template, encoding: .utf8) else { return false }
        // The template ships with __HOME__ placeholders so the repo is not tied to
        // one account; substitute the real home at install time.
        let rendered = text.replacingOccurrences(of: "__HOME__", with: home.path)
        do {
            try FileManager.default.createDirectory(
                at: agentPlistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try rendered.write(to: agentPlistURL, atomically: true, encoding: .utf8)
            fputs("SpeedtestMenuBar: wrote \(agentPlistURL.lastPathComponent)\n", stderr)
            return true
        } catch {
            fputs("SpeedtestMenuBar: LaunchAgent write failed: \(error)\n", stderr)
            return false
        }
    }

    private static func bootstrapAgent() {
        guard FileManager.default.fileExists(atPath: agentPlistURL.path) else { return }
        let uid = String(getuid())
        run("/bin/launchctl", ["bootstrap", "gui/\(uid)", agentPlistURL.path])
    }

    // MARK: - Process helper

    /// Synchronous by design: this runs once at launch, each call is milliseconds,
    /// and the status item must not start polling before the probe job exists.
    @discardableResult
    private static func run(_ path: String, _ args: [String]) -> Int32 {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = args
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
            return proc.terminationStatus
        } catch {
            return -1
        }
    }
}
