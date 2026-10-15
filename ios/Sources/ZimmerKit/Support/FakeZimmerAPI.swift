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
    /// The sessions each trigger has made, oldest first.
    private var triggerSessions: [Int: [Int]] = [5: [1031]]
    /// What each follow-up carried, newest last, so a test can see attachments arrive.
    public private(set) var sentAttachments: [Int: [[MessageAttachment]]] = [:]
    /// Every Quick Router start, in order, so a test can see what went with the words.
    public private(set) var quickRouterRequests: [QuickRouterRequest] = []
    public private(set) var registeredDevices: [String: APNsEnvironment] = [:]
    private let live: Bool
    private var conversationReads: [Int: Int] = [:]
    /// Made once, from the `now` the fake starts with: a session read twice is the same session,
    /// as on the server, so a page that reads again sees nothing to redraw.
    private let humanMessages: [Int: [HumanMessage]]
    /// The sweep (1031) is held by the spot gate for quota headroom.
    private var spotHeld: Set<Int> = [1031]
    /// The changelog (1029) has been handed a turn and is waiting for a worker thread.
    private var queuedTurns: Set<Int> = [1029]
    /// The Postgres question (1035) has a renewed Linear grant its agent has not picked up.
    private var reconnectServers: [Int: [String]] = [1035: ["Linear"]]
    /// …and a poller notice Zimmer retired before it was delivered.
    private var undelivered: [Int: [QueuedMessage]] = FakeZimmerAPI.sampleUndelivered()
    /// The class each session's genesis gives it: what *Derive it* goes back to. The samples
    /// choose no class of their own, so it is the class each starts with.
    private var derivedClasses: [Int: String]
    /// The Settings page's row, as `GET /api/v1/app_settings` answers it.
    private var appSettingsRow: AppSettings = FakeZimmerAPI.sampleAppSettings()
    /// The sign-in is a relay-only grant: the MCP Apps keys are refused, as the server
    /// refuses them before reading anything else.
    private let relayOnly: Bool
    /// The deployment's connections, as `GET /api/v1/oauth_grants` lists them: id 7 is this
    /// phone's, so a write that revokes it is a sign-out.
    private var grants: [OAuthGrant]
    /// The deployment's keys, as `GET /api/v1/api_keys` lists them.
    private var keys: [APIKey]
    private var nextKeyID = 3
    /// Set by `signOutEverywhere`: the grant this app signed in on is gone.
    public private(set) var signedOutEverywhere = false

    /// `live`: a running session's agent keeps talking, a line per read of its conversation
    /// after the first, so a screen that reads again can be seen to. `longTranscript`: 1044's
    /// conversation runs to a hundred messages, so its details card is far above the newest.
    /// `relayOnly`: the sign-in does not act as you, so a change to MCP Apps is a 403.
    public init(sessions: [SessionSummary] = FakeZimmerAPI.sampleSessions(), now: Date = Date(), live: Bool = false,
                longTranscript: Bool = false, relayOnly: Bool = false) {
        self.live = live
        self.relayOnly = relayOnly
        self.grants = FakeZimmerAPI.sampleGrants(now: now, relayOnly: relayOnly)
        self.keys = FakeZimmerAPI.sampleAPIKeys(now: now)
        self.all = sessions
        self.summaries = FakeZimmerAPI.sampleSummaries(now: now)
        self.conversations = FakeZimmerAPI.sampleConversations(now: now)
        self.derivedClasses = sessions.reduce(into: [:]) { $0[$1.id] = $1.priorityClass ?? "priority" }
        self.humanMessages = FakeZimmerAPI.sampleHumanMessages(now: now)
        if live {
            // Long enough to scroll back through, so following the end can be told from not.
            conversations[1042] = (0..<30).map { index in
                ConversationMessage(id: index, role: index.isMultiple(of: 2) ? .assistant : .user,
                                    content: "Earlier step \(index) of the CarPlay scene.", timestamp: now.addingTimeInterval(Double(index - 30) * 60))
            }
        }
        if longTranscript, let sample = conversations[1044] {
            // The sample's opening request first, then steps of work, then the sample's tail.
            let steps = (0..<92).map { index in
                let tool = index.isMultiple(of: 3)
                return ConversationMessage(
                    id: index + 1, role: .assistant,
                    content: tool
                        ? "Using tool: Bash\nswift test --filter Slice\(index / 3 + 1)"
                        : "Step \(index + 1) of the parity audit: the session page's \(index.isMultiple(of: 2) ? "header and its chips" : "details card and its rows") checked against the PWA on a phone.",
                    timestamp: now.addingTimeInterval(-Double(2_990 - index) * 60), hasToolUse: tool)
            }
            let tail = sample.dropFirst().enumerated().map { offset, message in
                var message = message
                message.id = steps.count + 1 + offset
                return message
            }
            conversations[1044] = [sample[0]] + steps + tail
        }
        // Past every session the fake can open, the family 1045–1049 included, so a new one
        // never takes an id an existing page answers to.
        self.nextID = max((sessions.map(\.id).max() ?? 0) + 1, 1100)
    }

    public func sessions(_ filter: SessionFilter) async throws -> [SessionSummary] {
        SessionOrdering.sorted(all.filter(filter.filters.admits))
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
        let session = try find(id)
        // As the server: a check reads back the catalog goal the session has now, so a goal
        // changed to another (or to free text) takes the check with it.
        let check = Self.sampleGoalChecks()[id].flatMap { check in
            Self.sampleConfigs.goal(matching: session.goal)?.id == check.goalID ? check : nil
        }
        return SessionDetail(session: session, statusSummary: summaries[id], hierarchy: hierarchy,
                             goalCheck: check, humanMessages: humanMessages[id] ?? [],
                             captureGaps: Self.sampleCaptureGaps()[id] ?? [], waiting: waiting(for: session))
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
        let all = conversations[id] ?? []
        let window = min(max(limit, 1), Conversation.maxLimit)
        return Conversation(messages: Array(all.suffix(window)), total: all.count, truncated: all.count > window)
    }

    public func earlierMessages(_ id: Int, before: Int, limit: Int) async throws -> Conversation {
        _ = try find(id)
        let all = conversations[id] ?? []
        let end = min(max(before, 0), all.count)
        let start = max(end - min(max(limit, 1), Conversation.maxLimit), 0)
        return Conversation(messages: Array(all[start..<end]), total: all.count, truncated: start > 0, firstPosition: start)
    }

    /// As the server: opening a session marks its notifications read.
    public func openSession(_ id: Int) async throws -> SessionDetail {
        let detail = try await session(id)
        markRead(session: id)
        return detail
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
            // The next agent process loads the renewed grant, as the server's does.
            reconnectServers[id] = nil
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
        // The server holds the clone for `TRASH_RETENTION_PERIOD`, four days, for a restore.
        session.trashAfter = Date().addingTimeInterval(4 * 86_400)
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
        // The rest of 1044's family is on no board the fixture draws, but opens from its
        // hierarchy and its goal check as any session does.
        guard let session = all.first(where: { $0.id == id }) ?? Self.sampleFamily().first(where: { $0.id == id }) else {
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
        return wired(ran(trashed([
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
                           // Free text, not a catalog goal: the page shows the words themselves.
                           goal: "Recommend the Postgres version staging should run, with the trade-offs either way.",
                           priorityClass: "spot", precedence: 20, lastUserActivityAt: ago(3)),
            SessionSummary(id: 1031, title: "Nightly dependency sweep", status: .waiting,
                           agentRuntime: "claude_code", createdAt: ago(20), updatedAt: ago(20),
                           priorityClass: "spot", precedence: 50, genesis: "schedule"),
            SessionSummary(id: 1029, title: "Draft the October changelog", status: .waiting,
                           agentRuntime: "claude_code", createdAt: ago(900), updatedAt: ago(800),
                           visibility: .snoozed, snoozedUntil: now.addingTimeInterval(20 * 3600)),
            failed(SessionSummary(id: 1027, title: "Rotate the staging deploy key", status: .failed,
                                  agentRuntime: "claude_code", createdAt: ago(600), updatedAt: ago(180),
                                  priorityClass: "spot", precedence: 10, agentRoot: "zimmer-production",
                                  pullRequests: [PullRequestLink(url: URL(string: "https://github.com/tadasant/zimmer/pull/1288")!, state: "open", ci: "fail")])),
            // The richest session: a long title, four PRs, a catalog goal with a long
            // description (stored as its id), notes, a wide hierarchy, three MCP servers (one
            // failed), a long conversation. What the detail screen has to stay legible on.
            SessionSummary(id: 1044, title: "Audit the iOS app for parity with the PWA, then implement the findings as a series of standalone slices — quick router and the detail page first",
                           status: .needsInput, agentRuntime: "claude_code", createdAt: ago(3_000), updatedAt: ago(9),
                           goal: "open-reviewed-green-pr",
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
        ])))
    }

    /// The MCP servers the web UI draws a connection chip for: 1038's chosen server, the one
    /// its plugin brings and the injected self-session server, all connected; 1044's three, one of them failed with
    /// the poller's error and the injected one not reached yet. And 1035's skills, which its
    /// composer's "/" offers.
    private static func wired(_ sessions: [SessionSummary]) -> [SessionSummary] {
        sessions.map { session in
            var session = session
            switch session.id {
            case 1035:
                session.catalogSkills = ["open-pr", "wait-for-ci", "zimmer-qa-mobile-screens"]
            case 1038:
                // Its plugin brings a server of its own, which the editor cannot remove.
                session.mcpServers = ["playwright-custom"]
                session.catalogPlugins = ["screenshots-videos"]
                session.allMcpServers = ["playwright-custom", "remote-fs-screenshots", "zimmer-self-session"]
                session.injectedMcpServers = ["zimmer-self-session"]
                session.customMetadata = SessionCustomMetadata(pullRequests: session.pullRequests, mcpServerStatuses: [
                    "playwright-custom": McpServerStatus(status: "connected"),
                    "remote-fs-screenshots": McpServerStatus(status: "connected"),
                    "zimmer-self-session": McpServerStatus(status: "connected"),
                ])
            case 1044:
                session.mcpServers = ["playwright-custom", "linear"]
                session.allMcpServers = ["playwright-custom", "linear", "zimmer-self-session"]
                session.injectedMcpServers = ["zimmer-self-session"]
                session.customMetadata = SessionCustomMetadata(pullRequests: session.pullRequests, mcpServerStatuses: [
                    "playwright-custom": McpServerStatus(status: "connected"),
                    "linear": McpServerStatus(status: "failed", error: "OAuth token expired: 401 Unauthorized from the Linear MCP server"),
                ])
            default:
                break
            }
            return session
        }
    }

    /// The rest of 1044's family, which no board in the fixture lists: the router that
    /// spawned it, on a catalog goal judged on 1044's PRs, and the slices 1044 spawned.
    static func sampleFamily(now: Date = Date()) -> [SessionSummary] {
        func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }
        let children: [(Int, String, SessionStatus)] = [
            (1045, "Slice 1: the Quick Router on every screen", .archived),
            (1046, "Slice 2: the session page's density", .running),
            (1047, "Slice 3: the board's rows", .waiting),
            (1048, "Fresh-eyes review of #1293", .archived),
            (1049, "Fresh-eyes review of #1294", .failed),
        ]
        let router = SessionSummary(id: 1040, title: "Route: iOS parity audit and slices", status: .archived, agentRuntime: "claude_code",
                                    createdAt: ago(3_020), updatedAt: ago(2_990), archivedAt: ago(2_990), goal: "open-reviewed-green-pr",
                                    priorityClass: "priority", agentRoot: "zimmer-orchestrator")
        return [router] + children.map { id, title, status in
            SessionSummary(id: id, title: title, status: status, agentRuntime: "claude_code", createdAt: ago(2_000), updatedAt: ago(60),
                           archivedAt: status == .archived ? ago(60) : nil, priorityClass: "spot", agentRoot: "zimmer")
        }
    }

    /// Every sample but the sweep (1031, held at the starting line) has had its agent launch,
    /// so a restart from Needs input continues its conversation rather than starting over.
    private static func ran(_ sessions: [SessionSummary]) -> [SessionSummary] {
        sessions.map { session in
            var session = session
            if session.id != 1031 { session.runtimeSessionID = "fixture-\(session.id)" }
            return session
        }
    }

    /// The trashed sample keeps its clone for a restore, until four days after it was trashed.
    private static func trashed(_ sessions: [SessionSummary]) -> [SessionSummary] {
        sessions.map { session in
            var session = session
            if session.status == .archived, let archivedAt = session.archivedAt {
                session.trashAfter = archivedAt.addingTimeInterval(4 * 86_400)
            }
            return session
        }
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
            // A fresh-eyes review as agents write them: headings, a fenced block, a nested
            // list, a table, a quote, and a bare signed URL beside a written link. What the
            // transcript's markdown has to draw.
            1048: [
                ConversationMessage(id: 0, role: .user, content: "Review #1293 with fresh eyes.", timestamp: ago(120)),
                ConversationMessage(id: 1, role: .assistant, content: "## Review of #1293\n\nOne finding is **blocking**; the rest are *nits*.\n\n### The corner button covers Send\n\nOn a small phone `quickRouterCorner()` sits over the composer:\n\n```swift\n.overlay(alignment: .bottomTrailing) { QuickRouterButton() }\n```\n\n- Lift it above the safe area\n  - as the web does\n- Re-shoot both appearances\n\n| Check | Result |\n| --- | --- |\n| Build | pass |\n| UI tests | 2 failed |\n\n> Fix the overlay first; the nits can wait.\n\nThe screenshot is https://files.example.com/pr-1293/composer.png?X-Amz-Signature=4f2c9a and [the diff](https://github.com/tadasant/zimmer/pull/1293/files) has the rest.", timestamp: ago(60)),
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

    /// `goal_check` as the server writes it for a catalog goal with criteria. The router
    /// (1040) recorded no PR of its own, so it is judged on the PRs of 1044, which it spawned.
    static func sampleGoalChecks() -> [Int: GoalCheck] {
        let note = "Advisory only: nothing acts on this. It covers only what Zimmer records and reads from GitHub. Anything else the goal asks for, such as a review, a skill, or a screenshot, is still the agent's word."
        return [
            1044: GoalCheck(goalID: "open-reviewed-green-pr", goalName: "Open Reviewed Green PR", verdict: "pending", provisional: false, criteria: [
                GoalCheck.Criterion(key: "pull_request_open", label: "A pull request is open or merged", status: "met", detail: "#1282 is open"),
                GoalCheck.Criterion(key: "ci_green", label: "CI is green", status: "pending", detail: "pending on #1283"),
                GoalCheck.Criterion(key: "verification_section", label: "PR description has a Verification section", status: "met"),
                GoalCheck.Criterion(key: "ready_to_merge_label", label: "Label \"ready to merge\" applied", status: "unknown"),
            ], note: note),
            1040: GoalCheck(goalID: "open-reviewed-green-pr", goalName: "Open Reviewed Green PR", verdict: "pending", criteria: [
                GoalCheck.Criterion(key: "pull_request_open", label: "A pull request is open or merged", status: "met", detail: "#1282 is open"),
                GoalCheck.Criterion(key: "ci_green", label: "CI is green", status: "pending", detail: "pending on #1283"),
            ], delegatedSessionIDs: [1044], note: note),
            1038: GoalCheck(goalID: "open-reviewed-green-pr", goalName: "Open Reviewed Green PR", verdict: "met", criteria: [
                GoalCheck.Criterion(key: "pull_request_open", label: "A pull request is open or merged", status: "met", detail: "#1261 is open"),
                GoalCheck.Criterion(key: "ci_green", label: "CI is green", status: "met", detail: "pass on #1261"),
            ], note: note),
        ]
    }

    /// `human_messages` as the server writes them: what people said, through which channel,
    /// and whether to this session or to another in its family.
    static func sampleHumanMessages(now: Date = Date()) -> [Int: [HumanMessage]] {
        func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }
        let asked = "Zimmer iOS still doesn't have parity with PWA. Do an extensive audit for parity and design, then implement it as a series of standalone slices."
        let carryOn = "Carry on. Screenshots with real data on every slice."
        return [
            1044: [
                HumanMessage(author: "Tadas", channelLabel: "Zimmer web UI", authoredInSessionID: 1040, content: asked, occurredAt: ago(3_010),
                             origin: .elsewhere, authoredIn: "session #1040 — Route: iOS parity audit and slices"),
                HumanMessage(author: "Tadas", channelLabel: "Zimmer web UI", authoredInSessionID: 1044, content: carryOn, occurredAt: ago(1_380),
                             origin: .here, authoredIn: "this session (#1044)"),
            ],
            1040: [
                HumanMessage(author: "Tadas", channelLabel: "Zimmer web UI", authoredInSessionID: 1040, content: asked, occurredAt: ago(3_010),
                             origin: .here, authoredIn: "this session (#1040)"),
                HumanMessage(author: "Tadas", channelLabel: "Zimmer web UI", authoredInSessionID: 1044, content: carryOn, occurredAt: ago(1_380),
                             origin: .elsewhere, authoredIn: "session #1044 — Audit the iOS app for parity with the PWA"),
            ],
            1038: [
                HumanMessage(author: "Tadas", channelLabel: "Zimmer web UI", authoredInSessionID: 1038, content: "Open a PR for the iOS scaffold and get CI green.", occurredAt: ago(240),
                             origin: .here, authoredIn: "this session (#1038)"),
            ],
        ]
    }

    /// `human_message_capture_gaps`: 1044's router came in over Slack, and no roster row maps
    /// a Slack user, so the counts on that family are a floor.
    static func sampleCaptureGaps() -> [Int: [HumanMessageCaptureGap]] {
        let slack = HumanMessageCaptureGap(
            channel: "slack", channelLabel: "Slack", genesis: "slack", sessionIDs: [1040],
            reason: "No row in this deployment's roster maps any Slack user ID, so every Slack message resolved to nobody and recorded nothing — whoever sent it.",
            remedy: "Fill in the human's Slack user ID at /supervisor/users. It is a row edit, not a deploy."
        )
        return [1044: [slack], 1040: [slack]]
    }
}

