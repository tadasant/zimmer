import XCTest
@testable import ZimmerKit

/// The Settings page's row: session defaults, the experimental toggles and MCP Apps.
final class AppSettingsTests: XCTestCase {
    private func client(_ handlers: [ScriptedTransport.Handler]) -> (ZimmerHTTPClient, ScriptedTransport) {
        let transport = ScriptedTransport(handlers)
        return (ZimmerHTTPClient(auth: AuthSession(store: Fixtures.signedIn(), transport: transport), transport: transport), transport)
    }

    private static func row() -> [String: Any] {
        [
        "session_defaults": [
            "runtime": "codex", "model": "gpt-5.6-sol", "runtime_overridden": true, "model_overridden": false,
            "built_in": ["runtime": "claude_code", "model": "opus"],
        ],
        "runtimes": [
            ["id": "claude_code", "label": "Claude Code", "default_model": "opus", "models": ["opus", "sonnet"]],
            ["id": "codex", "label": "Codex", "default_model": "gpt-5.6-sol", "models": ["gpt-5.6-sol"]],
        ],
        "experimental": [
            ["key": "mcp_tool_search", "title": "MCP tool search", "description": "Search on demand.", "enabled": false, "default_enabled": true, "extension": false],
            ["key": "warm_router_process", "title": "Warm Quick Router process", "description": "One idle process.", "enabled": false, "default_enabled": false, "extension": false],
        ],
        "mcp_apps": ["enabled": true, "allowed_servers": ["linear"], "eligible_servers": [["name": "linear", "title": "Linear"], ["name": "github", "title": "GitHub"]]],
        ]
    }

