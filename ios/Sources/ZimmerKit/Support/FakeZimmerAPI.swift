import Foundation

/// An in-memory Zimmer, for the unit tests and for the app's `#if DEBUG` fixture mode
/// (`-ZimmerFixture`), which is what the UI test and the screenshots drive. An agent cannot
/// complete a Google sign-in, so nothing automated reaches a real server; this is the
/// stand-in, and it behaves like the server where the app depends on it — filters by
/// status, hides archived sessions unless asked, orders by urgency, delivers a follow-up
/// to a waiting session and queues one behind a running turn, refuses to archive what is
/// already archived, and starts Quick Router sessions.
public actor FakeZimmerAPI: ZimmerAPI {
    public private(set) var all: [SessionSummary]
    private var summaries: [Int: StatusSummary]
    private var conversations: [Int: [ConversationMessage]]
    private var nextID: Int

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
        SessionDetail(session: try find(id), statusSummary: summaries[id])
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
                           agentRuntime: "claude_code", createdAt: ago(90), updatedAt: ago(2)),
            SessionSummary(id: 1038, title: "PR #1261 is green and ready — merge it?", status: .needsInput,
                           agentRuntime: "claude_code", createdAt: ago(240), updatedAt: ago(6)),
            SessionSummary(id: 1035, title: "Which Postgres version should staging run?", status: .needsInput,
                           agentRuntime: "codex", createdAt: ago(300), updatedAt: ago(41)),
            SessionSummary(id: 1031, title: "Nightly dependency sweep", status: .waiting,
                           agentRuntime: "claude_code", createdAt: ago(20), updatedAt: ago(20)),
            SessionSummary(id: 1027, title: "Rotate the staging deploy key", status: .failed,
                           agentRuntime: "claude_code", createdAt: ago(600), updatedAt: ago(180)),
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
