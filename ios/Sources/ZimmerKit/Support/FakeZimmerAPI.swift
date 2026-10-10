import Foundation

/// An in-memory Zimmer, for the unit tests and for the app's `#if DEBUG` fixture mode
/// (`-ZimmerFixture`), which is what the UI test and the screenshots drive. An agent cannot
/// complete a Google sign-in, so nothing automated reaches a real server; this is the
/// stand-in, and it behaves like the server where the app depends on it — filters by
/// status, hides archived sessions unless asked, and orders by urgency.
public actor FakeZimmerAPI: ZimmerAPI {
    public private(set) var all: [SessionSummary]

    public init(sessions: [SessionSummary] = FakeZimmerAPI.sampleSessions()) {
        self.all = sessions
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
}
