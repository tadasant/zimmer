import Foundation

/// Zimmer's cached "where things stand" blurb for a session (`status_summary` on
/// `GET /api/v1/sessions/:id`). Written when a session comes to rest; may be stale.
public struct StatusSummary: Hashable, Sendable, Codable {
    public var summary: String?
    public var generatedAt: Date?
    public var generating: Bool?
    /// Why the last generation failed, when it did.
    public var error: String?
    /// Messages that landed after the summary was written: the web UI's "3 messages since
    /// summary generated". Nil when there is no summary.
    public var messagesSinceGenerated: Int?

    enum CodingKeys: String, CodingKey {
        case summary, generating, error
        case generatedAt = "generated_at"
        case messagesSinceGenerated = "messages_since_generated"
    }

    public init(summary: String?, generatedAt: Date? = nil, generating: Bool? = nil, error: String? = nil, messagesSinceGenerated: Int? = nil) {
        self.summary = summary
        self.generatedAt = generatedAt
        self.generating = generating
        self.error = error
        self.messagesSinceGenerated = messagesSinceGenerated
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        summary = try? container.decodeIfPresent(String.self, forKey: .summary)
        generatedAt = try? container.decodeIfPresent(Date.self, forKey: .generatedAt)
        generating = try? container.decodeIfPresent(Bool.self, forKey: .generating)
        error = try? container.decodeIfPresent(String.self, forKey: .error)
        messagesSinceGenerated = try? container.decodeIfPresent(Int.self, forKey: .messagesSinceGenerated)
    }

    /// Whether the summary still describes the session: no message since it was written.
    public var isCurrent: Bool { (messagesSinceGenerated ?? 0) == 0 }
}

/// One session, as the detail screen shows it.
public struct SessionDetail: Hashable, Sendable {
    public var session: SessionSummary
    public var statusSummary: StatusSummary?
    /// The lineage graph the session belongs to, origin first.
    public var hierarchy: SessionHierarchy?
    /// The web UI's Goal check panel: what Zimmer can read back about the goal.
    public var goalCheck: GoalCheck?
    /// The web UI's Human messages panel: what people said to this session and its family.
    public var humanMessages: [HumanMessage]
    /// The channels this session's family came in through that Zimmer cannot capture: with
    /// any, the counts above are a floor, and an empty list is not "no human spoke".
    public var captureGaps: [HumanMessageCaptureGap]
    /// Why it is waiting, and the recovery banners: what the web page's header says above
    /// everything else. Empty when there is nothing to say.
    public var waiting: WaitingExplanation

    public init(session: SessionSummary, statusSummary: StatusSummary? = nil, hierarchy: SessionHierarchy? = nil,
                goalCheck: GoalCheck? = nil, humanMessages: [HumanMessage] = [], captureGaps: [HumanMessageCaptureGap] = [],
                waiting: WaitingExplanation = .empty) {
        self.session = session
        self.statusSummary = statusSummary
        self.hierarchy = hierarchy
        self.goalCheck = goalCheck
        self.humanMessages = humanMessages
        self.captureGaps = captureGaps
        self.waiting = waiting
    }

    /// Follow-ups are accepted for these; Zimmer queues one sent mid-turn.
    public var acceptsFollowUp: Bool {
        switch session.status {
        case .needsInput, .running, .waiting: return true
        default: return false
        }
    }

    /// The channels capture is not configured for, as the web panel's empty state names them:
    /// "Slack", "Slack and the Zimmer web UI", "A, B, and C" — Rails' `to_sentence`.
    public var uncapturedChannels: String {
        let labels = captureGaps.map(\.channelLabel)
        switch labels.count {
        case 0: return ""
        case 1: return labels[0]
        case 2: return "\(labels[0]) and \(labels[1])"
        default: return labels.dropLast().joined(separator: ", ") + ", and " + labels[labels.count - 1]
        }
    }

