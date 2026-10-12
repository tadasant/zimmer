import XCTest
@testable import ZimmerKit

/// What the session page reads beyond the row: the goal check, the human messages, the
/// summary's freshness and a failure's details — each as `GET /api/v1/sessions/:id` writes
/// it, and each lenient, so a panel that does not read never fails the page.
final class SessionPageTests: XCTestCase {
    private func decode(_ json: [String: Any]) throws -> SessionDetail {
        try ZimmerJSON.decoder.decode(SessionShowResponse.self, from: JSONSerialization.data(withJSONObject: json)).detail
    }

    func testTheGoalCheckRidesInsideTheSessionObject() throws {
        let detail = try decode([
            "session": [
                "id": 1044, "status": "needs_input",
                "goal_check": [
                    "goal_id": "open-reviewed-green-pr", "goal_name": "Open a reviewed green PR", "verdict": "pending", "provisional": true,
                    "criteria": [
                        ["key": "pr_open", "label": "An unmerged PR is open", "status": "met", "detail": "#1282 is open"],
                        ["key": "reviewed", "label": "Reviewed", "status": "pending", "detail": NSNull()],
                        ["key": "odd", "status": "surprising"],
                    ],
                    "note": "advisory",
                ],
            ],
        ])
        let check = try XCTUnwrap(detail.goalCheck)
        XCTAssertEqual(check.goalName, "Open a reviewed green PR")
        XCTAssertEqual(check.verdict, "pending")
        XCTAssertTrue(check.provisional)
        XCTAssertEqual(check.criteria.map(\.label), ["An unmerged PR is open", "Reviewed", "odd"], "a criterion without a label is named by its key")
        XCTAssertEqual(check.criteria.map(\.status), ["met", "pending", "surprising"])
        XCTAssertEqual(check.metCount, 1)
    }

    func testAFreeTextGoalHasNoCheckAndAMalformedOneDoesNotFailThePage() throws {
        XCTAssertNil(try decode(["session": ["id": 1, "status": "waiting", "goal_check": NSNull()]]).goalCheck)
        XCTAssertNil(try decode(["session": ["id": 1, "status": "waiting"]]).goalCheck)
        XCTAssertNil(try decode(["session": ["id": 1, "status": "waiting", "goal_check": "yes"]]).goalCheck)
    }

    func testHumanMessagesReadWhoSaidWhatAndDropTheUnreadable() throws {
        let detail = try decode([
            "session": ["id": 1044, "status": "needs_input"],
            "human_messages": [
                ["origin": "here", "author": "tadas@example.com", "author_display_name": "Tadas", "channel": "web_ui", "channel_label": "Web UI",
                 "authored_in_session_id": 1040, "content": "Carry on.", "occurred_at": "2026-10-12T09:00:00Z"],
                ["origin": "elsewhere", "author": "tadas@example.com", "channel_label": "iOS app", "content": "", "occurred_at": "bad"],
                ["origin": "elsewhere", "author": "tadas@example.com", "channel_label": "Slack", "content": "Ship it.", "occurred_at": "not a date"],
            ],
        ])
        XCTAssertEqual(detail.humanMessages.map(\.content), ["Carry on.", "Ship it."], "an entry without content is dropped, not the panel")
        XCTAssertEqual(detail.humanMessages.first?.author, "Tadas", "the display name over the address")
        XCTAssertEqual(detail.humanMessages.last?.author, "tadas@example.com")
        XCTAssertEqual(detail.humanMessages.first?.authoredInSessionID, 1040)
        XCTAssertEqual(detail.humanMessages.first?.channelLabel, "Web UI")
        XCTAssertNotNil(detail.humanMessages.first?.occurredAt)
        XCTAssertNil(detail.humanMessages.last?.occurredAt)
    }

