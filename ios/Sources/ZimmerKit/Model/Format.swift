import Foundation

/// The short forms the screens use where space is tight, as Motet's `Format` does.
public enum Format {
    /// How long ago, in the fewest characters that still read: "now", "41m", "3h", "2d",
    /// "5w". The web board's "41 minutes ago" spends the whole line on it; a row has the
    /// line for the title.
    public static func age(_ date: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<60: return "now"
        case ..<3600: return "\(Int(seconds / 60))m"
        case ..<86_400: return "\(Int(seconds / 3600))h"
        case ..<(86_400 * 14): return "\(Int(seconds / 86_400))d"
        default: return "\(Int(seconds / (86_400 * 7)))w"
        }
    }

    /// A model id with its vendor prefix and snapshot date dropped, so
    /// `claude-opus-4-5-20260401` reads "opus-4-5" and `gpt-5.2-codex` stays as it is.
    public static func modelName(_ id: String) -> String {
        var name = id
        for prefix in ["claude-", "anthropic/", "openai/"] where name.hasPrefix(prefix) {
            name = String(name.dropFirst(prefix.count))
        }
        // A trailing -YYYYMMDD is a snapshot date, not part of the name.
        if let range = name.range(of: #"-\d{8}$"#, options: .regularExpression) {
            name.removeSubrange(range)
        }
        return name
    }

    /// A span in the health page's shape (`HealthMonitorService.format_wait`): "45s", "3m",
    /// "2h 5m", "3d 4h".
    public static func duration(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        switch total {
        case ..<60: return "\(total)s"
        case ..<3600: return "\(total / 60)m"
        case ..<86_400:
            let minutes = (total % 3600) / 60
            return minutes == 0 ? "\(total / 3600)h" : "\(total / 3600)h \(minutes)m"
        default:
            let hours = (total % 86_400) / 3600
            return hours == 0 ? "\(total / 86_400)d" : "\(total / 86_400)d \(hours)h"
        }
    }

    /// Bytes as the web page prints them (`number_to_human_size`): "1.2 MB", "840 KB".
    public static func bytes(_ bytes: Int) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(bytes)
        var index = 0
        while value >= 1024, index < units.count - 1 {
            value /= 1024
            index += 1
        }
        let text = index == 0 || value >= 100 ? String(Int(value.rounded())) : String(format: "%.1f", value)
        return "\(text) \(units[index])"
    }

    /// A count as the web page's `number_to_human` prints it: "1.2M", "840K", "12".
    public static func compact(_ count: Int) -> String {
        let value = Double(count)
        func scaled(_ divisor: Double, _ unit: String) -> String {
            let scaled = value / divisor
            let text = scaled >= 100 ? String(Int(scaled.rounded())) : String(format: "%.1f", scaled).replacingOccurrences(of: ".0", with: "")
            return text + unit
        }
        switch count {
        case ..<1000: return String(count)
        case ..<1_000_000: return scaled(1000, "K")
        case ..<1_000_000_000: return scaled(1_000_000, "M")
        default: return scaled(1_000_000_000, "B")
        }
    }
}
