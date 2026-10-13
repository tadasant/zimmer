import Foundation

/// `waiting` on `GET /api/v1/sessions/:id`: the web UI's "why is this session waiting" and
/// recovery banners, as the server words them (`Sessions::WaitingExplanation`).
///
/// The app draws the server's sentences rather than working its own out. Why a session
/// waits is a ranking of several mechanisms — a spot hold, a quota pause, an auth-outage
/// park, a turn queued for a worker — and the server keeps that ranking in one place so the
/// web page and every client say the same thing. A server older than this sends no `waiting`
/// at all, which reads as nothing to say.
public struct WaitingExplanation: Hashable, Sendable, Decodable {
    /// One mechanism that could be holding the session, in the server's rank order.
    public struct Reason: Hashable, Sendable, Decodable {
        /// `spot_hold`, `spot_pause`, `auth_outage_park` or `turn_queued`.
        public var mechanism: String
        public var label: String
        public var at: Date?
        /// The one the session is waiting on now; exactly one is.
        public var current: Bool
        /// An overdue hold that nothing will re-arm.
        public var demoted: Bool

        public init(mechanism: String, label: String, at: Date? = nil, current: Bool = false, demoted: Bool = false) {
            self.mechanism = mechanism
            self.label = label
            self.at = at
            self.current = current
            self.demoted = demoted
        }

        enum CodingKeys: String, CodingKey { case mechanism, label, at, current, demoted }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            mechanism = try container.decode(String.self, forKey: .mechanism)
            label = (try? container.decodeIfPresent(String.self, forKey: .label)) ?? mechanism
            at = (try? container.decodeIfPresent(String.self, forKey: .at)).flatMap(ZimmerJSON.parseDate)
            current = (try? container.decodeIfPresent(Bool.self, forKey: .current)) ?? false
            demoted = (try? container.decodeIfPresent(Bool.self, forKey: .demoted)) ?? false
        }
    }

    public var reasons: [Reason]
    /// In the order the web page stacks them.
    public var banners: [WaitingBanner]

    public init(reasons: [Reason] = [], banners: [WaitingBanner] = []) {
        self.reasons = reasons
        self.banners = banners
    }

    /// Nothing to say: what an older server's answer reads as.
    public static let empty = WaitingExplanation()

    enum CodingKeys: String, CodingKey { case reasons, banners }

    /// A banner or reason that does not read is dropped, not the whole explanation.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        reasons = (try? container.decodeIfPresent([Lenient<Reason>].self, forKey: .reasons))?.compactMap(\.value) ?? []
        banners = (try? container.decodeIfPresent([Lenient<WaitingBanner>].self, forKey: .banners))?.compactMap(\.value) ?? []
    }
}

/// One of the session page's banners: a headline, paragraphs of plain text, and at most one
/// control. A key the app does not know is still shown — the words are the server's, so a
/// banner added on the server reaches the phone without a release.
public struct WaitingBanner: Hashable, Sendable, Decodable, Identifiable {
    /// The banner's colour on the web: amber and orange are `warning`, sky and blue `info`.
    public enum Tone: String, Hashable, Sendable {
        case info, warning
    }

    /// The banner's one control, naming the call it makes. A kind the app does not know is no
    /// control at all: the banner still says what it says, and the web page has the button.
    public enum Action: Hashable, Sendable {
        /// `PATCH /api/v1/sessions/:id` with `scheduling_class` — "Make this session priority".
        case updateSchedulingClass(label: String, priority: Bool)
        /// `POST /api/v1/sessions/:id/force_start`, after a confirmation that says whose turn
        /// is stopped (`confirm`, the web page's own confirm text).
        case forceStart(label: String, expectedVictimID: Int, confirm: String)
        /// `POST /api/v1/sessions/:id/follow_up` with `prompt` — the MCP reconnect message.
        case followUp(label: String, prompt: String)
        /// The web page at `path`, for a flow only a browser can finish (MCP OAuth).
        case openInBrowser(label: String, path: String)

