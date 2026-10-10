import XCTest
@testable import ZimmerKit

final class SessionActionsTests: XCTestCase {
    private func client(_ handlers: [ScriptedTransport.Handler]) -> (ZimmerHTTPClient, ScriptedTransport) {
        let transport = ScriptedTransport(handlers)
        return (ZimmerHTTPClient(auth: AuthSession(store: Fixtures.signedIn(), transport: transport), transport: transport), transport)
    }

    func testDetailDecodesTheSessionAndItsStatusSummary() async throws {
        let (api, transport) = client([{ _ in Fixtures.json(200, [
            "session": ["id": 1038, "title": "Merge?", "status": "needs_input"],
            "status_summary": ["summary": "Needs your go-ahead.", "generated_at": "2026-10-09T10:00:00Z", "generating": false],
            "session_hierarchy": [:], "human_messages": [],
        ]) }])

        let detail = try await api.session(1038)

        XCTAssertEqual(transport.sent.first?.url.path, "/api/v1/sessions/1038")
        XCTAssertEqual(detail.session.status, .needsInput)
        XCTAssertEqual(detail.statusSummary?.summary, "Needs your go-ahead.")
        XCTAssertTrue(detail.acceptsFollowUp)
    }

    func testAMissingStatusSummaryIsNotAnError() async throws {
        let (api, _) = client([{ _ in Fixtures.json(200, ["session": ["id": 7, "status": "running"], "status_summary": NSNull()]) }])
        let detail = try await api.session(7)
        XCTAssertNil(detail.statusSummary)
    }

    func testTheConversationKeepsRolesOrderAndPositions() async throws {
        let (api, transport) = client([{ _ in Fixtures.json(200, [
            "messages": [
                ["role": "user", "content": "Ship it?", "timestamp": "2026-10-09T10:00:00.123Z", "has_tool_use": false, "has_tool_result": false],
                ["role": "assistant", "content": "Using tool: Bash", "has_tool_use": true],
                ["role": "assistant", "content": "Green. Merge?", "has_tool_use": false],
                ["role": "system", "content": "ignored"],
            ],
            "total": 10, "truncated": true,
        ]) }])

        let conversation = try await api.conversation(1038)

        XCTAssertEqual(transport.sent.first?.url.path, "/api/v1/sessions/1038/conversation")
        XCTAssertEqual(conversation.messages.map(\.role), [.user, .assistant, .assistant])
        XCTAssertEqual(conversation.messages.map(\.id), [6, 7, 8], "positions count from the start of the whole conversation")
        XCTAssertTrue(conversation.truncated)
        XCTAssertNotNil(conversation.messages[0].timestamp)
        XCTAssertEqual(conversation.lastAgentMessage?.content, "Green. Merge?", "tool traffic is not the last thing the agent said")
    }

    func testAFollowUpPostsThePromptAndReportsWhetherItWasQueued() async throws {
        let (api, transport) = client([
            { _ in Fixtures.json(200, ["session": ["id": 1, "status": "running"], "message": "Follow-up prompt sent"]) },
            { _ in Fixtures.json(202, ["session": ["id": 1, "status": "running"], "enqueued_message": ["id": 9, "position": 1, "status": "pending"], "message": "Message queued"]) },
        ])

        let sent = try await api.followUp(1, prompt: "Yes, merge it.")
        let queued = try await api.followUp(1, prompt: "And deploy.")

        let request = transport.sent[0]
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.url.path, "/api/v1/sessions/1/follow_up")
        XCTAssertEqual(request.headers["Content-Type"], "application/json")
        let body = try JSONSerialization.jsonObject(with: request.body ?? Data()) as? [String: String]
        XCTAssertEqual(body, ["prompt": "Yes, merge it."])
        XCTAssertFalse(sent.queued)
        XCTAssertTrue(queued.queued)
    }

    func testArchiveAndQuickRouterHitTheirEndpoints() async throws {
        let (api, transport) = client([
            { _ in Fixtures.json(200, ["session": ["id": 1, "status": "archived"], "message": "Session moved to trash"]) },
            { _ in Fixtures.json(201, ["session_id": 2001, "session_url": "https://zimmer.example.test/sessions/2001"]) },
        ])

        let archived = try await api.archive(1)
        let started = try await api.startQuickRouter("Rotate the staging deploy key")

        XCTAssertEqual(transport.sent.map(\.url.path), ["/api/v1/sessions/1/archive", "/api/v1/quick_router"])
        XCTAssertEqual(archived.status, .archived)
        XCTAssertEqual(started, 2001)
    }

    func testARefusedArchiveCarriesTheServersReason() async throws {
        let (api, _) = client([{ _ in Fixtures.json(422, ["error": "A turn is in flight", "message": "Session 1 has a turn in flight; pass force to archive anyway"]) }])
        do {
            _ = try await api.archive(1)
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? ZimmerError, .http(status: 422, message: "Session 1 has a turn in flight; pass force to archive anyway"))
        }
    }

    func testTheFakeDeliversQueuesArchivesAndRoutesLikeTheServer() async throws {
        let fake = FakeZimmerAPI()

        let delivered = try await fake.followUp(1038, prompt: "Yes, merge it.")
        XCTAssertFalse(delivered.queued)
        let afterFollowUp = try await fake.session(1038)
        XCTAssertEqual(afterFollowUp.session.status, .running)
        let conversation = try await fake.conversation(1038)
        XCTAssertEqual(conversation.messages.last?.content, "Yes, merge it.")

        let queued = try await fake.followUp(1042, prompt: "Also add a voice prompt.")
        XCTAssertTrue(queued.queued)

        _ = try await fake.archive(1035)
        let needsInput = try await fake.sessions(.needsInput)
        XCTAssertFalse(needsInput.contains { $0.id == 1035 })
        do {
            _ = try await fake.archive(1035)
            XCTFail("archiving twice should be refused")
        } catch {}

        do {
            _ = try await fake.archive(1038)
            XCTFail("a session mid-turn cannot be archived, as on the server")
        } catch {
            XCTAssertEqual((error as? ZimmerError).map { if case .http(422, _) = $0 { return true } else { return false } }, true)
        }

        let id = try await fake.startQuickRouter("Rotate the staging deploy key")
        let active = try await fake.sessions(.active)
        XCTAssertEqual(active.first { $0.id == id }?.status, .waiting)
    }
}