    /// The Human messages panel's closed row, in the web panel's words: both counts, always,
    /// and what the search could not cover — a cut tree, a channel nothing listens on.
    public var humanMessagesSummary: String {
        let truncated = hierarchy?.truncated ?? false
        if humanMessages.isEmpty {
            var line = "none recorded anywhere in this hierarchy"
            if truncated { line += " that was searched" }
            if !captureGaps.isEmpty {
                line += " — and capture is not configured for " + (captureGaps.count == 1 ? "this hierarchy's channel" : "this hierarchy's channels")
            }
            return line
        }
        let here = humanMessages.filter(\.isHere).count
        var line = "\(here) \(here == 1 ? "message" : "messages") in this session · \(humanMessages.count - here) elsewhere in the hierarchy"
        if truncated { line += " (truncated tree — not every session was searched)" }
        return line
    }
}

struct SessionShowResponse: Decodable {
    let session: SessionSummary
    let statusSummary: StatusSummary?
    let hierarchy: SessionHierarchy?
    let goalCheck: GoalCheck?
    let humanMessages: [HumanMessage]
    let captureGaps: [HumanMessageCaptureGap]
    let waiting: WaitingExplanation

    enum CodingKeys: String, CodingKey {
        case session, waiting
        case statusSummary = "status_summary"
        case hierarchy = "session_hierarchy"
        case humanMessages = "human_messages"
        case captureGaps = "human_message_capture_gaps"
    }

    enum SessionKeys: String, CodingKey {
        case goalCheck = "goal_check"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        session = try container.decode(SessionSummary.self, forKey: .session)
        statusSummary = try? container.decodeIfPresent(StatusSummary.self, forKey: .statusSummary)
        // Drawn when they read, never a reason for the page to fail.
        hierarchy = try? container.decodeIfPresent(SessionHierarchy.self, forKey: .hierarchy)
        // The goal check rides inside the session object, as `session_json` writes it.
        let sessionContainer = try? container.nestedContainer(keyedBy: SessionKeys.self, forKey: .session)
        goalCheck = (try? sessionContainer?.decodeIfPresent(GoalCheck.self, forKey: .goalCheck)) ?? nil
        let sessionID = session.id
        humanMessages = ((try? container.decodeIfPresent([LenientHumanMessage].self, forKey: .humanMessages))?.compactMap(\.message) ?? [])
            .map { message in
                // A server from before `origin` says only where it was said.
                var message = message
                if message.origin == nil { message.origin = message.authoredInSessionID == sessionID ? .here : .elsewhere }
                return message
            }
        captureGaps = (try? container.decodeIfPresent([LenientCaptureGap].self, forKey: .captureGaps))?.compactMap(\.gap) ?? []
        // A server from before the banners sends none, which is nothing to say.
        waiting = (try? container.decodeIfPresent(WaitingExplanation.self, forKey: .waiting)) ?? .empty
    }

    var detail: SessionDetail {
        SessionDetail(session: session, statusSummary: statusSummary, hierarchy: hierarchy, goalCheck: goalCheck,
                      humanMessages: humanMessages, captureGaps: captureGaps, waiting: waiting)
    }
}

/// `goal_check` on a session: the web UI's Goal check panel — one line per criterion the
/// goal's catalog entry declares, each met, unmet, pending or unknown, and a verdict over
/// them. Advisory: nothing acts on it. Nil when the goal is free text or has no checks.
public struct GoalCheck: Hashable, Sendable, Decodable {
    public struct Criterion: Hashable, Sendable, Decodable, Identifiable {
        public var key: String
        public var label: String
        public var status: String
        public var detail: String?

        public var id: String { key }

        public init(key: String, label: String, status: String, detail: String? = nil) {
            self.key = key
            self.label = label
            self.status = status
            self.detail = detail
        }