        public var label: String {
            switch self {
            case let .updateSchedulingClass(label, _), let .forceStart(label, _, _),
                 let .followUp(label, _), let .openInBrowser(label, _):
                return label
            }
        }
    }

    /// `spot_hold`, `queued_turn`, `mcp_oauth_reconnect`, … — one banner per key.
    public var key: String
    public var tone: Tone
    public var headline: String
    /// Paragraphs, in order.
    public var body: [String]
    public var action: Action?

    public var id: String { key }

    public init(key: String, tone: Tone, headline: String, body: [String] = [], action: Action? = nil) {
        self.key = key
        self.tone = tone
        self.headline = headline
        self.body = body
        self.action = action
    }

    enum CodingKeys: String, CodingKey { case key, tone, headline, body, action }

    enum ActionKeys: String, CodingKey {
        case kind, label, prompt, path, confirm
        case schedulingClass = "scheduling_class"
        case expectedVictimID = "expected_victim_id"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        key = try container.decode(String.self, forKey: .key)
        headline = try container.decode(String.self, forKey: .headline)
        // An unknown tone is drawn as a warning: a banner is there because something is off.
        tone = (try? container.decodeIfPresent(String.self, forKey: .tone)).flatMap(Tone.init(rawValue:)) ?? .warning
        body = (try? container.decodeIfPresent([String?].self, forKey: .body))?
            .compactMap { $0 }.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? []
        let actionContainer = try? container.nestedContainer(keyedBy: ActionKeys.self, forKey: .action)
        action = actionContainer.flatMap(Self.action(from:))
    }

    /// The action, when it is one the app can carry out with what the server sent; nil
    /// otherwise, never a control that would make a call with a guessed argument.
    private static func action(from container: KeyedDecodingContainer<ActionKeys>) -> Action? {
        guard let kind = try? container.decodeIfPresent(String.self, forKey: .kind) else { return nil }
        func string(_ key: ActionKeys) -> String? {
            guard let value = try? container.decodeIfPresent(String.self, forKey: key), !value.isEmpty else { return nil }
            return value
        }
        switch kind {
        case "update_scheduling_class":
            guard let scheduling = string(.schedulingClass), ["priority", "spot"].contains(scheduling) else { return nil }
            return .updateSchedulingClass(label: string(.label) ?? (scheduling == "priority" ? "Make this session priority" : "Move to spot"),
                                          priority: scheduling == "priority")
        case "force_start":
            // Without the victim the person is shown, Force could stop a turn nobody confirmed.
            guard let victim = try? container.decodeIfPresent(Int.self, forKey: .expectedVictimID) else { return nil }
            return .forceStart(label: string(.label) ?? "Force", expectedVictimID: victim,
                               confirm: string(.confirm) ?? "Stop session #\(victim)'s turn to free a worker thread for this session?")
        case "follow_up":
            guard let prompt = string(.prompt) else { return nil }
            return .followUp(label: string(.label) ?? "Send", prompt: prompt)
        case "open_in_browser":
            // A path on the web app, never somewhere else.
            guard let path = string(.path), path.hasPrefix("/"), !path.hasPrefix("//") else { return nil }
            return .openInBrowser(label: string(.label) ?? "Open in the browser", path: path)
        default:
            return nil
        }
    }
}

/// A list entry that does not read decodes as nil rather than failing the list.
struct Lenient<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: Decoder) throws {
        value = try? Value(from: decoder)
    }
}

/// What Force did: the session as it now is, and the server's sentence about whose turn was
/// stopped and where this one stands.
public struct ForceStartResult: Hashable, Sendable {
    public var session: SessionSummary
    public var message: String

    public init(session: SessionSummary, message: String) {
        self.session = session
        self.message = message
    }
}

struct ForceStartResponse: Decodable {
    let session: SessionSummary
    let message: String?
}
