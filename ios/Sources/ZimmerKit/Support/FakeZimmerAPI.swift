import Foundation

/// An in-memory Zimmer, for the unit tests and for the app's `#if DEBUG` fixture mode
/// (`-ZimmerFixture`), which is what the UI test and the screenshots drive. An agent cannot
/// complete a Google sign-in, so nothing automated reaches a real server; this is the
/// stand-in, and it behaves like the server where the app depends on it — filters by
/// status, hides archived sessions unless asked, orders by urgency, queues a follow-up
/// behind a running turn, refuses to archive a session mid-turn or already archived, and
/// starts Quick Router sessions. One simplification: the real server also queues for a
/// `waiting` session whose turn is handed over but not yet started; the fake delivers to
/// every `waiting` session.
public actor FakeZimmerAPI: ZimmerAPI {
    public private(set) var all: [SessionSummary]
    private var summaries: [Int: StatusSummary]
    private var conversations: [Int: [ConversationMessage]]
    private var nextID: Int
    public private(set) var registeredDevices: [String: APNsEnvironment] = [:]

    public init(sessions: [SessionSummary] = FakeZimmerAPI.sampleSessions(), now: Date = Date()) {
        self.all = sessions
        self.summaries = FakeZimmerAPI.sampleSummaries()
        self.conversations = FakeZimmerAPI.sampleConversations(now: now)
        self.nextID = (sessions.map(\.id).max() ?? 0) + 1
    }

    public func sessions(_ filter: SessionFilter) async throws -> [SessionSummary] {
        let matching = all.filter { session in
            switch filter {
            case .needsInput: return session.status == .needsInput
            case .active: return session.status != .archived
            case .running: return session.status == .running
            case .failed: return session.status == .failed
            case .archived: return session.status == .archived
            }
        }
        return SessionOrdering.sorted(matching)
    }

    public func session(_ id: Int) async throws -> SessionDetail {
        SessionDetail(session: try find(id), statusSummary: summaries[id], hierarchy: Self.sampleHierarchy(for: id, in: all))
    }

    public func conversation(_ id: Int) async throws -> Conversation {
        _ = try find(id)
        return Conversation(messages: conversations[id] ?? [])
    }

    public func followUp(_ id: Int, prompt: String) async throws -> FollowUpResult {
        var session = try find(id)
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ZimmerError.http(status: 422, message: "prompt is required") }
        switch session.status {
        case .running:
            return FollowUpResult(queued: true, message: "Message queued (session is running). It will be sent when the agent completes its current task.")
        case .needsInput, .waiting:
            var messages = conversations[id] ?? []
            messages.append(ConversationMessage(id: messages.count, role: .user, content: text, timestamp: Date()))
            conversations[id] = messages
            session.status = .running
            session.updatedAt = Date()
            replace(session)
            return FollowUpResult(queued: false, message: "Follow-up prompt sent")
        default:
            throw ZimmerError.http(status: 422, message: "Session is \(session.status.rawValue). Follow-up prompts can only be sent to running, waiting, or needs_input sessions.")
        }
    }

    public func archive(_ id: Int) async throws -> SessionSummary {
        var session = try find(id)
        guard session.status != .archived else {
            throw ZimmerError.http(status: 422, message: "Session cannot be trashed from current status: archived")
        }
        guard session.status != .running else {
            throw ZimmerError.http(status: 422, message: "Session \(id) has a turn in flight. Archive it once the turn ends.")
        }
        session.status = .archived
        session.archivedAt = Date()
        session.updatedAt = Date()
        replace(session)
        return session
    }

    public func startQuickRouter(_ prompt: String) async throws -> Int {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ZimmerError.http(status: 422, message: "prompt can't be blank") }
        let id = nextID
        nextID += 1
        let title = text.count > 60 ? String(text.prefix(57)) + "…" : text
        all.append(SessionSummary(id: id, title: title, status: .waiting, agentRuntime: "claude_code",
                                  prompt: text, createdAt: Date(), updatedAt: Date()))
        conversations[id] = [ConversationMessage(id: 0, role: .user, content: text, timestamp: Date())]
        return id
    }

    public func registerDevice(token: String, environment: APNsEnvironment, deviceName: String?, appVersion: String?) async throws {
        registeredDevices[token] = environment
    }

    public func unregisterDevice(token: String) async throws {
        registeredDevices[token] = nil
    }

    private func find(_ id: Int) throws -> SessionSummary {
        guard let session = all.first(where: { $0.id == id }) else {
            throw ZimmerError.http(status: 404, message: "The requested resource was not found")
        }
        return session
    }

    private func replace(_ session: SessionSummary) {
        if let index = all.firstIndex(where: { $0.id == session.id }) { all[index] = session }
    }

    // MARK: - Sample data

    /// A believable board: two sessions waiting on a person, work in flight, one failure,
    /// one finished. Times are relative to `now` so a screenshot never shows a stale date.
    public static func sampleSessions(now: Date = Date()) -> [SessionSummary] {
        func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }
        return [
            SessionSummary(id: 1042, title: "Add a CarPlay scene to the iOS app", status: .running,
                           agentRuntime: "claude_code", createdAt: ago(90), updatedAt: ago(2),
                           priorityClass: "spot", precedence: 30, lastUserActivityAt: ago(70)),
            SessionSummary(id: 1038, title: "PR #1261 is green and ready — merge it?", status: .needsInput,
                           agentRuntime: "claude_code", createdAt: ago(240), updatedAt: ago(6),
                           goal: "Unmerged PR is open and CI is green.", favorited: true,
                           priorityClass: "priority", precedence: 5,
                           effort: EffortSummary(level: "high", source: "default", default: "high", levels: ["low", "medium", "high", "xhigh", "max"]),
                           model: "opus", agentRoot: "zimmer", lastUserActivityAt: ago(30),
                           pullRequests: [PullRequestLink(url: URL(string: "https://github.com/tadasant/zimmer/pull/1261")!, state: "open", ci: "pass")]),
            SessionSummary(id: 1035, title: "Which Postgres version should staging run?", status: .needsInput,
                           agentRuntime: "codex", createdAt: ago(300), updatedAt: ago(41),
                           priorityClass: "spot", precedence: 20, lastUserActivityAt: ago(3)),
            SessionSummary(id: 1031, title: "Nightly dependency sweep", status: .waiting,
                           agentRuntime: "claude_code", createdAt: ago(20), updatedAt: ago(20),
                           priorityClass: "spot", precedence: 50),
            SessionSummary(id: 1029, title: "Draft the October changelog", status: .waiting,
                           agentRuntime: "claude_code", createdAt: ago(900), updatedAt: ago(800),
                           visibility: .snoozed, snoozedUntil: now.addingTimeInterval(20 * 3600)),
            SessionSummary(id: 1027, title: "Rotate the staging deploy key", status: .failed,
                           agentRuntime: "claude_code", createdAt: ago(600), updatedAt: ago(180),
                           priorityClass: "spot", precedence: 10),
            SessionSummary(id: 1019, title: "Fix the flaky transcript poller test", status: .archived,
                           agentRuntime: "claude_code", createdAt: ago(2_000), updatedAt: ago(1_400),
                           archivedAt: ago(1_400)),
        ]
    }

    static func sampleSummaries() -> [Int: StatusSummary] {
        [
            1038: StatusSummary(summary: "The PR is open, CI is green and the review is done. It needs your go-ahead to merge."),
            1035: StatusSummary(summary: "Asking whether staging should match production's Postgres 16 or try 17 first."),
            1042: StatusSummary(summary: "Building the CarPlay list template; about halfway through."),
            1027: StatusSummary(summary: "Failed: the deploy key in the secret store is read-only for this session."),
        ]
    }

    static func sampleConversations(now: Date) -> [Int: [ConversationMessage]] {
        func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }
        return [
            1038: [
                ConversationMessage(id: 0, role: .user, content: "Open a PR for the iOS scaffold and get CI green.", timestamp: ago(240)),
                ConversationMessage(id: 1, role: .assistant, content: "Using tool: Bash\ngh pr checks 1261", timestamp: ago(12), hasToolUse: true),
                ConversationMessage(id: 2, role: .assistant, content: "PR #1261 is open and every check is green. The review found nothing blocking. Shall I merge it?", timestamp: ago(6)),
            ],
            1035: [
                ConversationMessage(id: 0, role: .user, content: "Bring staging's database up to date.", timestamp: ago(300)),
                ConversationMessage(id: 1, role: .assistant, content: "Production runs Postgres 16. Should staging match it, or try 17 first?", timestamp: ago(41)),
            ],
        ]
    }
}

