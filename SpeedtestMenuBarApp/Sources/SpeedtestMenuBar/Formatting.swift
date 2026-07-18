import Cocoa

/// Formatting helpers for speed values.
enum Format {
    /// Full precision for menus/tooltips.
    static func mbps(_ value: Double?) -> String {
        guard let value else { return "--" }
        if value >= 100 { return String(format: "%.0f", value) }
        if value >= 10 { return String(format: "%.1f", value) }
        let text = String(format: "%.2f", value)
        return text.replacingOccurrences(of: "0+$", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\.$", with: "", options: .regularExpression)
    }

    /// Compact for menu bar display.
    static func compact(_ value: Double?) -> String {
        guard let value else { return "--" }
        if value >= 1000 { return String(format: "%.1fG", value / 1000) }
        if value >= 100 { return String(format: "%.0f", value) }
        if value >= 10 { return String(format: "%.0f", value) }
        let text = String(format: "%.1f", value)
        return text.replacingOccurrences(of: "0+$", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\.$", with: "", options: .regularExpression)
    }
}

/// Unicode block sparkline rendering.
enum Sparkline {
    private static let blocks = ["▁", "▂", "▃", "▄", "▅", "▆", "▇", "█"]

    static func glyphs(values: [Double], fallback: Double?) -> String {
        var samples = Array(values.suffix(3))
        if samples.count < 3, let fallback {
            samples = [fallback * 0.70, fallback * 0.86, fallback]
        }
        guard samples.count >= 3, let minVal = samples.min(), let maxVal = samples.max() else {
            return "▁▁▁"
        }
        let range = max(maxVal - minVal, max(maxVal, 1) * 0.08)
        return samples.map { sample in
            let normalized = max(0, min(1, (sample - minVal) / range))
            let index = Int(round(normalized * Double(blocks.count - 1)))
            return blocks[index]
        }.joined()
    }
}

/// Color constants.
enum Colors {
    static let down = NSColor(calibratedRed: 0.18, green: 0.93, blue: 0.34, alpha: 1.0)
    static let up = NSColor(calibratedRed: 1.0, green: 0.27, blue: 0.33, alpha: 1.0)
    static let dim = NSColor.labelColor.withAlphaComponent(0.38)
    static let warning = NSColor.systemYellow
}
