import XCTest
@testable import ZimmerKit

/// What a Quick Router start sends: the words alone, or with the web bubble's Advanced
/// choices and attachments — and only what was chosen.
final class QuickRouterTests: XCTestCase {
    private func client(_ handlers: [ScriptedTransport.Handler]) -> (ZimmerHTTPClient, ScriptedTransport) {
        let transport = ScriptedTransport(handlers)
        return (ZimmerHTTPClient(auth: AuthSession(store: Fixtures.signedIn(), transport: transport), transport: transport), transport)
    }

    private func body(_ request: HTTPRequest) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: request.body ?? Data()) as? [String: Any])
    }

    func testTheWordsAloneSendOnlyThePrompt() async throws {
        let (api, transport) = client([{ _ in Fixtures.json(201, ["session_id": 4123, "session_url": "https://zimmer.example.com/sessions/4123"]) }])
        let id = try await api.startQuickRouter("Rotate the staging deploy key")
        XCTAssertEqual(id, 4123)
        let sent = try XCTUnwrap(transport.sent.first)
        XCTAssertEqual(sent.url.path, "/api/v1/quick_router")
        XCTAssertEqual(try body(sent).keys.sorted(), ["prompt"])
    }

    func testTheAdvancedChoicesAndAttachmentsRideAlong() async throws {
        let (api, transport) = client([{ _ in Fixtures.json(201, ["session_id": 4124]) }])
        let request = QuickRouterRequest(
            prompt: "Long unattended sweep", runtime: "codex", model: "gpt-5.2-codex", spot: true, parentSessionID: 1044,
            attachments: [MessageAttachment(filename: "deploy.log", mediaType: "text/plain", data: Data("failed\n".utf8))]
        )
        _ = try await api.startQuickRouter(request)
        let json = try body(try XCTUnwrap(transport.sent.first))
        XCTAssertEqual(json["agent_runtime"] as? String, "codex")
        XCTAssertEqual(json["model"] as? String, "gpt-5.2-codex")
        XCTAssertEqual(json["scheduling_class"] as? String, "spot")
        XCTAssertEqual(json["parent_session_id"] as? Int, 1044)
        let attachment = try XCTUnwrap((json["attachments"] as? [[String: Any]])?.first)
        XCTAssertEqual(attachment["filename"] as? String, "deploy.log")
        XCTAssertEqual(attachment["data"] as? String, Data("failed\n".utf8).base64EncodedString())
    }

    func testBlankChoicesAreNotSent() throws {
        let json = QuickRouterRequest(prompt: "x", runtime: "", model: "", spot: false).json
        XCTAssertEqual(json.keys.sorted(), ["prompt"], "an untouched panel posts nothing, so the server resolves the defaults")
    }

    func testTheFixtureRefusesWhatTheServerRefuses() async throws {
        let fake = FakeZimmerAPI()
        await XCTAssertThrowsAsync(try await fake.startQuickRouter(QuickRouterRequest(prompt: "x", runtime: "not-a-runtime")), "an unregistered harness")
        await XCTAssertThrowsAsync(try await fake.startQuickRouter(QuickRouterRequest(prompt: "x", runtime: "codex", model: "opus")), "a model of another harness")
        await XCTAssertThrowsAsync(try await fake.startQuickRouter(QuickRouterRequest(prompt: "x", parentSessionID: 1)), "a parent that is not there")

        let id = try await fake.startQuickRouter(QuickRouterRequest(prompt: "Sweep", spot: true, parentSessionID: 1038))
        let started = try await fake.session(id).session
        XCTAssertEqual(started.priorityClass, "spot")
        XCTAssertEqual(started.precedence, 51, "the top of the fixture's spot queue, one above 1031's 50")
        let recorded = await fake.quickRouterRequests.last
        XCTAssertEqual(recorded?.parentSessionID, 1038)
    }
}