// MARK: - Session actions
//
// In this file because an extension here can read the actor's private state. Each behaves
// as the server does where the app depends on it: a pause needs a running session, a
// restart a failed or needs-input one, a restore a trashed one; a blank title clears it.
extension FakeZimmerAPI {
    public func sessions(_ filter: SessionFilter, board: BoardFilter) async throws -> SessionSearchResult {
        SessionSearchResult(sessions: try await sessions(filter).filter(board.admits))
    }

    public func search(_ query: String, contents: Bool, filter: SessionFilter, board: BoardFilter) async throws -> SessionSearchResult {
        let needle = query.lowercased()
        let matches = try await sessions(filter, board: board).sessions.filter { session in
            if session.displayTitle.lowercased().contains(needle) { return true }
            guard contents else { return false }
            return (conversations[session.id] ?? []).contains { $0.content.lowercased().contains(needle) }
        }
        return SessionSearchResult(sessions: matches)
    }

    public func sendNow(_ id: Int, prompt: String) async throws -> FollowUpResult {
        var session = try find(id)
        guard [SessionStatus.running, .waiting, .needsInput].contains(session.status) else {
            throw ZimmerError.http(status: 422, message: "Session is \(session.status.rawValue). Follow-up prompts can only be sent to running, waiting, or needs_input sessions.")
        }
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        var messages = conversations[id] ?? []
        messages.append(ConversationMessage(id: messages.count, role: .user, content: text, timestamp: Date()))
        conversations[id] = messages
        session.status = .running
        session.updatedAt = Date()
        replace(session)
        return FollowUpResult(queued: false, message: "Follow-up prompt sent immediately")
    }

