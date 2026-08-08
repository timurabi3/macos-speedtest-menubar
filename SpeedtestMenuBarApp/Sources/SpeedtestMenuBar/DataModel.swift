import Foundation

/// Parsed state from the speedtest-live-probe latest.json.
final class SpeedtestState {
    private(set) var downloadMbps: Double?
    private(set) var uploadMbps: Double?
    private(set) var downloadPeak: Double?
    private(set) var uploadPeak: Double?
    private(set) var sessionDownloadPeak: Double?
    private(set) var sessionUploadPeak: Double?
    /// Result of the last active capacity test. Distinct from downloadMbps /
    /// uploadMbps, which are passive utilisation — what is actually flowing right
    /// now, normally near zero on an idle machine.
    private(set) var capacityDownload: Double?
    private(set) var capacityUpload: Double?
    private(set) var lastTestAt: TimeInterval = 0
    private(set) var nextTestAt: TimeInterval = 0
    private(set) var status: String = "waiting"
    private(set) var phase: String = ""
    private(set) var error: String?
    private(set) var updatedAt: TimeInterval = 0
    private(set) var raw: [String: Any] = [:]

    var isTesting: Bool { phase == "testing" }

    var isStale: Bool {
        Date().timeIntervalSince1970 - updatedAt > 3.0
    }

    var ageText: String {
        let seconds = Int(max(0, Date().timeIntervalSince1970 - updatedAt))
        if seconds < 60 { return "\(seconds)s ago" }
        return "\(seconds / 60)m ago"
    }

    var displayDownload: Double? {
        sessionDownloadPeak ?? downloadPeak ?? downloadMbps
    }

    var displayUpload: Double? {
        sessionUploadPeak ?? uploadPeak ?? uploadMbps
    }

    func reload(from url: URL) {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any] else {
            return
        }
        raw = dict
        downloadMbps = num("download_mbps")
        uploadMbps = num("upload_mbps")
        downloadPeak = num("download_peak_mbps")
        uploadPeak = num("upload_peak_mbps")
        sessionDownloadPeak = num("session_download_peak_mbps")
        sessionUploadPeak = num("session_upload_peak_mbps")
        capacityDownload = num("capacity_download_mbps")
        capacityUpload = num("capacity_upload_mbps")
        lastTestAt = num("last_test_at") ?? 0
        nextTestAt = num("next_test_at") ?? 0
        status = str("status") ?? "waiting"
        phase = str("phase") ?? ""
        error = str("error")
        updatedAt = num("updated_at") ?? updatedAt
    }

    /// "4m ago" / "never" — for the last capacity test, not the last state write.
    var lastTestText: String {
        guard lastTestAt > 0 else { return "never" }
        return Self.relative(seconds: Int(max(0, Date().timeIntervalSince1970 - lastTestAt)), suffix: "ago")
    }

    var nextTestText: String {
        guard nextTestAt > 0 else { return "soon" }
        let seconds = Int(nextTestAt - Date().timeIntervalSince1970)
        if seconds <= 0 { return "due" }
        return "in " + Self.relative(seconds: seconds, suffix: "")
    }

    private static func relative(seconds: Int, suffix: String) -> String {
        let unit: String
        if seconds < 60 {
            unit = "\(seconds)s"
        } else if seconds < 3600 {
            unit = "\(seconds / 60)m"
        } else {
            unit = "\(seconds / 3600)h"
        }
        return suffix.isEmpty ? unit : "\(unit) \(suffix)"
    }

    private func num(_ key: String) -> Double? {
        guard let value = raw[key], !(value is NSNull) else { return nil }
        if let v = value as? Double { return v }
        if let v = value as? Int { return Double(v) }
        if let v = value as? NSNumber { return v.doubleValue }
        return nil
    }

    private func str(_ key: String) -> String? {
        guard let value = raw[key], !(value is NSNull) else { return nil }
        let text = String(describing: value).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}

/// Rolling history for sparkline rendering.
final class SpeedHistory {
    private let limit: Int
    private(set) var values: [Double] = []

    init(limit: Int = 18) {
        self.limit = limit
    }

    func append(_ value: Double?) {
        guard let value, value >= 0 else { return }
        values.append(value)
        if values.count > limit {
            values.removeFirst(values.count - limit)
        }
    }

    var last: Double? { values.last }
}
