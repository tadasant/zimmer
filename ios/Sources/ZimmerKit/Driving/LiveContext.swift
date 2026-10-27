import Foundation

/// What a Live Mode call is doing at this moment, in words a driver can glance at: the one
/// function call in flight, named by what it does rather than what it is called.
public enum LiveActivity {
    /// "Starting work…", "Checking on a session…": from a relayed function call's name and
    /// arguments. The Zimmer gateway names its tool in the arguments; a direct tool is named
    /// `<server>__<tool>`.
    public static func describe(name: String, arguments: String) -> String {
        if name == "zimmer" {
            let tool = JSONValue.parse(arguments)?["tool"]?.string ?? ""
            switch tool {
            case "quick_router", "start_session": return "Starting work…"
            case "get_session", "get_session_provenance": return "Checking on a session…"
            case "quick_search_sessions", "get_user_view", "search_root_records": return "Looking through sessions…"
            case "action_session", "respond_to_elicitation", "manage_enqueued_messages": return "Following up…"
            case "send_push_notification": return "Sending it to your phone…"
            case "get_system_health", "get_costs": return "Checking on Zimmer…"
            default: return tool.isEmpty ? "Asking Zimmer…" : "Zimmer: \(tool.replacingOccurrences(of: "_", with: " "))…"
            }
        }
        switch name {
        case "describe_zimmer_tool": return "Asking Zimmer…"
        case "list_mcp_servers", "enable_mcp_server", "disable_mcp_server": return "Changing its tools…"
        case "get_live_settings", "update_live_settings": return "Changing its settings…"
        default:
            if let separator = name.range(of: "__") {
                return "Using \(name[..<separator.lowerBound].replacingOccurrences(of: "-", with: " "))…"
            }
            return "Working on it…"
        }
    }
}

/// What the call screen in the car carries beside the call's state: the session the
/// conversation is about, the work it has in flight, and how many sessions need the driver.
/// The voice control template has one line of text, so this chooses the line.
public struct LiveContext: Hashable, Sendable {
    /// The sessions the conversation has touched, newest first (`GET
    /// /live_conversations/:id/sessions`).
    public var sessions: [SessionSummary]
    /// The function call in flight, described (`LiveActivity`); nil between calls.
    public var activity: String?
    public var needsYou: Int

    public init(sessions: [SessionSummary] = [], activity: String? = nil, needsYou: Int = 0) {
        self.sessions = sessions
        self.activity = activity
        self.needsYou = needsYou
    }

    /// The session the conversation is about right now: the one it touched last.
    public var subject: SessionSummary? { sessions.first }

    /// The template's title, longest variant first, as CarPlay chooses among them. The short
    /// one is always the state's own word, so a narrow screen still says what the call is doing.
    /// The activity is not in it: a title is fixed when the template is built, and the activity
    /// changes with every function call, so the screen carries that in a bar button instead.
    public func titleVariants(for state: LiveVoiceState, muted: Bool = false) -> [String] {
        let short = state.label(muted: muted)
        var long = short
        if let subject {
            let title = DrivingWords.firstSentence(subject.displayTitle, limit: 48)
            long += " · \(title): \(subject.status.label.lowercased())"
        } else if needsYou > 0 {
            long += " · \(needsYou) need you"
        }
        return long == short ? [short] : [long, short]
    }

    /// A different line than `other` drew: the template needs rebuilding. Only the subject
    /// changes the line, so only a new subject rebuilds it.
    public func differs(from other: LiveContext) -> Bool {
        subject?.id != other.subject?.id || subject?.status != other.subject?.status || subject?.title != other.subject?.title
            || (subject == nil && needsYou != other.needsYou)
    }
}

/// The session ids a tool turn's output names, as Zimmer's own tools write them: the
/// `**ID:** 1101` line of a started or read session, a `/sessions/1101` URL, or "session
/// #1101". The server reads its own turns this way for `GET /live_conversations/:id/sessions`;
/// the fixture does the same for its fake thread.
public enum LiveReferencedSessions {
    public static func ids(in text: String) -> [Int] {
        var found: [(position: Int, id: Int)] = []
        for pattern in [#"\*\*ID:\*\*\s*(\d+)"#, #"/sessions/(\d+)"#, #"[Ss]ession\s+#(\d+)"#] {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let range = Range(match.range(at: 1), in: text), let id = Int(text[range]) else { continue }
                found.append((match.range.location, id))
            }
        }
        // In the order the text names them, each once.
        var seen = Set<Int>()
        return found.sorted { $0.position < $1.position }.compactMap { seen.insert($0.id).inserted ? $0.id : nil }
    }
}
