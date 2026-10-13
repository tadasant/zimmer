import XCTest
@testable import ZimmerKit

/// The session page's detail (iOS parity G16): the goal named from the catalog, the goal
/// check's delegated sessions, the hierarchy's origin, genesis and "drawn under" rows, the
/// human messages split here from elsewhere with the capture gaps, and each MCP server's
/// connection — each as `GET /api/v1/sessions/:id` and `GET /api/v1/configs` write them.
final class SessionDetailPanelsTests: XCTestCase {
    private func client(_ handlers: [ScriptedTransport.Handler]) -> (ZimmerHTTPClient, ScriptedTransport) {
        let transport = ScriptedTransport(handlers)
        return (ZimmerHTTPClient(auth: AuthSession(store: Fixtures.signedIn(), transport: transport), transport: transport), transport)
    }

    private func decode(_ json: [String: Any]) throws -> SessionDetail {
        try ZimmerJSON.decoder.decode(SessionShowResponse.self, from: JSONSerialization.data(withJSONObject: json)).detail
    }

    // MARK: - The goal, by its name

    func testACatalogGoalIsNamedWhetherStoredAsItsIdOrItsWords() async throws {
        let (api, transport) = client([
            { _ in Fixtures.json(200, ["goals": [
                ["id": "open-reviewed-green-pr", "name": "Open Reviewed Green PR", "description": "Unmerged PR is open and CI is green.", "checks": ["ci_green"]],
                ["id": "codebase-question", "name": "", "description": NSNull()],
            ]]) },
        ])
        let configs = try await api.configs()
        XCTAssertEqual(transport.sent.first?.url.path, "/api/v1/configs")

        XCTAssertEqual(configs.goal(matching: "open-reviewed-green-pr")?.title, "Open Reviewed Green PR", "stored as its id")
        XCTAssertEqual(configs.goal(matching: "  Unmerged PR is open and CI is green.\n")?.id, "open-reviewed-green-pr", "stored as its words")
        XCTAssertNil(configs.goal(matching: "Recommend a Postgres version."), "free text names no catalog goal")
        XCTAssertNil(configs.goal(matching: ""))
        XCTAssertNil(configs.goal(matching: nil))

        // A blank name falls back to the id; a goal without words is stored as its id.
        let bare = try XCTUnwrap(configs.goal(matching: "codebase-question"))
        XCTAssertEqual(bare.title, "codebase-question")
        XCTAssertEqual(bare.storedValue, "codebase-question")
        XCTAssertEqual(configs.goals.first?.storedValue, "Unmerged PR is open and CI is green.", "picked from the catalog, a goal is stored as its words, as the web picker stores it")
    }

    func testPickingAGoalPatchesTheSessionWithItsWords() async throws {
        let fake = FakeZimmerAPI()
        let configs = try await fake.configs()
        let question = try XCTUnwrap(configs.goals.first { $0.id == "codebase-question" })
        let session = try await fake.updateGoal(1038, goal: question.storedValue)
        XCTAssertEqual(configs.goal(matching: session.goal)?.title, "Codebase Question")
    }

    // MARK: - The goal check's delegated sessions

    func testTheGoalCheckSaysWhoseRequestsWereJudged() throws {
        let detail = try decode([
            "session": [
                "id": 1040, "status": "archived",
                "goal_check": [
                    "goal_id": "open-reviewed-green-pr", "goal_name": "Open Reviewed Green PR", "verdict": "pending", "provisional": true,
                    "observed_at": "2026-10-12T09:00:00Z", "delegated_session_ids": [1044, 1046],
                    "criteria": [["key": "pull_request_open", "label": "A pull request is open or merged", "status": "met"]],
                    "note": "Advisory only: nothing acts on this.",
                ],
            ],
        ])
        let check = try XCTUnwrap(detail.goalCheck)
        XCTAssertEqual(check.goalID, "open-reviewed-green-pr")
        XCTAssertEqual(check.delegatedSessionIDs, [1044, 1046])
        XCTAssertEqual(check.note, "Advisory only: nothing acts on this.")
        XCTAssertEqual(check.tally, "1 of 1 met · Open Reviewed Green PR · not at rest yet", "the web panel's line beside the verdict")

        let own = try decode(["session": ["id": 1, "status": "needs_input", "goal_check": [
            "verdict": "met", "delegated_session_ids": "not a list", "criteria": [["key": "ci_green", "status": "met"]],
        ]]])
        XCTAssertEqual(own.goalCheck?.delegatedSessionIDs, [], "a malformed list reads as the session's own PRs, not a failed page")
        XCTAssertEqual(own.goalCheck?.tally, "1 of 1 met")
    }

    // MARK: - The hierarchy