    public func unarchive(_ id: Int) async throws -> SessionSummary {
        try change(id, refusal: "Session is not in trash", when: { $0.status != .archived }) {
            $0.status = .needsInput
            $0.archivedAt = nil
        }
    }

    public func restart(_ id: Int) async throws -> SessionSummary {
        // The server resumes into `waiting`: the turn is handed over, not yet started.
        try change(id, refusal: "Session cannot be restarted from current status", when: { ![SessionStatus.failed, .needsInput].contains($0.status) }) {
            $0.status = .waiting
        }
    }

    public func pause(_ id: Int) async throws -> SessionSummary {
        try change(id, refusal: "Session is not running", when: { $0.status != .running }) {
            $0.status = .needsInput
        }
    }

    public func toggleFavorite(_ id: Int) async throws -> SessionSummary {
        try change(id) { $0.favorited = !$0.isFavorite }
    }

    public func setVisibility(_ id: Int, _ change: VisibilityChange) async throws -> SessionSummary {
        if case let .snoozed(until) = change, until <= Date() {
            throw ZimmerError.http(status: 422, message: "snoozed_until must be in the future")
        }
        return try self.change(id) { session in
            switch change {
            case .visible: session.visibility = .visible; session.snoozedUntil = nil
            case .hidden: session.visibility = .hidden; session.snoozedUntil = nil
            case let .snoozed(until): session.visibility = .snoozed; session.snoozedUntil = until
            }
            session.effectiveVisibility = session.visibility
        }
    }

    public func updateNotes(_ id: Int, notes: String) async throws -> SessionSummary {
        try change(id) { $0.notes = notes.isEmpty ? nil : notes }
    }

