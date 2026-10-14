import Foundation

/// A message's text, cut at its fenced code blocks, so the screen can set prose as inline
/// markdown and code in the monospaced face — the web UI renders both
/// (`shared/_enhanced_markdown`); the app showed the raw text, fences and all.
public enum MessageSegment: Hashable, Sendable {
    case prose(String)
    case code(String, language: String?)

    /// A fenced code block, which the screen draws with a Copy button.
    public var isCode: Bool {
        if case .code = self { return true }
        return false
    }

    /// Split on ``` fences. An unclosed fence runs to the end, as a renderer would show it.
    /// Blank prose between blocks is dropped.
    public static func segments(of text: String) -> [MessageSegment] {
        var segments: [MessageSegment] = []
        var prose: [String] = []
        var code: [String] = []
        var language: String?
        var inCode = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if inCode {
                    segments.append(.code(code.joined(separator: "\n"), language: language))
                    code = []
                    inCode = false
                } else {
                    let joined = prose.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                    if !joined.isEmpty { segments.append(.prose(joined)) }
                    prose = []
                    let tag = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                    language = tag.isEmpty ? nil : tag
                    inCode = true
                }
                continue
            }
            if inCode { code.append(String(line)) } else { prose.append(String(line)) }
        }
        if inCode {
            segments.append(.code(code.joined(separator: "\n"), language: language))
        } else {
            let joined = prose.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty { segments.append(.prose(joined)) }
        }
        return segments
    }
}

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