// MARK: - Session actions
//
// In this file because an extension here can read the actor's private state. Each behaves
// as the server does where the app depends on it: a pause needs a running session, a
// restart a failed or needs-input one, a restore a trashed one; a blank title clears it.
extension FakeZimmerAPI {
    /// As the server: every filter narrows, together.
    public func sessions(_ filters: BoardFilters, board: BoardFilter) async throws -> SessionSearchResult {
        SessionSearchResult(sessions: SessionOrdering.sorted(all.filter { filters.admits($0) && board.admits($0) }))
    }

    public func search(_ query: String, contents: Bool, filters: BoardFilters, board: BoardFilter) async throws -> SessionSearchResult {
        let needle = query.lowercased()
        let matches = try await sessions(filters, board: board).sessions.filter { session in
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
        reconnectServers[id] = nil
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
            $0.trashAfter = nil
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
            session.schedulingClass = session.priorityClass
            // Promoting a waiting session starts it, as the server's PATCH does.
            if starts { session.status = .running }
        }
        return SchedulingChange(session: session, startOutcome: starts ? "started" : nil,
                                startMessage: starts ? "Session \(id)'s next turn is due now: resumed from the spot queue." : nil)
    }

    /// *Derive it* goes back to the genesis's class; a waiting session the change makes
    /// priority starts, as the server's PATCH starts one on any change into priority.
    public func setSchedulingClass(_ id: Int, to choice: SchedulingClassChoice) async throws -> SchedulingChange {
        let current = try find(id)
        let chosen = choice == .derive ? nil : choice.rawValue
        let effective = chosen ?? derivedClasses[id] ?? "priority"
        let starts = effective == "priority" && current.status == .waiting && !current.isPriority
        let session = try change(id) { session in
            session.schedulingClass = chosen
            session.priorityClass = effective
            if starts { session.status = .running }
        }
        return SchedulingChange(session: session, startOutcome: starts ? "started" : nil,
                                startMessage: starts ? "Session \(id)'s next turn is due now: resumed from the spot queue." : nil)
    }

