import Foundation

/// Parsed state from the speedtest-live-probe latest.json.
final class SpeedtestState {
    private(set) var downloadMbps: Double?
    private(set) var uploadMbps: Double?
    private(set) var downloadPeak: Double?
    private(set) var uploadPeak: Double?
    private(set) var sessionDownloadPeak: Double?
    private(set) var sessionUploadPeak: Double?
    private(set) var status: String = "waiting"
    private(set) var error: String?
    private(set) var updatedAt: TimeInterval = 0
    private(set) var raw: [String: Any] = [:]

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
        status = str("status") ?? "waiting"
        error = str("error")
        updatedAt = num("updated_at") ?? updatedAt
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
