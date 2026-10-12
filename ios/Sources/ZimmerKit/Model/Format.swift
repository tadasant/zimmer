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

    /// A model id as the web UI's metadata block shows it: the vendor prefix and date suffix
    /// dropped, so `claude-opus-4-5-20260401` reads "opus 4.5" and `gpt-5.2-codex` stays.
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
}
