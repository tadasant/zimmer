import XCTest
@testable import ZimmerKit

/// Slice 3: a session's queue, its logs and its subagents.
final class SessionExtrasTests: XCTestCase {
    private func client(_ handlers: [ScriptedTransport.Handler]) -> (ZimmerHTTPClient, ScriptedTransport) {
        let transport = ScriptedTransport(handlers)
        return (ZimmerHTTPClient(auth: AuthSession(store: Fixtures.signedIn(), transport: transport), transport: transport), transport)
    }

    private func body(_ request: HTTPRequest) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: request.body ?? Data()) as? [String: Any])
    }

    func testTheQueueIsReadPendingAndInDeliveryOrder() async throws {
        let (api, transport) = client([{ _ in Fixtures.json(200, ["enqueued_messages": [
            ["id": 2, "content": "second", "position": 2, "status": "pending", "origin": "caller"],
            ["id": 1, "content": "first", "position": 1, "status": "pending", "origin": "automated_merge_notice"],
        ]]) }])

        let queue = try await api.queue(9)

        XCTAssertEqual(transport.sent[0].url.path, "/api/v1/sessions/9/enqueued_messages")
        XCTAssertEqual(URLComponents(url: transport.sent[0].url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "status" }?.value, "pending")
        XCTAssertEqual(queue.map(\.id), [1, 2])
        XCTAssertTrue(queue[0].isAutomated)
        XCTAssertFalse(queue[1].isAutomated)
    }

    func testEachQueueActionHitsItsRoute() async throws {
        let message: ScriptedTransport.Handler = { _ in Fixtures.json(200, ["enqueued_message": ["id": 5, "content": "x", "position": 1]]) }
        let (api, transport) = client([
            message,
            { _ in HTTPResponse(statusCode: 204, headers: ["x-request-id": "r"], body: Data()) },
            message,
            { _ in Fixtures.json(200, ["session": ["id": 9, "status": "running"], "message": "Message sent as interrupt"]) },
        ])

        _ = try await api.editQueued(9, message: 5, content: "deploy to staging only")
        try await api.deleteQueued(9, message: 5)
        _ = try await api.moveQueued(9, message: 5, to: 1)
        try await api.sendQueuedNow(9, message: 5)

        XCTAssertEqual(transport.sent.map { "\($0.method) \($0.url.path)" }, [
            "PATCH /api/v1/sessions/9/enqueued_messages/5",
            "DELETE /api/v1/sessions/9/enqueued_messages/5",
            "PATCH /api/v1/sessions/9/enqueued_messages/5/reorder",
            "POST /api/v1/sessions/9/enqueued_messages/5/interrupt",
        ])
        XCTAssertEqual(try body(transport.sent[0]) as? [String: String], ["content": "deploy to staging only"])
        XCTAssertEqual(try body(transport.sent[2])["position"] as? Int, 1)
    }

    func testLogsPageNewestFirstAndSayWhetherThereIsMore() async throws {
        let (api, transport) = client([{ _ in Fixtures.json(200, [
            "logs": [["id": 3, "content": "Turn started", "level": "info", "created_at": "2026-10-11T01:00:00Z"]],
            "pagination": ["page": 1, "total_pages": 3],
        ]) }])

        let page = try await api.logs(9, page: 1)

        XCTAssertEqual(transport.sent[0].url.path, "/api/v1/sessions/9/logs")
        XCTAssertEqual(page.entries.map(\.content), ["Turn started"])
        XCTAssertTrue(page.hasMore)
    }

    func testASubagentTranscriptIsReadIntoMessages() async throws {
        let jsonl = [
            #"{"type":"user","message":{"role":"user","content":"Find the scenes."}}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Grep","input":{}}]}}"#,
            #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"Info.plist:12"}]}}"#,
            "not json",
            #"{"type":"summary","summary":"x"}"#,
            #"{"type":"assistant","timestamp":"2026-10-11T01:00:00Z","message":{"role":"assistant","content":[{"type":"text","text":"In Info.plist."}]}}"#,
        ].joined(separator: "\n")
        let (api, transport) = client([
            { _ in Fixtures.json(200, ["subagent_transcripts": [["id": 7, "display_label": "Explore: scenes", "formatted_duration": "1m"]]]) },
            { _ in Fixtures.json(200, ["subagent_transcript": ["id": 7, "transcript": jsonl]]) },
        ])

        let list = try await api.subagentTranscripts(9)
        let messages = try await api.subagentTranscript(9, transcript: 7)

        XCTAssertEqual(list.first?.title, "Explore: scenes")
        XCTAssertEqual(transport.sent[1].url.path, "/api/v1/sessions/9/subagent_transcripts/7")
        XCTAssertEqual(messages.map(\.content), ["Find the scenes.", "Using tool: Grep", "Info.plist:12", "In Info.plist."])
        XCTAssertEqual(messages.map(\.isToolTraffic), [false, true, true, false])
        XCTAssertNotNil(messages.last?.timestamp)
    }

    func testTheFixtureManagesAQueueAsTheServerDoes() async throws {
        let fake = FakeZimmerAPI()
        let moved = try await fake.moveQueued(1042, message: 502, to: 1)
        XCTAssertEqual(moved.position, 1)
        try await fake.deleteQueued(1042, message: 501)
        let left = try await fake.queue(1042)
        XCTAssertEqual(left.map(\.id), [502])
        XCTAssertEqual(left.map(\.position), [1], "positions close up after a delete")
        await XCTAssertThrowsAsync(try await fake.editQueued(1042, message: 502, content: "  "), "a blank edit is refused")

        try await fake.sendQueuedNow(1042, message: 502)
        let empty = try await fake.queue(1042)
        XCTAssertEqual(empty, [])
        let conversation = try await fake.conversation(1042)
        XCTAssertEqual(conversation.messages.last?.content, "Then open a draft PR.", "Send now delivers it as the next turn")
    }
}
