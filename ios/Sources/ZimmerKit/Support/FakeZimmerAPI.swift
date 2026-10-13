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
    private var queues: [Int: [QueuedMessage]] = FakeZimmerAPI.sampleQueues()
    /// 1035 queued a message to 1031, so it is drawn as 1031's additional senior.
    private var uncles: [Int: [Int]] = [1031: [1035]]
    private var inbox: [InboxNotification] = FakeZimmerAPI.sampleNotifications()
    private var triggerList: [TriggerSummary] = FakeZimmerAPI.sampleTriggers()
    /// What each follow-up carried, newest last, so a test can see attachments arrive.
    public private(set) var sentAttachments: [Int: [[MessageAttachment]]] = [:]
    /// Every Quick Router start, in order, so a test can see what went with the words.
    public private(set) var quickRouterRequests: [QuickRouterRequest] = []
    private var prompts: [Int: [PendingElicitation]] = FakeZimmerAPI.samplePrompts()
    public private(set) var registeredDevices: [String: APNsEnvironment] = [:]
    private let live: Bool
    private var conversationReads: [Int: Int] = [:]

    /// `live`: a running session's agent keeps talking, a line per read of its conversation
    /// after the first, so a screen that reads again can be seen to.
    public init(sessions: [SessionSummary] = FakeZimmerAPI.sampleSessions(), now: Date = Date(), live: Bool = false) {
        self.live = live
        self.all = sessions
        self.summaries = FakeZimmerAPI.sampleSummaries()
        self.conversations = FakeZimmerAPI.sampleConversations(now: now)
        if live {
            // Long enough to scroll back through, so following the end can be told from not.
            conversations[1042] = (0..<30).map { index in
                ConversationMessage(id: index, role: index.isMultiple(of: 2) ? .assistant : .user,
                                    content: "Earlier step \(index) of the CarPlay scene.", timestamp: now.addingTimeInterval(Double(index - 30) * 60))
            }
        }
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
        var hierarchy = Self.sampleHierarchy(for: id, in: all)
        let seniors = uncles
        if let nodes = hierarchy?.nodes {
            hierarchy?.nodes = nodes.map { node in
                var node = node
                node.uncles = seniors[node.id] ?? []
                return node
            }
        }
        return SessionDetail(session: try find(id), statusSummary: summaries[id], hierarchy: hierarchy,
                             goalCheck: Self.sampleGoalChecks()[id], humanMessages: Self.sampleHumanMessages()[id] ?? [])
    }

    /// As the server: the newest `limit`, positions counted from the start, capped at 200.
    public func conversation(_ id: Int, limit: Int) async throws -> Conversation {
        let session = try find(id)
        if live, session.status == .running {
            let reads = conversationReads[id, default: 0]
            conversationReads[id] = reads + 1
            if reads > 0 {
                var messages = conversations[id] ?? []
                messages.append(ConversationMessage(id: messages.count, role: .assistant, content: "Still working — step \(reads) done.", timestamp: Date()))
                conversations[id] = messages
            }
        }
        // As the server: each message names its place in the transcript. Here a
        // conversation is its own transcript, so that is its position.
        let all = (conversations[id] ?? []).enumerated().map { index, message in
            var message = message
            message.transcriptIndex = message.transcriptIndex ?? index
            return message
        }
        let window = min(max(limit, 1), Conversation.maxLimit)
        return Conversation(messages: Array(all.suffix(window)), total: all.count, truncated: all.count > window)
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

    /// As the server: a blank prompt, a harness the registry does not carry, a model the
    /// harness does not offer, or a parent that is not there is refused; spot lands at the
    /// top of the spot queue; the new session threads under its parent.
    public func startQuickRouter(_ request: QuickRouterRequest) async throws -> Int {
        let text = request.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ZimmerError.http(status: 422, message: "prompt can't be blank") }
        let runtime = request.runtime ?? "claude_code"
        guard Self.sampleConfigs.runtimeModels[runtime] != nil else {
            throw ZimmerError.http(status: 422, message: "That harness is not available.")
        }
        if let model = request.model, !Self.sampleConfigs.models(for: runtime).contains(where: { $0.id == model }) {
            throw ZimmerError.http(status: 422, message: "That model is not available for the \(runtime) harness.")
        }
        if let parent = request.parentSessionID, !all.contains(where: { $0.id == parent }) {
            throw ZimmerError.http(status: 422, message: "parent_session_id names no session")
        }
        let id = nextID
        nextID += 1
        let title = text.count > 60 ? String(text.prefix(57)) + "…" : text
        let topOfSpot = (all.compactMap { $0.priorityClass == "spot" ? $0.precedence : nil }.max() ?? 0) + 1
        all.append(SessionSummary(id: id, title: title, status: .waiting, agentRuntime: runtime,
                                  prompt: text, createdAt: Date(), updatedAt: Date(),
                                  priorityClass: request.spot ? "spot" : "priority", precedence: request.spot ? topOfSpot : nil,
                                  model: request.model))
        conversations[id] = [ConversationMessage(id: 0, role: .user, content: text, timestamp: Date())]
        quickRouterRequests.append(request)
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
            failed(SessionSummary(id: 1027, title: "Rotate the staging deploy key", status: .failed,
                                  agentRuntime: "claude_code", createdAt: ago(600), updatedAt: ago(180),
                                  priorityClass: "spot", precedence: 10, agentRoot: "zimmer-production",
                                  pullRequests: [PullRequestLink(url: URL(string: "https://github.com/tadasant/zimmer/pull/1288")!, state: "open", ci: "fail")])),
            // The richest session: a long title, four PRs, a long goal, notes, a wide
            // hierarchy, a long conversation. What the detail screen has to stay legible on.
            SessionSummary(id: 1044, title: "Audit the iOS app for parity with the PWA, then implement the findings as a series of standalone slices — quick router and the detail page first",
                           status: .needsInput, agentRuntime: "claude_code", createdAt: ago(3_000), updatedAt: ago(9),
                           goal: "Unmerged PR is open, CI is confirmed green, an independent fresh-eyes review of the PR has been performed and all of its feedback addressed, and the PR description carries a Verification section with screenshots for every UI change.",
                           notes: "Tadas: the detail page is too verbose with real data. Keep the slices off the files #1282 and #1284 touch where possible.",
                           // Spot, at the foot of the queue: the Ranked view's UI test reads row
                           // frames in the spot queue, and a second priority row with a two-line
                           // title could push them off a small simulator's screen.
                           priorityClass: "spot", precedence: 5,
                           effort: EffortSummary(level: "high", source: "explicit", default: "medium", levels: ["low", "medium", "high", "xhigh", "max"]),
                           // No last touch of its own, so Last Touched files it last: the rows above it
                           // keep the places the UI tests tap, on a simulator of any height.
                           model: "claude-opus-4-5-20260401", agentRoot: "zimmer-orchestrator",
                           pullRequests: [
                               PullRequestLink(url: URL(string: "https://github.com/tadasant/zimmer/pull/1281")!, state: "merged", ci: "pass"),
                               PullRequestLink(url: URL(string: "https://github.com/tadasant/zimmer/pull/1282")!, state: "open", ci: "pass"),
                               PullRequestLink(url: URL(string: "https://github.com/tadasant/zimmer/pull/1283")!, state: "open", ci: "pending"),
                               PullRequestLink(url: URL(string: "https://github.com/tadasant/zimmer/pull/1284")!, state: "closed", ci: "fail"),
                           ]),
            SessionSummary(id: 1019, title: "Fix the flaky transcript poller test", status: .archived,
                           agentRuntime: "claude_code", createdAt: ago(2_000), updatedAt: ago(1_400),
                           archivedAt: ago(1_400)),
        ]
    }

    /// The failure the web UI's failure details read: a reason, an exception, an exit status.
    private static func failed(_ session: SessionSummary) -> SessionSummary {
        var session = session
        session.metadata = SessionMetadata(
            agentRoot: session.agentRoot, lastUserActivityAt: session.metadata?.lastUserActivityAt,
            failureReason: "process_exited",
            exceptionMessage: "The deploy key in the secret store is read-only for this session (secrets/staging-deploy-key: permission denied).",
            exceptionClass: "Zimmer::SecretWriteRefused", exitStatus: 1
        )
        return session
    }

    static func sampleSummaries(now: Date = Date()) -> [Int: StatusSummary] {
        [
            1044: StatusSummary(
                summary: "The audit is written up in ios/PARITY_AUDIT.md and the first two slices are open as PRs: the Quick Router on every screen, and the session page's density. The second one is waiting on your look at the screenshots before it goes further; the third slice, the board's rows, is drafted on a branch.",
                generatedAt: now.addingTimeInterval(-12 * 60), messagesSinceGenerated: 2),
            1038: StatusSummary(summary: "The PR is open, CI is green and the review is done. It needs your go-ahead to merge.", generatedAt: now.addingTimeInterval(-6 * 60), messagesSinceGenerated: 0),
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
                ConversationMessage(id: 1, role: .assistant, content: "Production runs **Postgres 16**; staging is on 15. Two ways to go:\n\n- Match production: `pg_upgrade` to 16, ten minutes, no surprises.\n- Try 17 first on staging, so production's upgrade is rehearsed.\n\nThe upgrade itself is one command either way:\n\n```sh\nbin/rails db:upgrade -- --target 16\n```\n\nShould staging match it, or try 17 first?", timestamp: ago(41)),
            ],
            1044: [
                ConversationMessage(id: 0, role: .user, content: "Zimmer iOS still doesn't have parity with PWA. There is no quick router in the corner of every screen, and it should be the most prominent thing on the main screen. With real data the detail page is too verbose and hard to parse. Make it more information dense. Do an extensive audit for parity and design, then implement it as a series of standalone slices.", timestamp: ago(3_000)),
                ConversationMessage(id: 1, role: .assistant, content: "Using tool: Bash\ngh pr view 1270 --json body", timestamp: ago(2_900), hasToolUse: true),
                ConversationMessage(id: 2, role: .assistant, content: "Tool result: (4,812 characters)", timestamp: ago(2_899), hasToolResult: true),
                ConversationMessage(id: 3, role: .assistant, content: "The audit is done. Twenty-six findings, grouped into six slices:\n\n1. Quick Router on every screen — a bar at the foot of the board, a button in every other corner.\n2. Session page density — one chip line for the header, a divided card for goal, notes and hierarchy, tighter conversation.\n3. Board density — grouped rows, compact ages.\n4. Quick Router advanced options and attachments (a server parameter change).\n5. The other tabs.\n6. Transcript parity: markdown, earlier messages, copy.\n\nThe first slice is open as #1293. Shall I carry on with the session page before you have looked at the first?", timestamp: ago(1_400)),
                ConversationMessage(id: 4, role: .user, content: "Carry on. Screenshots with real data on every slice.", timestamp: ago(1_380)),
                ConversationMessage(id: 5, role: .assistant, content: "Using tool: Edit\nios/App/Zimmer/Views/SessionDetailView.swift", timestamp: ago(600), hasToolUse: true),
                ConversationMessage(id: 6, role: .assistant, content: "Slice 2 is open as #1294 with before-and-after screenshots from the simulator on the long-titled fixture session. The header is one chip line, goal and notes clamp to two lines, the hierarchy is a disclosure, and the conversation is in the smaller face. The board's density is drafted on a branch and goes up next.\n\nOne thing needs you: the Goal check panel reads `pending` on every session whose goal is free text, because the API returns a check only for catalog goals. Should the app hide the panel in that case, as the web does, or say \"no checks for this goal\"? I have gone with hiding it, as the web does.", timestamp: ago(9)),
            ],
        ]
    }

    /// `goal_check` as the server writes it for a catalog goal with criteria.
    static func sampleGoalChecks() -> [Int: GoalCheck] {
        [
            1044: GoalCheck(goalName: "open-reviewed-green-pr", verdict: "pending", provisional: false, criteria: [
                GoalCheck.Criterion(key: "pr_open", label: "An unmerged PR is open", status: "met", detail: "#1282 is open"),
                GoalCheck.Criterion(key: "ci_green", label: "CI is green on the PR", status: "met", detail: "pass on #1282"),
                GoalCheck.Criterion(key: "reviewed", label: "A fresh-eyes review has been addressed", status: "pending", detail: "no review comment yet"),
                GoalCheck.Criterion(key: "screenshots", label: "The PR carries screenshots", status: "unknown"),
            ]),
            1038: GoalCheck(goalName: "open-reviewed-green-pr", verdict: "met", criteria: [
                GoalCheck.Criterion(key: "pr_open", label: "An unmerged PR is open", status: "met", detail: "#1261 is open"),
                GoalCheck.Criterion(key: "ci_green", label: "CI is green on the PR", status: "met", detail: "pass on #1261"),
            ]),
        ]
    }

    /// `human_messages` as the server writes them: what people said, through which channel.
    static func sampleHumanMessages(now: Date = Date()) -> [Int: [HumanMessage]] {
        func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }
        return [
            1044: [
                HumanMessage(author: "Tadas", channelLabel: "Web UI", authoredInSessionID: 1040, content: "Zimmer iOS still doesn't have parity with PWA…", occurredAt: ago(3_010)),
                HumanMessage(author: "Tadas", channelLabel: "iOS app", authoredInSessionID: 1044, content: "Carry on. Screenshots with real data on every slice.", occurredAt: ago(1_380)),
            ],
            1038: [
                HumanMessage(author: "Tadas", channelLabel: "Web UI", authoredInSessionID: 1038, content: "Open a PR for the iOS scaffold and get CI green.", occurredAt: ago(240)),
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

    /// As the server answers the app: a turn in flight ends, a queue waits for `force`.
    public func trash(_ id: Int, force: Bool) async throws -> TrashOutcome {
        var session = try find(id)
        guard session.status != .archived else {
            throw ZimmerError.http(status: 422, message: "Session cannot be trashed from current status: archived")
        }
        if !force, !(queues[id] ?? []).isEmpty { return .queued }
        queues[id] = nil
        session.status = .archived
        session.archivedAt = Date()
        session.updatedAt = Date()
        replace(session)
        return .trashed(session)
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
        // As the server with `end_turn`: a turn in flight goes, a queue is reported.
        for id in ids {
            do {
                if try await trash(id, force: false) == .queued {
                    errors.append(BulkArchiveResult.Refusal(id: id, message: "Cannot archive session \(id): queued messages have not been delivered."))
                } else {
                    archived += 1
                }
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

    /// 1038 spawned 1042 and 1031; every one of them sees the same three-node tree. 1044
    /// sits under a router session with five siblings it spawned, a tree wide enough that
    /// the panel folds it.
    static func sampleHierarchy(for id: Int, in sessions: [SessionSummary]) -> SessionHierarchy? {
        if id == 1044 {
            let family: [(Int, String, SessionStatus, Int)] = [
                (1040, "Route: iOS parity audit and slices", .archived, 0),
                (1044, "Audit the iOS app for parity with the PWA, then implement the findings as a series of standalone slices — quick router and the detail page first", .needsInput, 1),
                (1045, "Slice 1: the Quick Router on every screen", .archived, 2),
                (1046, "Slice 2: the session page's density", .running, 2),
                (1047, "Slice 3: the board's rows", .waiting, 2),
                (1048, "Fresh-eyes review of #1293", .archived, 2),
                (1049, "Fresh-eyes review of #1294", .failed, 2),
            ]
            return SessionHierarchy(nodes: family.map { nodeID, title, status, depth in
                SessionHierarchy.Node(id: nodeID, title: title, agentRoot: depth == 0 ? "zimmer-orchestrator" : "zimmer", status: status, depth: depth, current: nodeID == id)
            })
        }
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

// MARK: - Queue, logs and subagents
//
// As the server: a queue is managed but never added to here (the app queues through
// follow_up), positions close up after a delete, and Send now delivers the message as the
// session's next turn.
extension FakeZimmerAPI {
    public func queue(_ id: Int) async throws -> [QueuedMessage] {
        _ = try find(id)
        return (queues[id] ?? []).sorted { $0.position < $1.position }
    }

    public func editQueued(_ id: Int, message: Int, content: String) async throws -> QueuedMessage {
        let text = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ZimmerError.http(status: 422, message: "Content can't be blank") }
        var list = try queued(id)
        guard let index = list.firstIndex(where: { $0.id == message }) else { throw ZimmerError.http(status: 404, message: "The requested resource was not found") }
        list[index].content = text
        queues[id] = list
        return list[index]
    }

    public func deleteQueued(_ id: Int, message: Int) async throws {
        var list = try queued(id)
        guard list.contains(where: { $0.id == message }) else { throw ZimmerError.http(status: 404, message: "The requested resource was not found") }
        list.removeAll { $0.id == message }
        queues[id] = Self.renumbered(list)
    }

    public func moveQueued(_ id: Int, message: Int, to position: Int) async throws -> QueuedMessage {
        guard position >= 1 else { throw ZimmerError.http(status: 422, message: "Position must be >= 1") }
        var list = try queued(id)
        guard let index = list.firstIndex(where: { $0.id == message }) else { throw ZimmerError.http(status: 404, message: "The requested resource was not found") }
        let moved = list.remove(at: index)
        list.insert(moved, at: min(position - 1, list.count))
        list = Self.renumbered(list)
        queues[id] = list
        return list.first { $0.id == message }!
    }

    public func sendQueuedNow(_ id: Int, message: Int) async throws {
        var list = try queued(id)
        guard let index = list.firstIndex(where: { $0.id == message }) else { throw ZimmerError.http(status: 404, message: "The requested resource was not found") }
        let sent = list.remove(at: index)
        queues[id] = Self.renumbered(list)
        var history = conversations[id] ?? []
        history.append(ConversationMessage(id: history.count, role: .user, content: sent.content, timestamp: Date()))
        conversations[id] = history
    }

    public func logs(_ id: Int, page: Int) async throws -> LogPage {
        let session = try find(id)
        let now = Date()
        let lines = [
            ("Turn started", "info", 2.0), ("Cloned the repository", "info", 9.0),
            ("MCP server playwright took 41s to start", "warning", 9.5), ("Session created", "info", 10.0),
        ]
        let entries = lines.enumerated().map { offset, line in
            LogEntry(id: session.id * 100 + offset, content: line.0, level: line.1, createdAt: now.addingTimeInterval(-line.2 * 60))
        }
        return LogPage(entries: page == 1 ? entries : [], hasMore: false)
    }

    public func subagentTranscripts(_ id: Int) async throws -> [SubagentTranscriptSummary] {
        _ = try find(id)
        guard id == 1042 else { return [] }
        return [SubagentTranscriptSummary(id: 7, label: "Explore: find the CarPlay entry points", subagentType: "Explore",
                                          status: "completed", messageCount: 4, duration: "1m 12s", tokens: "18.4k")]
    }

    public func subagentTranscript(_ id: Int, transcript: Int) async throws -> [ConversationMessage] {
        _ = try find(id)
        guard transcript == 7 else { throw ZimmerError.http(status: 404, message: "The requested resource was not found") }
        return [
            ConversationMessage(id: 0, role: .user, content: "Find where the app declares its scenes."),
            ConversationMessage(id: 1, role: .assistant, content: "Using tool: Grep", hasToolUse: true),
            ConversationMessage(id: 2, role: .assistant, content: "Scenes are declared in Info.plist under UIApplicationSceneManifest; ZimmerApp.swift has the one WindowGroup."),
        ]
    }

    public func detachUncle(_ junior: Int, uncle: Int) async throws {
        _ = try find(junior)
        guard uncles[junior]?.contains(uncle) == true else {
            throw ZimmerError.http(status: 404, message: "Session \(uncle) is not a senior of session \(junior)")
        }
        uncles[junior]?.removeAll { $0 == uncle }
    }

    private func queued(_ id: Int) throws -> [QueuedMessage] {
        _ = try find(id)
        return (queues[id] ?? []).sorted { $0.position < $1.position }
    }

    private static func renumbered(_ list: [QueuedMessage]) -> [QueuedMessage] {
        list.enumerated().map { offset, message in
            var message = message
            message.position = offset + 1
            return message
        }
    }

    /// The running CarPlay session has two messages waiting for its turn to end.
    static func sampleQueues() -> [Int: [QueuedMessage]] {
        [1042: [
            QueuedMessage(id: 501, content: "Also add a Siri shortcut for \"what needs me\".", position: 1),
            QueuedMessage(id: 502, content: "Then open a draft PR.", position: 2),
        ]]
    }
}

// MARK: - The new-session form and a session's catalog artifacts
//
// As the server: a session starts on a known root with that root's defaults for anything
// not chosen, a model must be one its runtime lists, and an artifact must be in its catalog.
extension FakeZimmerAPI {
    public func configs() async throws -> AppConfigs {
        Self.sampleConfigs
    }

    public func catalog(_ kind: CatalogKind) async throws -> [CatalogItem] {
        Self.sampleCatalogs[kind] ?? []
    }

    public func createSession(_ request: NewSessionRequest) async throws -> SessionSummary {
        guard let root = Self.sampleConfigs.agentRoots.first(where: { $0.name == request.agentRoot }) else {
            throw ZimmerError.http(status: 422, message: "Agent root '\(request.agentRoot)' not found in catalog")
        }
        let runtime = request.runtime ?? root.defaultRuntime ?? "claude_code"
        let model = request.model ?? root.defaultModel ?? Self.sampleConfigs.runtimeModels[runtime]?.default
        let text = request.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let id = all.map(\.id).max().map { $0 + 1 } ?? 1
        var session = SessionSummary(
            id: id, title: request.title.flatMap { $0.isEmpty ? nil : $0 } ?? (text.count > 60 ? String(text.prefix(57)) + "…" : text),
            status: text.isEmpty ? .needsInput : .waiting, agentRuntime: runtime, prompt: text,
            createdAt: Date(), updatedAt: Date(), goal: request.goal,
            priorityClass: request.schedulingClass ?? "priority", model: model, agentRoot: root.name
        )
        for kind in CatalogKind.allCases {
            let chosen = request.selections[kind] ?? kind.defaults(of: root)
            session.setSelection(kind, chosen)
        }
        all.append(session)
        return session
    }

    public func updateModel(_ id: Int, model: String) async throws -> SessionSummary {
        let session = try find(id)
        let runtime = session.agentRuntime ?? "claude_code"
        guard Self.sampleConfigs.models(for: runtime).contains(where: { $0.id == model }) else {
            throw ZimmerError.http(status: 422, message: "\(model) is not a model for \(runtime)")
        }
        return try change(id) { $0.config = SessionConfig(model: model) }
    }

    public func updateSelection(_ id: Int, _ kind: CatalogKind, to values: [String]) async throws -> SelectionChange {
        let known = Set((Self.sampleCatalogs[kind] ?? []).map(\.id))
        if let unknown = values.first(where: { !known.contains($0) }) {
            throw ZimmerError.http(status: 422, message: "\(unknown) is not in the \(kind.label.lowercased()) catalog")
        }
        let session = try change(id) { $0.setSelection(kind, values) }
        // Slack is the fixture's server that needs authorizing.
        return SelectionChange(session: session, needsAuthorizing: kind == .mcpServers && values.contains("slack") ? ["slack"] : [])
    }

    static let sampleConfigs = AppConfigs(
        agentRoots: [
            AgentRootOption(name: "zimmer", displayName: "Zimmer", description: "The Zimmer Rails app and its iOS app.", isDefault: true,
                            defaultRuntime: "claude_code", defaultModel: "opus", defaultGoal: "open-reviewed-green-pr",
                            defaultMcpServers: ["playwright-custom"], defaultSkills: ["open-pr", "wait-for-ci"]),
            AgentRootOption(name: "zimmer-orchestrator", displayName: "Zimmer orchestrator", description: "Plans and routes work across roots.",
                            defaultRuntime: "claude_code", defaultModel: "opus"),
            AgentRootOption(name: "internal-only", userInvocable: false),
        ],
        runtimeModels: [
            "claude_code": RuntimeModels(default: "opus", models: [
                ModelOption(id: "opus", label: "Opus", effortLevels: ["low", "medium", "high", "xhigh", "max"], defaultEffort: "high"),
                ModelOption(id: "sonnet", label: "Sonnet", effortLevels: ["low", "medium", "high"], defaultEffort: "medium"),
            ]),
            "codex": RuntimeModels(default: "gpt-5.6-sol", models: [ModelOption(id: "gpt-5.6-sol", label: "GPT-5.6 Sol")]),
        ],
        goals: [
            GoalOption(id: "open-reviewed-green-pr", name: "Open a reviewed, green PR", description: "Unmerged PR is open and CI is green."),
            GoalOption(id: "answer-question", name: "Answer a question"),
        ],
        mcpServers: [CatalogItem(id: "playwright-custom", title: "Playwright"), CatalogItem(id: "slack", title: "Slack", unavailableReason: "Needs authorizing")]
    )

    static let sampleCatalogs: [CatalogKind: [CatalogItem]] = [
        .mcpServers: sampleConfigs.mcpServers,
        .skills: [CatalogItem(id: "open-pr", title: "Open a PR"), CatalogItem(id: "wait-for-ci", title: "Wait for CI"),
                  CatalogItem(id: "zimmer-qa-mobile-screens", title: "QA mobile screens")],
        .hooks: [CatalogItem(id: "block-force-push", title: "Block force-push")],
        .plugins: [CatalogItem(id: "screenshots-videos", title: "Screenshots and videos")],
    ]
}

extension SessionSummary {
    /// Set what the session has chosen of one kind.
    public mutating func setSelection(_ kind: CatalogKind, _ values: [String]) {
        switch kind {
        case .mcpServers: mcpServers = values
        case .skills: catalogSkills = values
        case .hooks: catalogHooks = values
        case .plugins: catalogPlugins = values
        }
    }
}

// MARK: - Inbox, triggers, costs and health
//
// As the server: an unread notification cannot be dismissed, and invoking a disabled
// trigger is refused.
extension FakeZimmerAPI {
    public func notifications() async throws -> [InboxNotification] { inbox }

    public func unreadNotificationCount() async throws -> Int { inbox.filter { !$0.read }.count }

    public func markNotificationRead(_ id: Int) async throws -> InboxNotification {
        guard let index = inbox.firstIndex(where: { $0.id == id }) else { throw ZimmerError.http(status: 404, message: "The requested resource was not found") }
        inbox[index].read = true
        return inbox[index]
    }

    public func markAllNotificationsRead() async throws {
        for index in inbox.indices { inbox[index].read = true }
    }

    public func dismissNotification(_ id: Int) async throws {
        guard let notification = inbox.first(where: { $0.id == id }) else { throw ZimmerError.http(status: 404, message: "The requested resource was not found") }
        guard notification.read else { throw ZimmerError.http(status: 422, message: "Cannot dismiss unread notification") }
        inbox.removeAll { $0.id == id }
    }

    public func dismissAllReadNotifications() async throws {
        inbox.removeAll(where: \.read)
    }

    public func triggers() async throws -> [TriggerSummary] { triggerList }

    public func toggleTrigger(_ id: Int) async throws -> TriggerSummary {
        guard let index = triggerList.firstIndex(where: { $0.id == id }) else { throw ZimmerError.http(status: 404, message: "The requested resource was not found") }
        triggerList[index].status = triggerList[index].isEnabled ? "disabled" : "enabled"
        return triggerList[index]
    }

    public func invokeTrigger(_ id: Int) async throws -> TriggerInvocation {
        guard let trigger = triggerList.first(where: { $0.id == id }) else { throw ZimmerError.http(status: 404, message: "The requested resource was not found") }
        // A disabled trigger can still be fired by hand, as the server allows.
        let started = try await startQuickRouter("\(trigger.name): run now")
        return TriggerInvocation(sessionID: started, message: "Trigger '\(trigger.name)' fired: session \(started) started")
    }

    public func costs(days: Int) async throws -> CostSnapshot {
        let now = Date()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let spend = [41.2, 55.0, 38.7, 62.3, 70.1, 48.9, 53.4]
        let daysShown = spend.enumerated().map { offset, cost in
            CostSnapshot.Day(day: formatter.string(from: now.addingTimeInterval(Double(offset - spend.count + 1) * 86_400)), costUSD: cost)
        }
        return CostSnapshot(
            from: now.addingTimeInterval(-Double(days) * 86_400), to: now, totalUSD: spend.reduce(0, +), days: daysShown,
            agentRoots: [.init(label: "zimmer", costUSD: 201.4), .init(label: "zimmer-orchestrator", costUSD: 88.2), .init(label: "motet", costUSD: 80.0)],
            models: [.init(label: "opus", costUSD: 330.1), .init(label: "sonnet", costUSD: 39.5)],
            topSessions: [.init(sessionID: 1042, costUSD: 23.81, tokens: 1_204_331), .init(sessionID: 1038, costUSD: 17.02, tokens: 880_120)]
        )
    }

    public func health() async throws -> HealthReport {
        HealthReport(
            overall: .init(key: "overall", status: "warning", message: "One or more warnings detected"),
            sections: [
                .init(key: "auth_health", status: "healthy"),
                .init(key: "cron_health", status: "healthy"),
                .init(key: "process_health", status: "healthy"),
                .init(key: "session_health", status: "warning", message: "Failure rate 12% over the last day"),
                .init(key: "system_health", status: "healthy"),
            ],
            generatedAt: Date()
        )
    }

    static func sampleNotifications(now: Date = Date()) -> [InboxNotification] {
        [
            InboxNotification(id: 91, type: "needs_input", read: false, createdAt: now.addingTimeInterval(-6 * 60),
                              session: .init(id: 1038, title: "PR #1261 is green and ready — merge it?", status: .needsInput)),
            InboxNotification(id: 90, type: "session_failed", read: false, createdAt: now.addingTimeInterval(-180 * 60),
                              session: .init(id: 1027, title: "Rotate the staging deploy key", status: .failed)),
            InboxNotification(id: 88, type: "session_complete", read: true, createdAt: now.addingTimeInterval(-1_400 * 60),
                              session: .init(id: 1019, title: "Fix the flaky transcript poller test", status: .archived)),
        ]
    }

    static func sampleTriggers(now: Date = Date()) -> [TriggerSummary] {
        [
            TriggerSummary(id: 5, name: "Nightly dependency sweep", status: "enabled", agentRoot: "zimmer",
                           lastTriggeredAt: now.addingTimeInterval(-20 * 60), lastSessionID: 1031, sessionsCreated: 31,
                           conditions: [.init(type: "schedule", description: "Every day at 02:00 UTC")]),
            TriggerSummary(id: 6, name: "Slack #zimmer mentions", status: "disabled", agentRoot: "zimmer-orchestrator",
                           sessionsCreated: 4, conditions: [.init(type: "slack", description: "@zimmer in #zimmer")]),
        ]
    }
}

// MARK: - Attachments
//
// As the server: too many, or an image over its limit, refuses the whole message; the
// rest go with it however it is delivered, and the conversation names them.
extension FakeZimmerAPI {
    public func followUp(_ id: Int, prompt: String, attachments: [MessageAttachment], now: Bool) async throws -> FollowUpResult {
        var accepted: [MessageAttachment] = []
        for attachment in attachments {
            if let refusal = MessageAttachment.refusal(adding: attachment, to: accepted) {
                throw ZimmerError.http(status: 422, message: refusal)
            }
            accepted.append(attachment)
        }
        let named = attachments.isEmpty ? prompt : prompt + "\n\n📎 " + attachments.map(\.filename).joined(separator: ", ")
        let result = now ? try await sendNow(id, prompt: named) : try await followUp(id, prompt: named)
        sentAttachments[id, default: []].append(attachments)
        return result
    }
}

// MARK: - Prompts and forks
//
// As the server: an answer resolves the prompt, so it leaves the list, and a fork is a new
// session in `needs_input` holding the conversation up to the message it was made at.
extension FakeZimmerAPI {
    public func pendingElicitations(_ id: Int) async throws -> [PendingElicitation] {
        _ = try find(id)
        return prompts[id] ?? []
    }

    public func answerElicitation(_ elicitation: Int, answer: ElicitationAnswer, content: String?) async throws {
        guard let owner = prompts.first(where: { $0.value.contains { $0.id == elicitation } })?.key else {
            throw ZimmerError.http(status: 404, message: "Elicitation not found for: \(elicitation)")
        }
        prompts[owner]?.removeAll { $0.id == elicitation }
        if prompts[owner]?.isEmpty ?? true, let index = all.firstIndex(where: { $0.id == owner }) {
            all[index].status = answer == .cancel ? .needsInput : .running
        }
    }

    public func fork(_ id: Int, at transcriptIndex: Int) async throws -> SessionSummary {
        let source = try find(id)
        let history = try await conversation(id).messages
        guard history.contains(where: { $0.transcriptIndex == transcriptIndex }) else {
            throw ZimmerError.http(status: 422, message: "Message index \(transcriptIndex) is out of range")
        }
        let forkID = nextID
        nextID += 1
        let forked = SessionSummary(id: forkID, title: "Fork of \(source.title ?? "#\(source.id)")", status: .needsInput,
                                    agentRuntime: source.agentRuntime, prompt: source.prompt, createdAt: Date(), updatedAt: Date())
        all.append(forked)
        conversations[forkID] = history.filter { ($0.transcriptIndex ?? 0) <= transcriptIndex }
        return forked
    }

    static func samplePrompts() -> [Int: [PendingElicitation]] {
        [1035: [PendingElicitation(
            id: 71,
            requestID: "req-staging-migrate",
            message: "Run the pending migrations against staging?",
            toolName: "run_migrations",
            context: "3 migrations, the largest backfills 2.1M rows.",
            expiresAt: Date().addingTimeInterval(50 * 60),
            form: ElicitationForm(fields: [
                .init(key: "database", title: "Database", kind: .choice(["staging", "staging-replica"]), required: true),
                .init(key: "batch_size", title: "Batch size", detail: "Rows per backfill batch.", kind: .number(integer: true), placeholder: "1000"),
                .init(key: "dry_run", title: "Dry run", kind: .toggle),
            ])
        )]]
    }
}