    func testTheHierarchyMarksTheOriginGenesisAndRowsDrawnUnderASenior() throws {
        let detail = try decode([
            "session": ["id": 1044, "status": "needs_input"],
            "session_hierarchy": [
                "origin_session_id": 1040, "root_session_ids": [1040, 1050], "truncated": true,
                "truncation_reason": "The tree has more than 50 sessions; only the first 50 are shown.",
                "nodes": [
                    ["id": 1040, "status": "archived", "depth": 0, "genesis": "slack", "priority_class": "priority", "spawn_edge": true],
                    ["id": 1044, "status": "needs_input", "depth": 1, "current": true, "genesis": "slack", "priority_class": "spot",
                     "parent_session_id": 1040, "render_parent_session_id": 1040, "spawn_edge": true, "agent_root": "zimmer"],
                    ["id": 1049, "status": "failed", "depth": 2, "genesis": "slack", "priority_class": NSNull(),
                     "parent_session_id": 1046, "render_parent_session_id": 1044, "spawn_edge": false],
                    ["id": 1050, "status": "running", "depth": 0, "genesis": NSNull()],
                ],
            ],
        ])
        let hierarchy = try XCTUnwrap(detail.hierarchy)
        XCTAssertEqual(hierarchy.originID, 1040)
        XCTAssertEqual(hierarchy.rootIDs, [1040, 1050])
        XCTAssertEqual(hierarchy.truncationReason, "The tree has more than 50 sessions; only the first 50 are shown.")
        XCTAssertEqual(hierarchy.nodes.map { hierarchy.rootMarker(for: $0) }, ["origin", nil, nil, "root"])
        XCTAssertEqual(hierarchy.nodes.map(\.genesisLine), ["slack · priority", "slack · spot", "slack", nil])
        XCTAssertEqual(hierarchy.nodes.map(\.spawnEdge), [true, true, false, true])
        XCTAssertEqual(hierarchy.nodes[2].renderParentID, 1044)
        XCTAssertTrue(hierarchy.hasRedrawnEdges)
        XCTAssertEqual(hierarchy.summary, "4 sessions, origin #1040", "the parent is the origin, so it is named once")
    }

    func testAHierarchyFromBeforeTheFieldsReadsAsSpawnedAndNamesTheParentByDepth() throws {
        let detail = try decode([
            "session": ["id": 3, "status": "running"],
            "session_hierarchy": ["nodes": [
                ["id": 1, "status": "archived", "depth": 0],
                ["id": 2, "status": "running", "depth": 1],
                ["id": 3, "status": "running", "depth": 2, "current": true],
            ]],
        ])
        let hierarchy = try XCTUnwrap(detail.hierarchy)
        XCTAssertFalse(hierarchy.hasRedrawnEdges)
        XCTAssertNil(hierarchy.originID)
        XCTAssertEqual(hierarchy.summary, "3 sessions · parent #2")
    }

    // MARK: - Human messages and capture gaps

    func testHumanMessagesSplitHereFromElsewhereAndCarryTheCaptureGaps() throws {
        let detail = try decode([
            "session": ["id": 1044, "status": "needs_input"],
            "human_messages": [
                ["origin": "elsewhere", "author_display_name": "Tadas", "channel_label": "Zimmer web UI", "authored_in_session_id": 1040,
                 "authored_in": "session #1040 — Route: iOS parity audit", "content": "Audit it.", "occurred_at": "2026-10-12T09:00:00Z"],
                ["origin": "here", "author_display_name": "Tadas", "channel_label": "Zimmer web UI", "authored_in_session_id": 1044,
                 "authored_in": "this session (#1044)", "content": "Carry on.", "occurred_at": "2026-10-12T10:00:00Z"],
                // A server from before `origin`: where it was said decides.
                ["author": "tadas", "authored_in_session_id": 1044, "content": "And screenshots."],
            ],
            "human_message_capture_gaps": [
                ["channel": "slack", "channel_label": "Slack", "genesis": "slack", "session_ids": [1040],
                 "reason": "No row maps any Slack user ID.", "remedy": "Fill in the Slack user ID at /supervisor/users."],
                ["channel_label": "No channel"],
                "not an object",
            ],
        ])
        XCTAssertEqual(detail.humanMessages.map(\.origin), [.elsewhere, .here, .here])
        XCTAssertEqual(detail.humanMessages.first?.authoredInTitle, "Route: iOS parity audit")
        XCTAssertNil(detail.humanMessages[1].authoredInTitle, "this session's own words name no other session")
        XCTAssertEqual(detail.humanMessagesSummary, "2 messages in this session · 1 elsewhere in the hierarchy")

        XCTAssertEqual(detail.captureGaps.count, 1, "a gap without a channel is dropped, not the panel")
        let gap = try XCTUnwrap(detail.captureGaps.first)
        XCTAssertEqual(gap.channelLabel, "Slack")
        XCTAssertEqual(gap.sessionIDs, [1040])
        XCTAssertEqual(gap.remedy, "Fill in the Slack user ID at /supervisor/users.")
        XCTAssertEqual(gap.headline, "Capture is not configured for Slack — which 1 session in this hierarchy came in through.")
    }