        enum CodingKeys: String, CodingKey { case key, label, status, detail }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            key = try container.decode(String.self, forKey: .key)
            label = (try? container.decodeIfPresent(String.self, forKey: .label)) ?? key
            status = (try? container.decodeIfPresent(String.self, forKey: .status)) ?? "unknown"
            detail = try? container.decodeIfPresent(String.self, forKey: .detail)
        }
    }

    /// The catalog goal's id and its name, as `config/goals.json` names it.
    public var goalID: String?
    public var goalName: String?
    /// "met", "unmet" or "pending".
    public var verdict: String
    /// The session has not come to rest, so an unmet criterion is work in progress.
    public var provisional: Bool
    public var criteria: [Criterion]
    /// The sessions this one spawned whose PRs were judged, because it recorded none of its
    /// own — a router hands the work down. Empty when its own PRs were judged.
    public var delegatedSessionIDs: [Int]
    /// What the check cannot see, which the web UI says under every check so a `met` is never
    /// read as more than it is.
    public var note: String?

    public init(goalID: String? = nil, goalName: String? = nil, verdict: String, provisional: Bool = false, criteria: [Criterion],
                delegatedSessionIDs: [Int] = [], note: String? = nil) {
        self.goalID = goalID
        self.goalName = goalName
        self.verdict = verdict
        self.provisional = provisional
        self.criteria = criteria
        self.delegatedSessionIDs = delegatedSessionIDs
        self.note = note
    }

    enum CodingKeys: String, CodingKey {
        case verdict, provisional, criteria, note
        case goalID = "goal_id"
        case goalName = "goal_name"
        case delegatedSessionIDs = "delegated_session_ids"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        goalID = try? container.decodeIfPresent(String.self, forKey: .goalID)
        goalName = try? container.decodeIfPresent(String.self, forKey: .goalName)
        verdict = (try? container.decodeIfPresent(String.self, forKey: .verdict)) ?? "pending"
        provisional = (try? container.decodeIfPresent(Bool.self, forKey: .provisional)) ?? false
        criteria = (try? container.decodeIfPresent([Criterion].self, forKey: .criteria)) ?? []
        delegatedSessionIDs = (try? container.decodeIfPresent([Int].self, forKey: .delegatedSessionIDs)) ?? []
        note = try? container.decodeIfPresent(String.self, forKey: .note)
    }

    public var metCount: Int { criteria.filter { $0.status == "met" }.count }

    /// The line beside the verdict, as the web panel writes it: "2 of 4 met · Open Reviewed
    /// Green PR · not at rest yet".
    public var tally: String {
        var parts = ["\(metCount) of \(criteria.count) met"]
        if let goalName, !goalName.isEmpty { parts.append(goalName) }
        var line = parts.joined(separator: " · ")
        if provisional { line += " · not at rest yet" }
        return line
    }
}

/// One entry of `human_messages` on a session: something a person said to this session or
/// to one of its family, through whichever channel, as the web UI's Human messages panel
/// lists them.
public struct HumanMessage: Hashable, Sendable, Identifiable {
    /// Whether a person said it to this session or to another in its family. `elsewhere` is
    /// context about what was first asked for, not an instruction to this session.
    public enum Origin: String, Hashable, Sendable {
        case here, elsewhere
    }

    public var author: String?
    public var channelLabel: String?
    public var authoredInSessionID: Int?
    public var content: String
    public var occurredAt: Date?
    /// Nil only before the response has been read whole; `SessionDetail` always has one.
    public var origin: Origin?
    /// The server's words for where it was said: "this session (#1044)", or "session #1040 —
    /// Route: iOS parity audit and slices".
    public var authoredIn: String?

    /// The same words at the same moment through two channels are two entries.
    public var id: String {
        "\(authoredInSessionID ?? 0)-\(occurredAt?.timeIntervalSince1970 ?? 0)-\(channelLabel ?? "")-\(author ?? "")-\(content.hashValue)"
    }

    public init(author: String?, channelLabel: String?, authoredInSessionID: Int?, content: String, occurredAt: Date?,
                origin: Origin? = nil, authoredIn: String? = nil) {
        self.author = author
        self.channelLabel = channelLabel
        self.authoredInSessionID = authoredInSessionID
        self.content = content
        self.occurredAt = occurredAt
        self.origin = origin
        self.authoredIn = authoredIn
    }

    public var isHere: Bool { origin == .here }

    /// The other session's title, out of the server's "session #1040 — Route: …".
    public var authoredInTitle: String? {
        guard let authoredIn, let dash = authoredIn.range(of: " — ") else { return nil }
        let title = authoredIn[dash.upperBound...].trimmingCharacters(in: .whitespaces)
        return title.isEmpty ? nil : title
    }
}

/// One entry of `human_message_capture_gaps`: a channel this session's family came in through
/// that Zimmer cannot write human messages for, why, and what would fix it — the web panel's
/// amber notice.
public struct HumanMessageCaptureGap: Hashable, Sendable, Identifiable {
    public var channel: String
    public var channelLabel: String
    public var genesis: String?
    public var sessionIDs: [Int]
    public var reason: String?
    public var remedy: String?

