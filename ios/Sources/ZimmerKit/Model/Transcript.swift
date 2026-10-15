import Foundation

/// How much of the conversation to show: the web UI's log-level filter, as far as the
/// conversation goes. *Minimal* is the words alone; *Condensed* adds each tool call as one
/// line; *Verbose* shows the tool traffic whole. The web's fourth level, *Show Logs*, is the
/// app's logs screen.
public enum ConversationLevel: String, CaseIterable, Sendable, Identifiable {
    case minimal, condensed, verbose

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .minimal: return "Minimal"
        case .condensed: return "Condensed"
        case .verbose: return "Verbose"
        }
    }

    /// Whether a message is shown at this level.
    public func shows(_ message: ConversationMessage) -> Bool {
        self != .minimal || !message.isToolTraffic
    }

    /// Whether tool traffic is cut to a line at this level.
    public var foldsToolTraffic: Bool { self == .condensed }
}

extension Conversation {
    /// The messages this level shows.
    public func messages(at level: ConversationLevel) -> [ConversationMessage] {
        messages.filter(level.shows)
    }
}

extension ConversationMessage {
    /// Tool traffic as one line, for the Condensed level: the tool and what it was given
    /// ("Using tool: Bash · gh pr checks 1261"), or the result's first line. The server writes
    /// tool traffic as `**Using tool: Bash**` over a fenced block, so the emphasis marks and
    /// the fences are dropped and the first line inside the fence follows the name.
    public var condensedLine: String {
        let lines = content.split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.replacingOccurrences(of: "**", with: "").trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("```") }
        guard let first = lines.first else { return "" }
        if let index = lines.firstIndex(where: { $0.hasPrefix("Using tool:") || $0.hasPrefix("Tool Result") }) {
            let head = lines[index]
            let next = lines.indices.contains(index + 1) ? lines[index + 1] : nil
            return next.map { "\(head) · \($0)" } ?? head
        }
        return first
    }
}