    func testTheRowDecodesAndTheBannerAndStatusLinesReadAsThePageDoes() async throws {
        let (api, transport) = client([{ _ in Fixtures.json(200, ["app_settings": Self.row()]) }])

        let settings = try await api.appSettings()

        XCTAssertEqual(transport.sent.map { "\($0.method) \($0.url.path)" }, ["GET /api/v1/app_settings"])
        XCTAssertEqual(settings.sessionDefaults.runtime, "codex")
        XCTAssertTrue(settings.sessionDefaults.isOverridden, "either half set by an operator")
        XCTAssertEqual(settings.sessionDefaults.builtIn.model, "opus")
        XCTAssertEqual(settings.sessionDefaultsBanner, "Active global default: Codex / gpt-5.6-sol")
        XCTAssertEqual(settings.models(for: "claude_code"), ["opus", "sonnet"])
        XCTAssertEqual(settings.models(for: "pi"), [], "a runtime the server does not list has no models")
        XCTAssertEqual(settings.runtimeLabel("pi"), "pi")
        XCTAssertEqual(settings.experimental.map(\.statusLine), ["MCP tool search is OFF.", "Warm Quick Router process is OFF (recommended default)."])
        XCTAssertEqual(settings.experimental[0].statusLine(on: true), "MCP tool search is ON (recommended default).")
        XCTAssertFalse(settings.experimental[0].isExtension)
        XCTAssertEqual(settings.mcpApps.allowedServers, ["linear"])
        XCTAssertEqual(settings.mcpApps.eligibleServers.map(\.id), ["linear", "github"])

        let data = try JSONEncoder().encode(settings)
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: data), settings, "the row survives a round trip")
    }

    func testAChangeSendsOnlyTheKeysItNamesAndReadsTheAnsweredRow() async throws {
        let (api, transport) = client([
            { _ in Fixtures.json(200, ["app_settings": Self.row()]) },
            { _ in Fixtures.json(200, ["app_settings": Self.row()]) },
        ])

        _ = try await api.updateAppSettings(AppSettingsChange(experimental: ["mcp_tool_search": false]))
        let after = try await api.updateAppSettings(AppSettingsChange(defaultRuntime: "", defaultModel: "", mcpAppsEnabled: true, mcpAppsAllowedServers: ["linear"]))

        XCTAssertEqual(after.sessionDefaults.runtime, "codex", "the answer is the row as stored")
        XCTAssertEqual(transport.sent.map { "\($0.method) \($0.url.path)" }, ["PATCH /api/v1/app_settings", "PATCH /api/v1/app_settings"])
        let first = try XCTUnwrap(JSONSerialization.jsonObject(with: transport.sent[0].body ?? Data()) as? [String: Any])
        let firstSettings = try XCTUnwrap(first["app_settings"] as? [String: Any])
        XCTAssertEqual(firstSettings.keys.sorted(), ["experimental"], "a toggle flip names nothing else")
        XCTAssertEqual(firstSettings["experimental"] as? [String: Bool], ["mcp_tool_search": false])
        let second = try XCTUnwrap(JSONSerialization.jsonObject(with: transport.sent[1].body ?? Data()) as? [String: Any])
        let secondSettings = try XCTUnwrap(second["app_settings"] as? [String: Any])
        XCTAssertEqual(secondSettings["default_runtime"] as? String, "", "an empty default clears the override")
        XCTAssertEqual(secondSettings["mcp_apps_enabled"] as? Bool, true)
        XCTAssertEqual(secondSettings["mcp_apps_allowed_servers"] as? [String], ["linear"])
        XCTAssertNil(secondSettings["experimental"])
    }

    func testARefusalCarriesTheServersMessage() async throws {
        let (api, _) = client([
            { _ in Fixtures.json(403, ["error": "Forbidden", "message": FakeZimmerAPI.relayOnlyRefusal]) },
            { _ in Fixtures.json(422, ["error": "Unknown experimental setting", "message": "nope is not a setting; valid: mcp_tool_search"]) },
        ])

        do {
            _ = try await api.updateAppSettings(AppSettingsChange(mcpAppsEnabled: true))
            XCTFail("a relay-only grant is refused")
        } catch let error as ZimmerError {
            XCTAssertEqual(error, .http(status: 403, message: FakeZimmerAPI.relayOnlyRefusal))
        }
        do {
            _ = try await api.updateAppSettings(AppSettingsChange(experimental: ["nope": true]))
            XCTFail("an unknown key is refused")
        } catch let error as ZimmerError {
            XCTAssertEqual(error, .http(status: 422, message: "nope is not a setting; valid: mcp_tool_search"))
        }
    }

    func testTheFixtureStoresAChangeAndAnswersAsTheServerDoes() async throws {
        let fake = FakeZimmerAPI()
        let shipped = try await fake.appSettings()
        XCTAssertFalse(shipped.sessionDefaults.isOverridden)
        XCTAssertEqual(shipped.experimental.map(\.key), ["mcp_tool_search", "warm_clone_pool_active_roots", "warm_router_process"])
        XCTAssertEqual(shipped.experimental.map(\.enabled), [true, false, false], "the registry's defaults")
        XCTAssertFalse(shipped.mcpApps.enabled)

        // A model override alone: the runtime stays built in, the banner says the pair.
        let overridden = try await fake.updateAppSettings(AppSettingsChange(defaultModel: "sonnet"))
        XCTAssertEqual(overridden.sessionDefaults.model, "sonnet")
        XCTAssertTrue(overridden.sessionDefaults.modelOverridden)
        XCTAssertFalse(overridden.sessionDefaults.runtimeOverridden)
        XCTAssertEqual(overridden.sessionDefaultsBanner, "Active global default: Claude Code / sonnet")
        // A runtime whose models do not include the stored override is refused, and nothing changes.
        await XCTAssertThrowsAsync(try await fake.updateAppSettings(AppSettingsChange(defaultRuntime: "codex")), "sonnet is not a Codex model")
        let unchanged = try await fake.appSettings()
        XCTAssertEqual(unchanged, overridden)
        // The pair together, then cleared.
        let codex = try await fake.updateAppSettings(AppSettingsChange(defaultRuntime: "codex", defaultModel: "gpt-5.6-sol"))
        XCTAssertEqual(codex.sessionDefaults.runtime, "codex")
        let cleared = try await fake.updateAppSettings(AppSettingsChange(defaultRuntime: "", defaultModel: ""))
        XCTAssertEqual(cleared.sessionDefaults, shipped.sessionDefaults, "an empty default clears the override")

        // A toggle: only the one named moves; an unknown key is refused.
        let flipped = try await fake.updateAppSettings(AppSettingsChange(experimental: ["warm_router_process": true]))
        XCTAssertEqual(flipped.experimental.map(\.enabled), [true, false, true])
        XCTAssertEqual(flipped.experimental[2].statusLine, "Warm Quick Router process is ON.")
        await XCTAssertThrowsAsync(try await fake.updateAppSettings(AppSettingsChange(experimental: ["nope": true])), "an unknown setting")

        // The allowlist keeps eligible servers only, once each, sorted, as the page's sanitize does.
        let apps = try await fake.updateAppSettings(AppSettingsChange(mcpAppsEnabled: true, mcpAppsAllowedServers: ["linear", "stdio-only", "github", "linear"]))
        XCTAssertTrue(apps.mcpApps.enabled)
        XCTAssertEqual(apps.mcpApps.allowedServers, ["github", "linear"])
        XCTAssertEqual(apps.experimental.map(\.enabled), [true, false, true], "the rest of the row is untouched")
    }

    func testARelayOnlyFixtureRefusesMcpAppsAndNothingElse() async throws {
        let fake = FakeZimmerAPI(relayOnly: true)
        do {
            _ = try await fake.updateAppSettings(AppSettingsChange(mcpAppsEnabled: true))
            XCTFail("the MCP Apps pair takes a sign-in acting as you")
        } catch let error as ZimmerError {
            XCTAssertEqual(error, .http(status: 403, message: FakeZimmerAPI.relayOnlyRefusal))
        }
        let after = try await fake.appSettings()
        XCTAssertFalse(after.mcpApps.enabled, "refused before anything is stored")
        let flipped = try await fake.updateAppSettings(AppSettingsChange(experimental: ["mcp_tool_search": false]))
        XCTAssertFalse(flipped.experimental[0].enabled, "a toggle is anyone's to change")
    }
}