    public var id: String { channel }

    public init(channel: String, channelLabel: String? = nil, genesis: String? = nil, sessionIDs: [Int] = [], reason: String? = nil, remedy: String? = nil) {
        self.channel = channel
        self.channelLabel = channelLabel ?? channel
        self.genesis = genesis
        self.sessionIDs = sessionIDs
        self.reason = reason
        self.remedy = remedy
    }

    /// The notice's headline, as the web panel writes it.
    public var headline: String {
        let count = sessionIDs.count
        return "Capture is not configured for \(channelLabel) — which \(count) \(count == 1 ? "session" : "sessions") in this hierarchy came in through."
    }
}

/// A gap without a channel does not read, and is dropped rather than the panel.
struct LenientCaptureGap: Decodable {
    let gap: HumanMessageCaptureGap?

    enum CodingKeys: String, CodingKey {
        case channel, genesis, reason, remedy
        case channelLabel = "channel_label"
        case sessionIDs = "session_ids"
    }

    init(from decoder: Decoder) throws {
        let container = try? decoder.container(keyedBy: CodingKeys.self)
        guard let channel = try? container?.decodeIfPresent(String.self, forKey: .channel), !channel.isEmpty else {
            gap = nil
            return
        }
        gap = HumanMessageCaptureGap(
            channel: channel,
            channelLabel: try? container?.decodeIfPresent(String.self, forKey: .channelLabel),
            genesis: try? container?.decodeIfPresent(String.self, forKey: .genesis),
            sessionIDs: (try? container?.decodeIfPresent([Int].self, forKey: .sessionIDs)) ?? [],
            reason: try? container?.decodeIfPresent(String.self, forKey: .reason),
            remedy: try? container?.decodeIfPresent(String.self, forKey: .remedy)
        )
    }
}

/// An entry that does not read (no content) is dropped, not the whole panel.
struct LenientHumanMessage: Decodable {
    let message: HumanMessage?

    enum CodingKeys: String, CodingKey {
        case content, author, origin
        case authoredIn = "authored_in"
        case authorDisplayName = "author_display_name"
        case channelLabel = "channel_label"
        case authoredInSessionID = "authored_in_session_id"
        case occurredAt = "occurred_at"
    }

    init(from decoder: Decoder) throws {
        let container = try? decoder.container(keyedBy: CodingKeys.self)
        guard let content = try? container?.decodeIfPresent(String.self, forKey: .content), !content.isEmpty else {
            message = nil
            return
        }
        let display = try? container?.decodeIfPresent(String.self, forKey: .authorDisplayName)
        let author = try? container?.decodeIfPresent(String.self, forKey: .author)
        message = HumanMessage(
            author: display ?? author,
            channelLabel: try? container?.decodeIfPresent(String.self, forKey: .channelLabel),
            authoredInSessionID: try? container?.decodeIfPresent(Int.self, forKey: .authoredInSessionID),
            content: content,
            occurredAt: (try? container?.decodeIfPresent(String.self, forKey: .occurredAt)).flatMap(ZimmerJSON.parseDate),
            origin: (try? container?.decodeIfPresent(String.self, forKey: .origin)).flatMap { HumanMessage.Origin(rawValue: $0) },
            authoredIn: try? container?.decodeIfPresent(String.self, forKey: .authoredIn)
        )
    }
}

/// `session_hierarchy` on `GET /api/v1/sessions/:id`: the sessions that spawned this one
/// and the ones it spawned, as the web UI's hierarchy panel draws them — origin first, each
/// node at its depth, in the order to draw them.
public struct SessionHierarchy: Hashable, Sendable, Decodable {
    public struct Node: Hashable, Sendable, Decodable, Identifiable {
        public var id: Int
        public var title: String?
        public var agentRoot: String?
        public var status: SessionStatus
        public var depth: Int
        public var current: Bool
        /// Sessions that queued or interrupted this one and so count as additional seniors —
        /// the web UI's "also senior" chips, each of which can be detached.
        public var uncles: [Int]
        /// Where this node's line of work came from, and the class that resolves to: the web
        /// panel's second pill, "quick_router · priority".
        public var genesis: String?
        public var priorityClass: String?
        /// The node this one is drawn under. Normally its spawn parent; when `spawnEdge` is
        /// false it was reached some other way (through a senior, or placed by a truncated
        /// walk), and the web panel tags the row "drawn under #id" so the indentation is not
        /// read as "spawned".
        public var renderParentID: Int?
        public var spawnEdge: Bool

