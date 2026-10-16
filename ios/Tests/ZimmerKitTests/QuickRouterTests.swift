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
        XCTAssertEqual(try body(sent).keys.sorted(), ["prompt"], "no class: the server classes a native start priority")
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

    func testThePageTheRouterWasOpenedOnRidesAlong() throws {
        let session = SessionSummary(id: 1038, title: "PR #1261 is green and ready — merge it?", status: .needsInput,
                                     goal: "Unmerged PR is open and CI is green.", priorityClass: "priority", agentRoot: "zimmer")
        let page = QuickRouterPage.session(session, url: URL(string: "https://zimmer.example.test/sessions/1038"))
        XCTAssertEqual(page.title, "PR #1261 is green and ready — merge it?")
        XCTAssertEqual(page.context, "Zimmer session #1038: PR #1261 is green and ready — merge it?\nStatus: Needs input\nAgent root: zimmer\nScheduling class: priority\nGoal: Unmerged PR is open and CI is green.")

        let json = QuickRouterRequest(prompt: "Merge it", parentSessionID: 1038, page: page).json
        XCTAssertEqual(json["page_url"] as? String, "https://zimmer.example.test/sessions/1038")
        XCTAssertEqual(json["page_title"] as? String, page.title)
        XCTAssertEqual(json["page_context"] as? String, page.context)

        // The page is the screen, not the thread: it goes whether or not the start threads under the session.
        let unthreaded = QuickRouterRequest(prompt: "Merge it", page: QuickRouterPage(url: nil, title: "Costs")).json
        XCTAssertNil(unthreaded["parent_session_id"])
        XCTAssertNil(unthreaded["page_url"], "a screen with no web page sends no URL")
        XCTAssertEqual(unthreaded["page_title"] as? String, "Costs")
        XCTAssertNil(unthreaded["page_context"])
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
