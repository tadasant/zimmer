import XCTest
@testable import ZimmerKit

/// Slice 4: the new-session form and a session's model and catalog artifacts.
final class CatalogTests: XCTestCase {
    private func client(_ handlers: [ScriptedTransport.Handler]) -> (ZimmerHTTPClient, ScriptedTransport) {
        let transport = ScriptedTransport(handlers)
        return (ZimmerHTTPClient(auth: AuthSession(store: Fixtures.signedIn(), transport: transport), transport: transport), transport)
    }

    private func body(_ request: HTTPRequest) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: request.body ?? Data()) as? [String: Any])
    }

    func testConfigsDecodeTheFormsListsAndHideRootsAPersonCannotStart() async throws {
        let (api, transport) = client([{ _ in Fixtures.json(200, [
            "agent_roots": [
                ["name": "zimmer", "display_name": "Zimmer", "default": true, "user_invocable": true, "default_runtime": "claude_code",
                 "default_model": "opus", "default_mcp_servers": ["playwright-custom"], "default_skills": ["open-pr"], "url": "https://x"],
                ["name": "hidden", "user_invocable": false],
            ],
            "runtime_models": ["claude_code": ["default": "opus", "models": [
                ["id": "opus", "label": "Opus", "default": true, "effort_levels": ["low", "high"], "default_effort": "high", "source": "built_in"],
            ]]],
            "goals": [["id": "open-reviewed-green-pr", "name": "Open a reviewed, green PR", "checks": []]],
            "mcp_servers": [["name": "slack", "title": "Slack", "unavailable": true, "unavailable_reason": "Needs authorizing"]],
        ]) }])

        let configs = try await api.configs()

        XCTAssertEqual(transport.sent[0].url.path, "/api/v1/configs")
        XCTAssertEqual(configs.invocableRoots.map(\.name), ["zimmer"])
        XCTAssertEqual(configs.models(for: "claude_code").first?.effortLevels, ["low", "high"])
        XCTAssertEqual(configs.goals.first?.id, "open-reviewed-green-pr")
        XCTAssertEqual(configs.mcpServers.first?.id, "slack", "MCP servers are keyed by name")
        XCTAssertEqual(configs.mcpServers.first?.unavailableReason, "Needs authorizing")
        XCTAssertEqual(CatalogKind.skills.defaults(of: configs.agentRoots[0]), ["open-pr"])
    }

    func testEachCatalogIsReadFromItsList() async throws {
        let (api, transport) = client([
            { _ in Fixtures.json(200, ["skills": [["id": "open-pr", "name": "open-pr", "title": "Open a PR"]]]) },
            { _ in Fixtures.json(200, ["hooks": [["id": "h1", "name": "h1"]]]) },
            { _ in Fixtures.json(200, ["plugins": [["id": "p1", "title": "P"]]]) },
        ])

        let skills = try await api.catalog(.skills)
        let hooks = try await api.catalog(.hooks)
        let plugins = try await api.catalog(.plugins)

        XCTAssertEqual(transport.sent.map(\.url.path), ["/api/v1/skills", "/api/v1/hooks", "/api/v1/plugins"])
        XCTAssertEqual(skills.map(\.displayTitle), ["Open a PR"])
        XCTAssertEqual(hooks.map(\.displayTitle), ["h1"], "an entry without a title shows its id")
        XCTAssertEqual(plugins.map(\.id), ["p1"])
    }

    func testANewSessionSendsWhatTheFormChoseAndOnlyThat() async throws {
        let (api, transport) = client([{ _ in Fixtures.json(201, ["session": ["id": 77, "status": "waiting"]]) }])
        let request = NewSessionRequest(
            agentRoot: "zimmer", prompt: "Rotate the key", runtime: "claude_code", model: "opus", effort: "high",
            goal: "open-reviewed-green-pr", schedulingClass: "spot", selections: [.skills: ["open-pr"], .mcpServers: []],
            idempotencyKey: "k-1"
        )

        let session = try await api.createSession(request)

        XCTAssertEqual(session.id, 77)
        XCTAssertEqual("\(transport.sent[0].method) \(transport.sent[0].url.path)", "POST /api/v1/sessions")
        let sent = try body(transport.sent[0])
        XCTAssertEqual(sent["agent_root"] as? String, "zimmer")
        XCTAssertEqual(sent["config"] as? [String: String], ["model": "opus", "effort": "high"])
        XCTAssertEqual(sent["catalog_skills"] as? [String], ["open-pr"])
        XCTAssertEqual(sent["mcp_servers"] as? [String], [], "an explicit empty list means none, not the root's defaults")
        XCTAssertNil(sent["catalog_hooks"], "a kind left alone takes the root's defaults")
        XCTAssertEqual(sent["idempotency_key"] as? String, "k-1")
        XCTAssertEqual(sent["scheduling_class"] as? String, "spot")
    }

    func testModelAndSelectionChangesHitTheirRoutes() async throws {
        let ok: ScriptedTransport.Handler = { _ in Fixtures.json(200, ["session": ["id": 5, "status": "running", "catalog_skills": ["open-pr"]]]) }
        let oauth: ScriptedTransport.Handler = { _ in Fixtures.json(200, [
            "session": ["id": 5, "status": "needs_input"], "message": "MCP servers updated",
            "oauth_required": true, "oauth_required_servers": ["slack"],
        ]) }
        let (api, transport) = client([ok, oauth, ok, ok, ok])

        _ = try await api.updateModel(5, model: "sonnet")
        let servers = try await api.updateSelection(5, .mcpServers, to: ["slack"])
        let skills = try await api.updateSelection(5, .skills, to: ["open-pr"]).session
        _ = try await api.updateSelection(5, .hooks, to: [])
        _ = try await api.updateSelection(5, .plugins, to: ["p1"])

        XCTAssertEqual(transport.sent.map { "\($0.method) \($0.url.path)" }, [
            "PATCH /api/v1/sessions/5/model", "PATCH /api/v1/sessions/5/mcp_servers", "PATCH /api/v1/sessions/5/catalog_skills",
            "PATCH /api/v1/sessions/5/catalog_hooks", "PATCH /api/v1/sessions/5/catalog_plugins",
        ])
        XCTAssertEqual(try body(transport.sent[0]) as? [String: String], ["model": "sonnet"])
        XCTAssertEqual(try body(transport.sent[3])["catalog_hooks"] as? [String], [])
        XCTAssertEqual(CatalogKind.skills.selection(in: skills), ["open-pr"])
        XCTAssertEqual(servers.needsAuthorizing, ["slack"], "a server that needs authorizing is named")
    }

    func testARetryOfTheSameRequestKeepsItsKeyAndAnEditedOneDoesNot() {
        let first = NewSessionRequest(agentRoot: "zimmer", prompt: "Go", idempotencyKey: "a")
        var same = first
        same.idempotencyKey = "b"
        var edited = first
        edited.prompt = "Go now"
        XCTAssertEqual(first.fingerprint, same.fingerprint, "the key is not part of what makes two attempts the same")
        XCTAssertNotEqual(first.fingerprint, edited.fingerprint)
        XCTAssertNil(NewSessionRequest(agentRoot: "zimmer", prompt: "x").body["title"], "no title is sent as no title")
    }

    func testTheFixtureStartsASessionWithTheRootsDefaultsForWhatWasNotChosen() async throws {
        let fake = FakeZimmerAPI()
        let session = try await fake.createSession(NewSessionRequest(agentRoot: "zimmer", prompt: "Go", selections: [.skills: []]))
        XCTAssertEqual(session.mcpServers, ["playwright-custom"], "not chosen: the root's default")
        XCTAssertEqual(session.catalogSkills, [], "chosen empty: none")
        XCTAssertEqual(session.model, "opus")
        await XCTAssertThrowsAsync(try await fake.createSession(NewSessionRequest(agentRoot: "nope", prompt: "x")), "an unknown root is refused")
        await XCTAssertThrowsAsync(try await fake.updateModel(session.id, model: "gpt-5.6-sol"), "a model of another runtime is refused")
    }
}
