import Foundation

/// What was typed into a session's composer and not sent, kept across leaving the screen and
/// relaunching, as the web UI keeps a composer's draft in local storage for seven days.
public struct DraftStore {
    /// How long an untouched draft is kept: the web UI's `draft_storage.js` window.
    public static let lifetime: TimeInterval = 7 * 24 * 3600

    private let defaults: UserDefaults
    private let prefix: String

    public init(defaults: UserDefaults = .standard, prefix: String = "draft.") {
        self.defaults = defaults
        self.prefix = prefix
    }

    /// The draft for `session`, or empty when there is none or it has gone stale.
    public func draft(for session: Int, now: Date = Date()) -> String {
        guard let entry = defaults.dictionary(forKey: prefix + String(session)),
              let text = entry["text"] as? String,
              let saved = entry["saved"] as? Double else { return "" }
        guard now.timeIntervalSince1970 - saved < Self.lifetime else {
            defaults.removeObject(forKey: prefix + String(session))
            return ""
        }
        return text
    }

    /// Keep `text` as the draft, or forget it when it is only whitespace.
    public func save(_ text: String, for session: Int, now: Date = Date()) {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            defaults.removeObject(forKey: prefix + String(session))
        } else {
            defaults.set(["text": text, "saved": now.timeIntervalSince1970], forKey: prefix + String(session))
        }
    }
}
