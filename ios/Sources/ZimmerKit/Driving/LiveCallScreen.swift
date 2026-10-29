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

/// The car's call screen, a voice control template: one state per call state, built once per
/// call and never rebuilt. It goes up when the call starts and down when it ends, and nothing
/// else: no rebuild for a new subject or for Mute, because every template change is one more
/// CarPlay can refuse.
///
/// CarPlay keeps the first five states a voice control template is given and ignores the rest
/// (`CPVoiceControlTemplate.init(voiceControlStates:)`), so the five call states are the five
/// states. A screen built with a muted twin of every state had ten, and CarPlay dropped
/// *speaking* and *working*. Muted, like what the call is doing, is said on the one line that
/// changes in place (`line`).
public enum LiveCallScreen {
    /// What CarPlay keeps.
    public static let maximumStates = 5

    /// Every state the screen is built with, in order: the first is the one it opens on.
    public static let states: [LiveVoiceState] = [.connecting, .listening, .thinking, .speaking, .working]

    /// The state to show for `state`. A call going idle is about to be taken down; until it is,
    /// it reads as connecting rather than naming a state the screen does not have.
    public static func identifier(for state: LiveVoiceState) -> String {
        states.contains(state) ? state.rawValue : LiveVoiceState.connecting.rawValue
    }

    /// A state's title: the call's state, in a word.
    public static func title(for state: LiveVoiceState) -> String {
        state.label
    }

    /// The one line beside the title, a label in the bar that changes in place: an error if the
    /// call has one, else Muted and what the call is doing, else nothing.
    public static func line(error: String?, working: String?, muted: Bool) -> String? {
        if let error { return error }
        let parts = [muted ? "Muted" : nil, working].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
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