    func testTheSummarySaysHowFreshItIs() throws {
        let detail = try decode([
            "session": ["id": 1044, "status": "needs_input"],
            "status_summary": ["summary": "Open.", "generated_at": "2026-10-12T09:00:00Z", "messages_since_generated": 3, "state": "ready", "generating": false, "error": NSNull()],
        ])
        let summary = try XCTUnwrap(detail.statusSummary)
        XCTAssertEqual(summary.messagesSinceGenerated, 3)
        XCTAssertFalse(summary.isCurrent)
        XCTAssertNotNil(summary.generatedAt)

        let fresh = try decode([
            "session": ["id": 1, "status": "waiting"],
            "status_summary": ["summary": "Open.", "messages_since_generated": 0],
        ])
        XCTAssertTrue(fresh.statusSummary?.isCurrent ?? false)
        let none = try decode([
            "session": ["id": 1, "status": "waiting"],
            "status_summary": ["summary": NSNull(), "messages_since_generated": NSNull(), "generated_at": 12],
        ])
        XCTAssertNil(none.statusSummary?.summary)
        XCTAssertTrue(none.statusSummary?.isCurrent ?? false, "no summary is not a stale summary")
    }

    func testAFailuresDetailsAreReadFromMetadata() throws {
        let detail = try decode([
            "session": [
                "id": 1027, "status": "failed",
                "metadata": ["agent_root_key": "zimmer", "failure_reason": "process_exited", "exception_message": "permission denied",
                             "exception_class": "Zimmer::SecretWriteRefused", "exit_status": "1"],
            ],
        ])
        let metadata = try XCTUnwrap(detail.session.metadata)
        XCTAssertTrue(metadata.hasFailureDetails)
        XCTAssertEqual(metadata.failureReason, "process_exited")
        XCTAssertEqual(metadata.exceptionMessage, "permission denied")
        XCTAssertEqual(metadata.exceptionClass, "Zimmer::SecretWriteRefused")
        XCTAssertEqual(metadata.exitStatus, 1, "an exit status written as a string still reads")
        XCTAssertEqual(metadata.agentRoot, "zimmer")

        let numeric = try decode(["session": ["id": 1, "status": "failed", "metadata": ["failure_reason": "crashed", "exit_status": 137]]])
        XCTAssertEqual(numeric.session.metadata?.exitStatus, 137)
        let healthy = try decode(["session": ["id": 1, "status": "running", "metadata": ["agent_root_key": "zimmer"]]])
        XCTAssertFalse(healthy.session.metadata?.hasFailureDetails ?? true)
    }

    func testTheFixtureCarriesWhatTheRichestSessionShows() async throws {
        let fake = FakeZimmerAPI()
        let detail = try await fake.session(1044)
        XCTAssertEqual(detail.goalCheck?.criteria.count, 4)
        XCTAssertEqual(detail.humanMessages.count, 2)
        XCTAssertEqual(detail.session.pullRequests.count, 4)
        XCTAssertEqual(detail.hierarchy?.nodes.count, 7)
        XCTAssertEqual(detail.statusSummary?.messagesSinceGenerated, 2)
        let failed = try await fake.session(1027)
        XCTAssertTrue(failed.session.metadata?.hasFailureDetails ?? false)
        XCTAssertEqual(failed.session.agentRoot, "zimmer-production", "the failure keeps the root")
    }

    func testCompactAges() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(Format.age(now.addingTimeInterval(-20), now: now), "now")
        XCTAssertEqual(Format.age(now.addingTimeInterval(-41 * 60), now: now), "41m")
        XCTAssertEqual(Format.age(now.addingTimeInterval(-3 * 3600 - 10), now: now), "3h")
        XCTAssertEqual(Format.age(now.addingTimeInterval(-2 * 86_400), now: now), "2d")
        XCTAssertEqual(Format.age(now.addingTimeInterval(-15 * 86_400), now: now), "2w")
        XCTAssertEqual(Format.age(now.addingTimeInterval(60), now: now), "now", "a clock ahead of the server is not the future")
    }

    func testModelNamesReadAsTheWebUIsMetadataBlockShowsThem() {
        XCTAssertEqual(Format.modelName("claude-opus-4-5-20260401"), "opus-4-5")
        XCTAssertEqual(Format.modelName("opus"), "opus")
        XCTAssertEqual(Format.modelName("gpt-5.2-codex"), "gpt-5.2-codex")
        XCTAssertEqual(Format.modelName("anthropic/claude-sonnet-4-5"), "claude-sonnet-4-5", "one prefix is dropped, not every one")
    }
}
