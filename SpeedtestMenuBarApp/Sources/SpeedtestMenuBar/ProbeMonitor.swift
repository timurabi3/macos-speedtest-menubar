import Cocoa
import Darwin

/// Passive counters from active physical Ethernet/Wi-Fi interfaces. No test traffic is generated.
final class ProbeMonitor {
    private(set) var downloadHistory = SpeedHistory()
    private(set) var uploadHistory = SpeedHistory()
    private(set) var currentDownload: Double?
    private(set) var currentUpload: Double?
    private(set) var peakDownload: Double?
    private(set) var peakUpload: Double?
    private(set) var interfaces: [String] = []
    private var previous: [String: (UInt32, UInt32)] = [:]
    private var lastSample: TimeInterval = 0

    func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastSample >= 1 else { return }
        var address: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&address) == 0, let first = address else {
            currentDownload = nil; currentUpload = nil; previous = [:]; lastSample = now
            return
        }
        defer { freeifaddrs(first) }
        var counters: [String: (UInt32, UInt32)] = [:]
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            let info = entry.pointee
            let name = String(cString: info.ifa_name)
            if name.hasPrefix("en"), let addr = info.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK),
               (info.ifa_flags & UInt32(IFF_UP | IFF_RUNNING)) == UInt32(IFF_UP | IFF_RUNNING),
               let data = info.ifa_data?.assumingMemoryBound(to: if_data.self) {
                counters[name] = (data.pointee.ifi_ibytes, data.pointee.ifi_obytes)
            }
            cursor = info.ifa_next
        }
        interfaces = counters.keys.sorted()
        let elapsed = now - lastSample
        var down: UInt64 = 0, up: UInt64 = 0
        var matched = false
        for (name, value) in counters {
            if let old = previous[name] {
                down += UInt64(value.0 &- old.0)
                up += UInt64(value.1 &- old.1)
                matched = true
            }
        }
        if matched && elapsed > 0 && elapsed < 10 {
            currentDownload = Double(down) * 8 / elapsed / 1_000_000
            currentUpload = Double(up) * 8 / elapsed / 1_000_000
            peakDownload = max(peakDownload ?? 0, currentDownload ?? 0)
            peakUpload = max(peakUpload ?? 0, currentUpload ?? 0)
            downloadHistory.append(currentDownload); uploadHistory.append(currentUpload)
        } else { currentDownload = nil; currentUpload = nil }
        previous = counters; lastSample = now
    }

    func resetPeaks() { peakDownload = currentDownload; peakUpload = currentUpload }

    func restartProbe(completion: @escaping (String?) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            process.arguments = ["kickstart", "-k", "gui/\(getuid())/com.timur.speedtestliveprobe"]
            process.standardError = pipe
            do {
                try process.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let message = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                DispatchQueue.main.async {
                    completion(process.terminationStatus == 0 ? nil : "The continuous probe is disabled or not loaded. It was stopped because it saturated the connection.\n\n\(message)")
                }
            } catch {
                DispatchQueue.main.async { completion(error.localizedDescription) }
            }
        }
    }
}