    func testTheClosedRowSaysWhatTheSearchCouldNotCover() throws {
        let one = try decode([
            "session": ["id": 1, "status": "running"],
            "human_messages": [["origin": "here", "content": "Go."]],
            "session_hierarchy": ["truncated": true, "nodes": []],
        ])
        XCTAssertEqual(one.humanMessagesSummary, "1 message in this session · 0 elsewhere in the hierarchy (truncated tree — not every session was searched)")

        let blind = try decode([
            "session": ["id": 1, "status": "running"],
            "human_messages": [],
            "human_message_capture_gaps": [["channel": "slack", "channel_label": "Slack", "session_ids": [1, 2]], ["channel": "web_ui", "channel_label": "the Zimmer web UI"]],
        ])
        XCTAssertEqual(blind.humanMessagesSummary, "none recorded anywhere in this hierarchy — and capture is not configured for this hierarchy's channels")
        XCTAssertEqual(blind.captureGaps.first?.headline, "Capture is not configured for Slack — which 2 sessions in this hierarchy came in through.")

        let nobody = try decode(["session": ["id": 1, "status": "running"]])
        XCTAssertEqual(nobody.humanMessagesSummary, "none recorded anywhere in this hierarchy")
        XCTAssertTrue(nobody.captureGaps.isEmpty)
    }

    // MARK: - MCP connections

    func testEachWiredMcpServerSaysHowItsConnectionStands() throws {
        let detail = try decode([
            "session": [
                "id": 1044, "status": "needs_input",
                "mcp_servers": ["playwright-custom", "linear"],
                "all_mcp_servers": ["playwright-custom", "linear", "zimmer-self-session", "from-a-plugin", "linear"],
                "injected_mcp_servers": ["zimmer-self-session"],
                "custom_metadata": ["mcp_servers_status": [
                    "playwright-custom": ["status": "connected"],
                    "linear": ["status": "failed", "error": "401 Unauthorized"],
                    "zimmer-self-session": ["status": "pending"],
                    "from-a-plugin": "not an object",
                ]],
            ],
        ])
        let connections = detail.session.mcpConnections
        XCTAssertEqual(connections.map(\.name), ["playwright-custom", "linear", "zimmer-self-session", "from-a-plugin"], "the effective set, each once")
        XCTAssertEqual(connections.map(\.state), [.connected, .failed, .pending, .pending], "an entry that does not read is pending, as the web chip reads it")
        XCTAssertEqual(connections[1].error, "401 Unauthorized")
        XCTAssertEqual(connections.map(\.injected), [false, false, true, false])

        let older = try decode(["session": ["id": 1, "status": "running", "mcp_servers": ["playwright-custom"]]])
        XCTAssertEqual(older.session.mcpConnections.map(\.name), ["playwright-custom"], "without the effective set, the chosen ones")
        XCTAssertEqual(older.session.mcpConnections.first?.state, .pending)
        let none = try decode(["session": ["id": 1, "status": "running", "custom_metadata": ["mcp_servers_status": "broken"]]])
        XCTAssertTrue(none.session.mcpConnections.isEmpty)
        XCTAssertEqual(McpConnection.State("surprising"), .pending)
    }

    func testTheMcpStatusesSurviveARoundTripWithThePullRequests() throws {
        let metadata = SessionCustomMetadata(
            pullRequests: [PullRequestLink(url: URL(string: "https://github.com/tadasant/zimmer/pull/1")!, state: "open")],
            mcpServerStatuses: ["linear": McpServerStatus(status: "failed", error: "401")]
        )
        let decoded = try JSONDecoder().decode(SessionCustomMetadata.self, from: JSONEncoder().encode(metadata))
        XCTAssertEqual(decoded, metadata)
    }

    // MARK: - The fixture

    func testTheFixtureCarriesEveryPanelTheScreenshotsShow() async throws {
        let fake = FakeZimmerAPI()
        let long = try await fake.session(1044)
        XCTAssertEqual(long.session.goal, "open-reviewed-green-pr", "a catalog goal stored as its id")
        XCTAssertEqual(long.captureGaps.map(\.channel), ["slack"])
        XCTAssertEqual(long.humanMessages.map(\.isHere), [false, true])
        XCTAssertEqual(long.session.mcpConnections.map(\.state), [.connected, .failed, .pending])
        XCTAssertEqual(long.hierarchy?.originID, 1040)
        XCTAssertEqual(long.hierarchy?.nodes.filter { !$0.spawnEdge }.map(\.id), [1049])

        // The router opens from the hierarchy, and is judged on the PRs of 1044, which it spawned.
        let router = try await fake.session(1040)
        XCTAssertEqual(router.goalCheck?.delegatedSessionIDs, [1044])
        XCTAssertEqual(router.hierarchy?.nodes.first { $0.current }?.id, 1040)

        let free = try await fake.session(1035)
        let configs = try await fake.configs()
        XCTAssertNil(configs.goal(matching: free.session.goal), "1035's goal is free text")
        let merge = try await fake.session(1038)
        XCTAssertEqual(configs.goal(matching: merge.session.goal)?.title, "Open Reviewed Green PR", "1038's is a catalog goal's words")

        // Choosing MCP servers moves the effective set with them, keeping the injected one.
        _ = try await fake.updateSelection(1038, .mcpServers, to: ["slack"])
        let rewired = try await fake.session(1038)
        XCTAssertEqual(rewired.session.mcpConnections.map(\.name), ["slack", "zimmer-self-session"])
    }
}