    /// As `SessionPrecedence`: an integer within a billion either way.
    public func setPrecedence(_ id: Int, _ precedence: Int) async throws -> SessionSummary {
        guard (-1_000_000_000...1_000_000_000).contains(precedence) else {
            let bound = precedence > 0 ? "less than or equal to 1000000000" : "greater than or equal to -1000000000"
            throw ZimmerError.http(status: 422, message: "Precedence must be \(bound)")
        }
        return try change(id) { $0.precedence = precedence }
    }

    public func setHeartbeat(_ id: Int, enabled: Bool) async throws -> SessionSummary {
        try change(id) { $0.heartbeatEnabled = enabled }
    }

    /// As `Sessions::UpdateHeartbeat`: 30 seconds to a day, and on or off is left as it is.
    public func setHeartbeatInterval(_ id: Int, seconds: Int) async throws -> SessionSummary {
        guard (30...86_400).contains(seconds) else {
            throw ZimmerError.http(status: 422, message: "Heartbeat interval seconds must be between 30 and 86400")
        }
        return try change(id) { $0.heartbeatIntervalSeconds = seconds }
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
        if (1040...1049).contains(id), id != 1042 {
            let family: [(Int, String, SessionStatus, Int)] = [
                (1040, "Route: iOS parity audit and slices", .archived, 0),
                (1044, "Audit the iOS app for parity with the PWA, then implement the findings as a series of standalone slices — quick router and the detail page first", .needsInput, 1),
                (1045, "Slice 1: the Quick Router on every screen", .archived, 2),
                (1046, "Slice 2: the session page's density", .running, 2),
                (1047, "Slice 3: the board's rows", .waiting, 2),
                (1048, "Fresh-eyes review of #1293", .archived, 2),
                (1049, "Fresh-eyes review of #1294", .failed, 2),
            ]
            // The router came in over Slack and runs priority; what it spawned is spot. The
            // review of #1294 was reached through a senior rather than a spawn edge, so it is
            // drawn under 1044, which did not spawn it.
            return SessionHierarchy(nodes: family.map { nodeID, title, status, depth in
                SessionHierarchy.Node(id: nodeID, title: title, agentRoot: depth == 0 ? "zimmer-orchestrator" : "zimmer", status: status, depth: depth,
                                      current: nodeID == id, genesis: "slack", priorityClass: depth == 0 ? "priority" : "spot",
                                      renderParentID: depth == 0 ? nil : (depth == 1 ? 1040 : 1044), spawnEdge: nodeID != 1049)
            }, originID: 1040, rootIDs: [1040])
        }
        let tree = [(1038, 0), (1042, 1), (1031, 1)]
        guard tree.contains(where: { $0.0 == id }) else { return SessionHierarchy(nodes: []) }
        return SessionHierarchy(nodes: tree.compactMap { nodeID, depth in
            guard let session = sessions.first(where: { $0.id == nodeID }) else { return nil }
            return SessionHierarchy.Node(id: nodeID, title: session.title, agentRoot: "zimmer", status: session.status, depth: depth, current: nodeID == id,
                                         genesis: "web_ui", priorityClass: session.priorityClass, renderParentID: depth == 0 ? nil : 1038)
        }, originID: 1038, rootIDs: [1038])
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
    public func sessions(_ filters: BoardFilters, board: BoardFilter, view: BoardView) async throws -> SessionSearchResult {
        var rows = try await sessions(filters, board: board).sessions
        if view == .yourBoard || view == .ranked {
            rows = rows.map { session in
                var session = session
                session.boardRow = BoardRow(agentRoot: session.agentRoot, statusSummary: summaries[session.id])
                return session
            }
        }
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
        // As the server: only a live spot session counts as a neighbour.
        func neighbour(_ id: Int?) -> Int? {
            guard let id, let row = all.first(where: { $0.id == id }), !row.isPriority, row.status != .archived else { return nil }
            return row.precedence ?? 0
        }
        let upper = neighbour(above)
        let lower = neighbour(below)
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

    public func undeliveredMessages(_ id: Int) async throws -> [QueuedMessage] {
        _ = try find(id)
        return (undelivered[id] ?? []).sorted { $0.position < $1.position }
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

    /// A poller notice to the Postgres question that Zimmer retired as stale: the PR it
    /// reported on had moved on by the time the session could take it.
    static func sampleUndelivered(now: Date = Date()) -> [Int: [QueuedMessage]] {
        [1035: [
            QueuedMessage(id: 497, content: "PR #1297's CI went green while you were waiting on an answer.", position: 1,
                          status: "undelivered", origin: "automated_pr_poller", createdAt: now.addingTimeInterval(-50 * 60)),
        ]]
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
            GoalOption(id: "open-reviewed-green-pr", name: "Open Reviewed Green PR", description: "Unmerged PR is open and CI is green."),
            GoalOption(id: "codebase-question", name: "Codebase Question",
                       description: "Research the codebase thoroughly to answer the user's question, and report your findings inline in the conversation."),
        ],
        mcpServers: [CatalogItem(id: "playwright-custom", title: "Playwright"), CatalogItem(id: "slack", title: "Slack", unavailableReason: "Needs authorizing")],
        geneses: [
            GenesisOption(key: "web_ui", label: "Zimmer web app"), GenesisOption(key: "slack", label: "Slack trigger"),
            GenesisOption(key: "whatsapp", label: "WhatsApp trigger"), GenesisOption(key: "email", label: "Email trigger"),
            GenesisOption(key: "github_issue", label: "GitHub issue trigger"), GenesisOption(key: "github_label", label: "GitHub label trigger"),
            GenesisOption(key: "schedule", label: "Scheduled trigger"), GenesisOption(key: "ao_event", label: "Session-state trigger"),
            GenesisOption(key: "system_event", label: "System-event trigger"), GenesisOption(key: "api", label: "API / agent spawn"),
            GenesisOption(key: "unknown", label: "Unknown"),
        ]
    )

    static let sampleCatalogs: [CatalogKind: [CatalogItem]] = [
        .mcpServers: sampleConfigs.mcpServers,
        // As `GET /api/v1/skills` lists them: the two workflow skills a person may invoke with
        // "/", and one only an agent invokes.
        .skills: [CatalogItem(id: "open-pr", title: "Open a PR", description: "Commit, push a branch, open the PR and wait for CI.",
                              name: "open-pr", userInvocable: true),
                  CatalogItem(id: "wait-for-ci", title: "Wait for CI", description: "Block until CI passes or fails on the current PR.",
                              name: "wait-for-ci", userInvocable: true),
                  CatalogItem(id: "zimmer-qa-mobile-screens", title: "QA mobile screens", description: "Render a changed screen at a phone's width.",
                              name: "zimmer-qa-mobile-screens", userInvocable: false)],
        .hooks: [CatalogItem(id: "block-force-push", title: "Block force-push")],
        .plugins: [CatalogItem(id: "screenshots-videos", title: "Screenshots and videos")],
    ]
}

extension SessionSummary {
    /// Set what the session has chosen of one kind.
    public mutating func setSelection(_ kind: CatalogKind, _ values: [String]) {
        switch kind {
        case .mcpServers:
            // The effective set follows the choice, with the injected ones and the ones a
            // plugin brings kept, as the server's.
            let kept = mcpConnections.filter { $0.injected || $0.fromPlugin }.map(\.name).filter { !values.contains($0) }
            mcpServers = values
            if allMcpServers != nil { allMcpServers = values + kept }
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

    func markRead(session: Int) {
        for index in inbox.indices where inbox[index].session?.id == session { inbox[index].read = true }
    }

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

    public func trigger(_ id: Int) async throws -> TriggerDetail {
        guard let trigger = triggerList.first(where: { $0.id == id }) else { throw ZimmerError.http(status: 404, message: "The requested resource was not found") }
        let recent = (triggerSessions[id] ?? []).reversed().prefix(10).compactMap { sessionID in
            all.first(where: { $0.id == sessionID }).map { TriggerDetail.RecentSession(id: $0.id, title: $0.title, status: $0.status, createdAt: $0.createdAt) }
        }
        return TriggerDetail(trigger: trigger, recentSessions: Array(recent))
    }

    public func toggleTrigger(_ id: Int) async throws -> TriggerSummary {
        guard let index = triggerList.firstIndex(where: { $0.id == id }) else { throw ZimmerError.http(status: 404, message: "The requested resource was not found") }
        triggerList[index].status = triggerList[index].isEnabled ? "disabled" : "enabled"
        return triggerList[index]
    }

    public func invokeTrigger(_ id: Int) async throws -> TriggerInvocation {
        guard let trigger = triggerList.first(where: { $0.id == id }) else { throw ZimmerError.http(status: 404, message: "The requested resource was not found") }
        // A disabled trigger can still be fired by hand, as the server allows.
        let started = try await startQuickRouter("\(trigger.name): run now")
        triggerSessions[id, default: []].append(started)
        if let index = triggerList.firstIndex(where: { $0.id == id }) {
            triggerList[index].lastSessionID = started
            triggerList[index].lastTriggeredAt = Date()
            triggerList[index].sessionsCreated = (triggerList[index].sessionsCreated ?? 0) + 1
        }
        return TriggerInvocation(sessionID: started, message: "Trigger '\(trigger.name)' fired: session \(started) started")
    }

    /// One week of spend whatever the window, narrowed as the server narrows: a root keeps
    /// its own share of every figure, a session only its own.
    public func costs(_ window: CostWindow, scope: CostScope) async throws -> CostSnapshot {
        let now = Date()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let roots: [CostSnapshot.Row] = [.init(label: "zimmer", costUSD: 201.4), .init(label: "zimmer-orchestrator", costUSD: 88.2), .init(label: "motet", costUSD: 80.0)]
        let fleet = roots.reduce(0) { $0 + $1.costUSD }
        let top: [CostSnapshot.TopSession] = [
            .init(sessionID: 1042, costUSD: 23.81, tokens: 1_204_331, title: "Add a CarPlay scene to the iOS app", apiCalls: 212),
            .init(sessionID: 1038, costUSD: 17.02, tokens: 880_120, title: "PR #1261 is green and ready — merge it?", apiCalls: 140),
        ]
        let share: Double
        var shownRoots = roots
        var shownTop = top
        switch scope {
        case .fleet:
            share = 1
        case let .agentRoot(root):
            shownRoots = roots.filter { $0.label == root }
            share = (shownRoots.first?.costUSD ?? 0) / fleet
            shownTop = root == "zimmer" ? top : []
        case let .session(id):
            shownTop = top.filter { $0.sessionID == id }
            shownRoots = shownTop.isEmpty ? [] : [.init(label: "zimmer", costUSD: shownTop[0].costUSD)]
            share = (shownTop.first?.costUSD ?? 0) / fleet
        }
        let spend = [41.2, 55.0, 38.7, 62.3, 70.1, 48.9, 53.4].map { $0 * share }
        let daysShown = spend.enumerated().map { offset, cost in
            CostSnapshot.Day(day: formatter.string(from: now.addingTimeInterval(Double(offset - spend.count + 1) * 86_400)), costUSD: cost)
        }
        let bounds: (Date, Date)
        switch window {
        case let .days(days): bounds = (now.addingTimeInterval(-Double(days) * 86_400), now)
        case let .range(from, to): bounds = (from, to.addingTimeInterval(86_399))
        }
        return CostSnapshot(
            from: bounds.0, to: bounds.1, scope: scope, totalUSD: spend.reduce(0, +), days: daysShown, agentRoots: shownRoots,
            models: [.init(label: "opus", costUSD: 330.1 * share), .init(label: "sonnet", costUSD: 39.5 * share)],
            topSessions: shownTop
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
                           conditions: [.init(type: "schedule", description: "Every day at 02:00 UTC", lastTriggeredAt: now.addingTimeInterval(-20 * 60))],
                           reuseSession: true, enqueueMessages: true,
                           promptTemplate: "Sweep the dependencies: bump what is safe, open one PR per ecosystem, and say what you held back on {{date}}.",
                           goal: "Open a reviewed, green PR for each bump."),
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


// MARK: - Why it is waiting
//
// As the server: a spot hold shows while the gate holds a waiting spot session and offers to
// make it priority; a turn queued for a worker offers Force while some running turn can be
// stopped, and Force refuses when the turn it would stop is not the one confirmed; a renewed
// MCP grant offers the reconnect message until a message reaches the agent.
extension FakeZimmerAPI {
    public func forceStart(_ id: Int, expectedVictimID: Int?) async throws -> ForceStartResult {
        let session = try find(id)
        guard session.status == .waiting, queuedTurns.contains(id) else {
            throw ZimmerError.http(status: 422, message: "Session #\(id) has no turn queued for a worker, so there is nothing to force.")
        }
        guard let victim = forceVictim(for: id) else {
            throw ZimmerError.http(status: 422, message: "Nothing to force: a worker thread is already free, so session \(id)'s turn starts on GoodJob's next poll.")
        }
        if let expectedVictimID, expectedVictimID != victim.id {
            throw ZimmerError.http(status: 422, message: "The turn you confirmed — session \(expectedVictimID)'s — is no longer the one that would be stopped (it ended, or was forced out already); session \(victim.id)'s is. Nothing was touched. Reload to see what Force would stop now.")
        }
        // The stopped turn is not cancelled: it goes straight back in the queue.
        queuedTurns.remove(id)
        queuedTurns.insert(victim.id)
        _ = try change(victim.id) { $0.status = .waiting }
        let forced = try change(id) { $0.status = .running }
        return ForceStartResult(session: forced, message: "Session \(victim.id)'s turn was stopped and put back in the queue, and session \(id)'s turn is first in line for the thread it freed.")
    }

    /// The turn Force would stop: the running one that started most recently.
    private func forceVictim(for id: Int) -> SessionSummary? {
        all.filter { $0.status == .running && $0.id != id }
            .max { ($0.updatedAt ?? .distantPast) < ($1.updatedAt ?? .distantPast) }
    }

    func waiting(for session: SessionSummary) -> WaitingExplanation {
        var reasons: [WaitingExplanation.Reason] = []
        var banners: [WaitingBanner] = []
        let id = session.id
        if session.status == .waiting, spotHeld.contains(id), !session.isPriority {
            reasons.append(.init(mechanism: "spot_hold", label: "the spot gate (quota headroom)", at: session.createdAt, current: true))
            banners.append(WaitingBanner(
                key: "spot_hold", tone: .warning, headline: "Held for quota headroom",
                body: [
                    "The spot gate held this session's first turn: the Claude account pool's 5-hour window is at 91% of its 85% target.",
                    "As of 4 minutes ago. It has waited 20 minutes. The starvation lane admits it once it has waited 2 hours, if the gate is still holding it then.",
                    "This is a spot session (genesis trigger, inherited from its trigger). It has not been cancelled — it will start on its own once the gate lets it.",
                    "The gate checks again in about 6 minutes.",
                ],
                action: .updateSchedulingClass(label: "Make this session priority", priority: true)
            ))
        }
        if session.status == .waiting, queuedTurns.contains(id) {
            reasons.append(.init(mechanism: "turn_queued", label: "a worker thread", at: session.updatedAt, current: true))
            var body = [
                "This session has been handed a turn and is waiting for a worker thread.",
                "Nothing is stuck and nobody needs to act. Zimmer runs 4 agent turns at once, and this one starts as soon as a thread frees up. Running means a worker is executing a turn, so a session queued behind the pool reads Waiting.",
            ]
            var action: WaitingBanner.Action?
            if let victim = forceVictim(for: id) {
                let kind = victim.priorityClass ?? "spot"
                body.append("All 4 threads are busy. Force takes one by stopping the turn that started most recently — session #\(victim.id), \(kind), started 2 minutes ago. That turn is not cancelled: it is put straight back in the queue and runs again as soon as a thread frees up. What it loses is the tool call it is in the middle of.")
                action = .forceStart(
                    label: "Force", expectedVictimID: victim.id,
                    confirm: "Stop session #\(victim.id)'s turn (\(kind), started 2 minutes ago) to free a worker thread for session #\(id)?\n\nIts work on disk survives and its turn goes back in the queue, but the tool call it is in the middle of is lost — and Zimmer cannot tell what that is."
                )
            } else {
                body.append("Nothing to force: a worker thread is already free, so session \(id)'s turn starts on GoodJob's next poll.")
            }
            banners.append(WaitingBanner(key: "queued_turn", tone: .info, headline: "Queued for a worker", body: body, action: action))
        }
        if let servers = reconnectServers[id], !servers.isEmpty, session.status == .running || session.status == .needsInput {
            let named = servers.joined(separator: " and ")
            let running = session.status == .running
            banners.append(WaitingBanner(
                key: "mcp_oauth_reconnect", tone: .info, headline: "Authorization complete — reconnects on the next turn",
                body: ["Zimmer has stored the renewed grant for \(named), and the next agent process this session starts will use it. This session's agent loaded its MCP servers when it started and cannot pick up a new connection mid-run, so those tools stay missing until it runs again. " + (running ? "The agent is mid-turn, so a message sent now queues and reconnects on the turn after it." : "Send a message to reconnect.")],
                action: .followUp(label: running ? "Queue a reconnect message" : "Reconnect now",
                                  prompt: "\(named) \(servers.count == 1 ? "has" : "have") been re-authorized, so \(servers.count == 1 ? "its" : "their") MCP tools are available again. Pick up where you left off.")
            ))
        }
        return WaitingExplanation(reasons: reasons, banners: banners)
    }
}

// MARK: - The Settings page's row
//
// As the server: only the keys sent are touched, an empty default clears that override, a
// model must be one its runtime lists (422 "Settings not saved"), an experimental key must be
// registered (422 "Unknown experimental setting"), the allowlist keeps only eligible servers,
// and the MCP Apps pair takes a sign-in acting as you (403 on a relay-only grant).
extension FakeZimmerAPI {
    public static let relayOnlyRefusal = "This sign-in may not act as you; sign in again and allow acting as you to change MCP Apps"

    public func appSettings() async throws -> AppSettings {
        appSettingsRow
    }

    public func updateAppSettings(_ change: AppSettingsChange) async throws -> AppSettings {
        if change.touchesMcpApps, relayOnly {
            throw ZimmerError.http(status: 403, message: Self.relayOnlyRefusal)
        }
        var next = appSettingsRow
        if change.defaultRuntime != nil || change.defaultModel != nil {
            let current = appSettingsRow.sessionDefaults
            var runtimeOverride: String? = current.runtimeOverridden ? current.runtime : nil
            var modelOverride: String? = current.modelOverridden ? current.model : nil
            if let value = change.defaultRuntime { runtimeOverride = value.isEmpty ? nil : value }
            if let value = change.defaultModel { modelOverride = value.isEmpty ? nil : value }
            let runtime = runtimeOverride ?? current.builtIn.runtime
            guard let entry = appSettingsRow.runtime(runtime) else {
                throw ZimmerError.http(status: 422, message: "Default runtime \(runtime) is not a registered runtime")
            }
            let model = modelOverride ?? entry.defaultModel
            guard entry.models.contains(model) else {
                throw ZimmerError.http(status: 422, message: "Default model \(model) is not available for \(entry.label)")
            }
            next.sessionDefaults = AppSettings.SessionDefaults(runtime: runtime, model: model, runtimeOverridden: runtimeOverride != nil,
                                                               modelOverridden: modelOverride != nil, builtIn: current.builtIn)
        }
        for (key, enabled) in change.experimental.sorted(by: { $0.key < $1.key }) {
            guard let index = next.experimental.firstIndex(where: { $0.key == key }) else {
                let valid = appSettingsRow.experimental.map(\.key).joined(separator: ", ")
                throw ZimmerError.http(status: 422, message: "\(key) is not a setting; valid: \(valid)")
            }
            next.experimental[index].enabled = enabled
        }
        if let enabled = change.mcpAppsEnabled { next.mcpApps.enabled = enabled }
        if let names = change.mcpAppsAllowedServers {
            let eligible = Set(appSettingsRow.mcpApps.eligibleServers.map(\.name))
            // Sorted as McpApps::Policy.sanitize_allowlist stores it: the server's order, not the catalog's.
            next.mcpApps.allowedServers = Array(Set(names.filter(eligible.contains))).sorted()
        }
        appSettingsRow = next
        return next
    }

    /// The shipped row: no override, the three built-in toggles at their defaults, MCP Apps
    /// off with two remote servers it could name.
    public static func sampleAppSettings() -> AppSettings {
        AppSettings(
            sessionDefaults: .init(runtime: "claude_code", model: "opus", runtimeOverridden: false, modelOverridden: false,
                                   builtIn: .init(runtime: "claude_code", model: "opus")),
            runtimes: [
                .init(id: "claude_code", label: "Claude Code", defaultModel: "opus", models: ["opus", "sonnet"]),
                .init(id: "codex", label: "Codex", defaultModel: "gpt-5.6-sol", models: ["gpt-5.6-sol"]),
            ],
            experimental: [
                .init(key: "mcp_tool_search", title: "MCP tool search",
                      description: "Spawn Claude Code sessions with ENABLE_TOOL_SEARCH=true so the agent searches MCP tools on demand instead of loading every attached server's tool schemas up front. Claude Code only — Codex ignores it.",
                      enabled: true, defaultEnabled: true),
                .init(key: "warm_clone_pool_active_roots", title: "Warm clones for every active root",
                      description: "Keep ready-made git clones for the repositories of every agent root that started sessions in the last week, not only the router's, so those sessions skip the `git clone` too. Off, the pool serves Quick Router sessions alone. See /health → Warm clone pool for what is pooled and how often a start claimed a clone.",
                      enabled: false, defaultEnabled: false),
                .init(key: "warm_router_process", title: "Warm Quick Router process",
                      description: "Keep one idle Claude Code process booted for the Quick Router, with its MCP servers connected, so a request skips process start and CLI boot. It makes no API call and spends no quota while idle, and the request is its first turn. Costs about 250 MB of RAM. See /health → Warm router process for how often a request claimed it.",
                      enabled: false, defaultEnabled: false),
            ],
            mcpApps: .init(enabled: false, allowedServers: [], eligibleServers: [.init(name: "linear", title: "Linear"), .init(name: "github", title: "GitHub")])
        )
    }
}

// MARK: - The auth boundary: who you are, connections and keys
//
// As the server: the reads are open to any sign-in; every write takes one acting as you
// (403 with the base controller's message on a relay-only grant, before any lookup). A
// revoked connection cannot be re-levelled (422), a revoke of the phone's own connection
// says `signedOut`, a key's name must be present, unique and no longer than 100 characters,
// and a revoked key's row stays so it can be restored.
extension FakeZimmerAPI {
    /// `Api::BaseController#require_a_person_on_the_app`'s message on the app's own token.
    public static let relayOnlyWriteRefusal = "This sign-in may not act as you; sign in again and allow acting as you"
    /// This phone's connection.
    public static let ownGrantID = 7

    public func account() async throws -> Account {
        let own = grants.first { $0.id == Self.ownGrantID }
        let actsAsYou = own?.actsAsYou ?? !relayOnly
        let email = own?.userEmail ?? "tadas@example.com"
        return Account(
            me: .init(authenticatedAs: "native_app", email: email, privilege: actsAsYou ? OAuthGrant.actAsHuman : OAuthGrant.relayOnly,
                      actsAsYou: actsAsYou, grantID: own?.id),
            // The card goes only to a sign-in acting as you.
            webSignIn: actsAsYou
                ? .init(email: email, name: "Tadas", lastSignedInAt: Date().addingTimeInterval(-3 * 3600), totpRequired: true,
                        totpEnrolledAt: Date().addingTimeInterval(-19 * 86_400), recoveryCodesRemaining: 8)
                : nil,
            deployment: .init(git: .init(commitSha: "b7d4e1c9a0f2d3e4c5b6a7980f1e2d3c4b5a6978", commitShort: "b7d4e1c", branch: "main",
                                         commitDate: "2026-10-14 17:22:05 +0000"),
                              environment: .init(railsEnv: "production", rubyVersion: "3.4.6", railsVersion: "8.1.0"))
        )
    }

    public func oauthGrants() async throws -> [OAuthGrant] {
        Self.listed(grants)
    }

    public func setGrantPrivilege(_ id: Int, actsAsYou: Bool) async throws -> OAuthGrant {
        try refuseUnlessActingAsYou()
        guard let index = grants.firstIndex(where: { $0.id == id }) else { throw ZimmerError.http(status: 404, message: "Not found") }
        if grants[index].isRevoked {
            throw ZimmerError.http(status: 422, message: "\(grants[index].clientLabel)'s connection is revoked; approve it again to reconnect")
        }
        if grants[index].actsAsYou != actsAsYou {
            grants[index].actsAsYou = actsAsYou
            grants[index].privilege = actsAsYou ? OAuthGrant.actAsHuman : OAuthGrant.relayOnly
            grants[index].scopeChangedAt = Date()
            grants[index].scopeChangeReason = actsAsYou ? "app_upgrade" : "app_downgrade"
        }
        return grants[index]
    }

    public func revokeGrant(_ id: Int) async throws -> GrantRevocation {
        try refuseUnlessActingAsYou()
        guard let index = grants.firstIndex(where: { $0.id == id }) else { throw ZimmerError.http(status: 404, message: "Not found") }
        if !grants[index].isRevoked {
            grants[index].status = "revoked"
            grants[index].revokedAt = Date()
            grants[index].revocationReason = "revoked from the iOS app (tadas@example.com), 203.0.113.7"
        }
        let grant = grants[index]
        return GrantRevocation(grant: grant, signedOut: id == Self.ownGrantID,
                               message: "Revoked \(grant.clientLabel)'s connection. It is refused from the next request on.")
    }

    public func apiKeys() async throws -> [APIKey] {
        Self.listed(keys)
    }

    public func mintAPIKey(name: String, grant: String) async throws -> MintedAPIKey {
        try refuseUnlessActingAsYou()
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { throw ZimmerError.http(status: 422, message: "Name can't be blank") }
        if trimmed.count > 100 { throw ZimmerError.http(status: 422, message: "Name is too long (maximum is 100 characters)") }
        if keys.contains(where: { $0.name == trimmed }) { throw ZimmerError.http(status: 422, message: "Name has already been taken") }
        guard APIKey.formGrants.contains(grant) else { throw ZimmerError.http(status: 422, message: "Grant \(grant) is not one a person may mint") }
        let token = "zmr_" + Self.randomToken(32)
        let key = APIKey(id: nextKeyID, name: trimmed, status: "active", source: "minted", grant: grant, fingerprint: Self.fingerprint(token),
                         agentSessionsUseIt: false, lastUsedAt: nil, createdAt: Date())
        nextKeyID += 1
        keys.append(key)
        return MintedAPIKey(key: key, token: token)
    }

    public func revokeAPIKey(_ id: Int) async throws -> APIKey {
        try refuseUnlessActingAsYou()
        guard let index = keys.firstIndex(where: { $0.id == id }) else { throw ZimmerError.http(status: 404, message: "Not found") }
        if !keys[index].isRevoked {
            keys[index].status = "revoked"
            keys[index].revokedAt = Date()
        }
        return keys[index]
    }

    public func restoreAPIKey(_ id: Int) async throws -> APIKey {
        try refuseUnlessActingAsYou()
        guard let index = keys.firstIndex(where: { $0.id == id }) else { throw ZimmerError.http(status: 404, message: "Not found") }
        keys[index].status = keys[index].isEnv && keys[index].isRetired ? "retired" : "active"
        keys[index].revokedAt = nil
        return keys[index]
    }

    public func signOutEverywhere() async throws -> SignOutEverywhereResult {
        try refuseUnlessActingAsYou()
        _ = try await revokeGrant(Self.ownGrantID)
        signedOutEverywhere = true
        return SignOutEverywhereResult(webSignInsEnded: 1, thisConnectionRevoked: true,
                                       message: "Signed out on every device. This sign-in is revoked too; sign in again to keep using the app.")
    }

    private func refuseUnlessActingAsYou() throws {
        if relayOnly { throw ZimmerError.http(status: 403, message: Self.relayOnlyWriteRefusal) }
    }

    /// The server's order: active first, then most recently used (connections) or newest
    /// (keys) first, as each `listed` scope sorts.
    private static func listed(_ grants: [OAuthGrant]) -> [OAuthGrant] {
        grants.sorted { a, b in
            if a.isRevoked != b.isRevoked { return !a.isRevoked }
            return (a.lastUsedAt ?? a.createdAt) > (b.lastUsedAt ?? b.createdAt)
        }
    }

    private static func listed(_ keys: [APIKey]) -> [APIKey] {
        keys.sorted { a, b in
            if a.isRevoked != b.isRevoked { return !a.isRevoked }
            return a.createdAt > b.createdAt
        }
    }

    /// The page's fingerprint: the first eight hex characters of the key's SHA-256.
    static func fingerprint(_ token: String) -> String {
        String(SHA256Digest.hash(Array(token.utf8)).map { String(format: "%02x", $0) }.joined().prefix(8))
    }

    private static func randomToken(_ length: Int) -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        return String((0..<length).map { _ in alphabet.randomElement()! })
    }

    /// This phone's connection (acting as you, unless the sign-in is relay only) and a second
    /// phone's, relay only and last used three days ago.
    static func sampleGrants(now: Date = Date(), relayOnly: Bool = false) -> [OAuthGrant] {
        [
            OAuthGrant(id: ownGrantID, clientName: "Zimmer iOS", clientLabel: "Zimmer iOS", clientID: "zimmer-native-app", firstParty: true,
                       registration: "self_registered", publisherHost: nil, userEmail: "tadas@example.com",
                       privilege: relayOnly ? OAuthGrant.relayOnly : OAuthGrant.actAsHuman, actsAsYou: !relayOnly, status: "active", current: true,
                       createdAt: now.addingTimeInterval(-12 * 86_400), lastUsedAt: now.addingTimeInterval(-40),
                       scopeChangedAt: now.addingTimeInterval(-12 * 86_400), scopeChangeReason: "consent"),
            OAuthGrant(id: 4, clientName: "Zimmer iOS", clientLabel: "Zimmer iOS", clientID: "zimmer-native-app", firstParty: true,
                       registration: "self_registered", publisherHost: nil, userEmail: "tadas@example.com",
                       privilege: OAuthGrant.relayOnly, actsAsYou: false, status: "active", current: false,
                       createdAt: now.addingTimeInterval(-41 * 86_400), lastUsedAt: now.addingTimeInterval(-3 * 86_400),
                       scopeChangedAt: now.addingTimeInterval(-41 * 86_400), scopeChangeReason: "consent"),
        ]
    }

    /// The env-registered key every agent session holds, listed under its fingerprint as the
    /// page lists it, and one minted key.
    static func sampleAPIKeys(now: Date = Date()) -> [APIKey] {
        [
            APIKey(id: 1, name: "c0ffee42", status: "active", source: "env", grant: APIKey.apiGrant, fingerprint: "c0ffee42",
                   agentSessionsUseIt: true, lastUsedAt: now.addingTimeInterval(-90), createdAt: now.addingTimeInterval(-120 * 86_400)),
            APIKey(id: 2, name: "laptop scripts", status: "active", source: "minted", grant: APIKey.apiGrant, fingerprint: "9a1b2c3d",
                   agentSessionsUseIt: false, lastUsedAt: now.addingTimeInterval(-6 * 3600), createdAt: now.addingTimeInterval(-9 * 86_400)),
        ]
    }
}