    public func rename(_ id: Int, title: String) async throws -> SessionSummary {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ZimmerError.http(status: 422, message: "Title cannot be empty")
        }
        return try change(id) { $0.title = title }
    }

    public func updateGoal(_ id: Int, goal: String) async throws -> SessionSummary {
        try change(id) { $0.goal = goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : goal }
    }

    public func updateEffort(_ id: Int, effort: String?) async throws -> SessionSummary {
        let session = try find(id)
        let levels = session.effort?.levels ?? []
        if let effort, !levels.contains(effort) {
            throw ZimmerError.http(status: 422, message: "\(effort) is not an effort level for this model")
        }
        return try change(id) { session in
            let fallback = session.effort?.default
            session.effort = EffortSummary(level: effort ?? fallback, source: effort == nil ? "default" : "explicit", default: fallback, levels: levels)
        }
    }

    public func setSchedulingClass(_ id: Int, priority: Bool) async throws -> SchedulingChange {
        let current = try find(id)
        let starts = priority && current.status == .waiting && !current.isPriority
        let session = try change(id) { session in
            session.priorityClass = priority ? "priority" : "spot"
            // Promoting a waiting session starts it, as the server's PATCH does.
            if starts { session.status = .running }
        }
        return SchedulingChange(session: session, startOutcome: starts ? "started" : nil,
                                startMessage: starts ? "Session \(id)'s next turn is due now: resumed from the spot queue." : nil)
    }

    public func setHeartbeat(_ id: Int, enabled: Bool) async throws -> SessionSummary {
        try change(id) { $0.heartbeatEnabled = enabled }
    }

    public func transcriptText(_ id: Int) async throws -> String {
        _ = try find(id)
        let messages = conversations[id] ?? []
        guard !messages.isEmpty else { throw ZimmerError.http(status: 404, message: "No transcript available for this session") }
        return messages.map { "\($0.role == .user ? "User" : "Assistant"): \($0.content)" }.joined(separator: "\n\n")
    }

    public func bulkArchive(_ ids: [Int]) async throws -> BulkArchiveResult {
        var archived = 0
        var errors: [BulkArchiveResult.Refusal] = []
        for id in ids {
            do {
                _ = try await archive(id)
                archived += 1
            } catch let ZimmerError.http(_, message) {
                errors.append(BulkArchiveResult.Refusal(id: id, message: message ?? "Cannot archive"))
            }
        }
        return BulkArchiveResult(archivedCount: archived, errors: errors)
    }

    public func refreshAll() async throws -> String {
        let failed = all.filter { $0.status == .failed }
        for session in failed {
            var restarted = session
            restarted.status = .waiting
            replace(restarted)
        }
        return "Refreshed \(all.count - failed.count), restarted \(failed.count), continued 0"
    }

    /// 1038 spawned 1042 and 1031; every one of them sees the same three-node tree.
    static func sampleHierarchy(for id: Int, in sessions: [SessionSummary]) -> SessionHierarchy? {
        let tree = [(1038, 0), (1042, 1), (1031, 1)]
        guard tree.contains(where: { $0.0 == id }) else { return SessionHierarchy(nodes: []) }
        return SessionHierarchy(nodes: tree.compactMap { nodeID, depth in
            guard let session = sessions.first(where: { $0.id == nodeID }) else { return nil }
            return SessionHierarchy.Node(id: nodeID, title: session.title, agentRoot: "zimmer", status: session.status, depth: depth, current: nodeID == id)
        })
    }

    public func regenerateStatusSummary(_ id: Int) async throws -> String {
        _ = try find(id)
        return "Status summary regeneration queued"
    }

    public func refreshTranscript(_ id: Int) async throws -> String {
        _ = try find(id)
        return "Transcript refreshed (\((conversations[id] ?? []).count) messages)"
    }

    /// Apply `edit` to one session, unless `when` says the server would refuse it.
    private func change(
        _ id: Int, refusal: String = "", when refused: (SessionSummary) -> Bool = { _ in false },
        _ edit: (inout SessionSummary) -> Void
    ) throws -> SessionSummary {
        var session = try find(id)
        guard !refused(session) else { throw ZimmerError.http(status: 422, message: "\(refusal): \(session.status.rawValue)") }
        edit(&session)
        session.updatedAt = Date()
        replace(session)
        return session
    }
}

// MARK: - The Ranked view's writes, and server-side view ordering
//
// As the server: Start now needs a waiting session with a turn to take, and a reorder takes
// a spot session to the midpoint of the neighbours it was dropped between.
extension FakeZimmerAPI {
    public func sessions(_ filter: SessionFilter, board: BoardFilter, view: BoardView) async throws -> SessionSearchResult {
        let rows = try await sessions(filter, board: board).sessions
        return SessionSearchResult(sessions: view.sections(rows).flatMap(\.sessions))
    }

    public func startNow(_ id: Int) async throws -> String {
        let session = try find(id)
        guard session.status == .waiting else {
            throw ZimmerError.http(status: 422, message: "Session \(id) is \(session.status.rawValue); only a waiting session's turn can be brought forward.")
        }
        _ = try change(id) { $0.status = .running }
        return "Session \(id)'s next turn is due now: resumed from the spot queue."
    }

    public func reorder(_ id: Int, above: Int?, below: Int?) async throws -> SessionSummary {
        guard above != id, below != id else { throw ZimmerError.http(status: 422, message: "A session cannot be dropped next to itself") }
        let upper = try above.map { try find($0).precedence ?? 0 }
        let lower = try below.map { try find($0).precedence ?? 0 }
        let precedence: Int
        switch (upper, lower) {
        case let (upper?, lower?): precedence = (upper + lower) / 2
        case let (upper?, nil): precedence = upper - 10
        case let (nil, lower?): precedence = lower + 10
        case (nil, nil): precedence = 0
        }
        return try change(id) { $0.precedence = precedence }
    }
}