        enum CodingKeys: String, CodingKey {
            case id, title, status, depth, current, genesis
            case agentRoot = "agent_root"
            case uncles = "uncle_session_ids"
            case priorityClass = "priority_class"
            case renderParentID = "render_parent_session_id"
            case spawnEdge = "spawn_edge"
        }

        public init(id: Int, title: String?, agentRoot: String? = nil, status: SessionStatus, depth: Int, current: Bool = false, uncles: [Int] = [],
                    genesis: String? = nil, priorityClass: String? = nil, renderParentID: Int? = nil, spawnEdge: Bool = true) {
            self.id = id
            self.title = title
            self.agentRoot = agentRoot
            self.status = status
            self.depth = depth
            self.current = current
            self.uncles = uncles
            self.genesis = genesis
            self.priorityClass = priorityClass
            self.renderParentID = renderParentID
            self.spawnEdge = spawnEdge
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(Int.self, forKey: .id)
            title = try? container.decodeIfPresent(String.self, forKey: .title)
            agentRoot = try? container.decodeIfPresent(String.self, forKey: .agentRoot)
            status = (try? container.decode(SessionStatus.self, forKey: .status)) ?? .unknown("unknown")
            depth = (try? container.decodeIfPresent(Int.self, forKey: .depth)) ?? 0
            current = (try? container.decodeIfPresent(Bool.self, forKey: .current)) ?? false
            uncles = (try? container.decodeIfPresent([Int].self, forKey: .uncles)) ?? []
            genesis = try? container.decodeIfPresent(String.self, forKey: .genesis)
            priorityClass = try? container.decodeIfPresent(String.self, forKey: .priorityClass)
            renderParentID = try? container.decodeIfPresent(Int.self, forKey: .renderParentID)
            // A server from before the field drew every row under its spawn parent.
            spawnEdge = (try? container.decodeIfPresent(Bool.self, forKey: .spawnEdge)) ?? true
        }

        public var displayTitle: String {
            if let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return title }
            return "Session \(id)"
        }

        /// "quick_router · priority": the web panel's genesis pill, or nil without a genesis.
        public var genesisLine: String? {
            guard let genesis, !genesis.isEmpty else { return nil }
            guard let priorityClass, !priorityClass.isEmpty else { return genesis }
            return "\(genesis) · \(priorityClass)"
        }
    }

    public var nodes: [Node]
    public var truncated: Bool
    /// The spawn origin: the one session at the top of the spawn tree.
    public var originID: Int?
    /// Every session the graph is drawn from. More than the origin when an uncle edge brings
    /// in a session with a line of its own.
    public var rootIDs: [Int]
    /// Why the walk stopped short, in the server's words.
    public var truncationReason: String?

    public init(nodes: [Node], truncated: Bool = false, originID: Int? = nil, rootIDs: [Int] = [], truncationReason: String? = nil) {
        self.nodes = nodes
        self.truncated = truncated
        self.originID = originID
        self.rootIDs = rootIDs
        self.truncationReason = truncationReason
    }

    enum CodingKeys: String, CodingKey {
        case nodes, truncated
        case originID = "origin_session_id"
        case rootIDs = "root_session_ids"
        case truncationReason = "truncation_reason"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        nodes = try container.decodeIfPresent([Node].self, forKey: .nodes) ?? []
        truncated = (try? container.decodeIfPresent(Bool.self, forKey: .truncated)) ?? false
        originID = try? container.decodeIfPresent(Int.self, forKey: .originID)
        rootIDs = (try? container.decodeIfPresent([Int].self, forKey: .rootIDs)) ?? []
        truncationReason = try? container.decodeIfPresent(String.self, forKey: .truncationReason)
    }

    /// The node's place at the top of the graph: "origin" for the spawn origin, "root" for
    /// another session the graph is drawn from, nil for everything below.
    public func rootMarker(for node: Node) -> String? {
        if node.id == originID { return "origin" }
        if rootIDs.contains(node.id) { return "root" }
        return nil
    }

    /// Some row is drawn under a session that did not spawn it.
    public var hasRedrawnEdges: Bool { nodes.contains { !$0.spawnEdge } }

    /// The closed row, as the web panel's summary writes it: "7 sessions, origin #1040".
    public var summary: String {
        var line = "\(nodes.count) sessions"
        if let originID { line += ", origin #\(originID)" }
        return line
    }

    /// Worth a panel only when the session is not alone in it.
    public var isWorthShowing: Bool { nodes.count > 1 }
}

/// One message of a session's conversation (`GET /api/v1/sessions/:id/conversation`).
public struct ConversationMessage: Hashable, Sendable, Codable, Identifiable {
    public enum Role: String, Sendable, Codable {
        case user, assistant
    }

    /// Position in the conversation, which is stable for a given transcript.
    public var id: Int
    public var role: Role
    public var content: String
    public var timestamp: Date?
    public var hasToolUse: Bool
    public var hasToolResult: Bool

    public init(id: Int, role: Role, content: String, timestamp: Date? = nil, hasToolUse: Bool = false, hasToolResult: Bool = false) {
        self.id = id
        self.role = role
        self.content = content
        self.timestamp = timestamp
        self.hasToolUse = hasToolUse
        self.hasToolResult = hasToolResult
    }

    /// Tool calls and their output: shown folded, because on a phone they bury the words.
    public var isToolTraffic: Bool { hasToolUse || hasToolResult }
}

/// The conversation, newest last, and whether older messages were left out.
public struct Conversation: Hashable, Sendable {
    /// How many the page reads at a time, and by how much *Show earlier* widens the window.
    public static let pageSize = 100
    /// The most the server returns in one read (`CONVERSATION_MAX_LIMIT`).
    public static let maxLimit = 200

    public var messages: [ConversationMessage]
    public var total: Int
    public var truncated: Bool
    /// Where the first of `messages` sits in the whole conversation (0 is the first message):
    /// what *Show earlier* reads back from.
    public var firstPosition: Int

    public init(messages: [ConversationMessage], total: Int? = nil, truncated: Bool = false, firstPosition: Int? = nil) {
        self.messages = messages
        self.total = total ?? messages.count
        self.truncated = truncated
        self.firstPosition = firstPosition ?? max((total ?? messages.count) - messages.count, 0)
    }

    /// The last thing the agent said: what a person deciding a follow-up wants first.
    public var lastAgentMessage: ConversationMessage? {
        messages.last { $0.role == .assistant && !$0.isToolTraffic && !$0.content.isEmpty }
    }
}

struct ConversationResponse: Decodable {
    struct Wire: Decodable {
        let role: String
        let content: String?
        let timestamp: String?
        let has_tool_use: Bool?
        let has_tool_result: Bool?
    }

    let messages: [Wire]
    let total: Int?
    let truncated: Bool?
    let first_position: Int?

    var conversation: Conversation {
        let offset = first_position ?? ((total ?? messages.count) - messages.count)
        let decoded = messages.enumerated().compactMap { index, wire -> ConversationMessage? in
            guard let role = ConversationMessage.Role(rawValue: wire.role) else { return nil }
            return ConversationMessage(
                id: offset + index,
                role: role,
                content: wire.content ?? "",
                timestamp: wire.timestamp.flatMap(ZimmerJSON.parseDate),
                hasToolUse: wire.has_tool_use ?? false,
                hasToolResult: wire.has_tool_result ?? false
            )
        }
        return Conversation(messages: decoded, total: total, truncated: truncated ?? false, firstPosition: offset)
    }
}

/// What happened to a follow-up: delivered now, or queued behind a turn in flight.
public struct FollowUpResult: Hashable, Sendable {
    public var queued: Bool
    public var message: String

    public init(queued: Bool, message: String) {
        self.queued = queued
        self.message = message
    }
}

struct FollowUpResponse: Decodable {
    struct Enqueued: Decodable { let position: Int? }
    let message: String?
    let enqueued_message: Enqueued?
}

struct ArchiveResponse: Decodable {
    let session: SessionSummary
}

struct QuickRouterResponse: Decodable {
    let session_id: Int
}
