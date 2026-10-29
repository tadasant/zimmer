import XCTest
@testable import ZimmerKit

/// Live Mode: what the app sends and reads over `/api/v1/live*`, and the Realtime sequencing a
/// voice call runs (the same rules as the web's call dock).
final class LiveAPITests: XCTestCase {
    private func client(_ handlers: [ScriptedTransport.Handler]) -> (ZimmerHTTPClient, ScriptedTransport) {
        let transport = ScriptedTransport(handlers)
        return (ZimmerHTTPClient(auth: AuthSession(store: Fixtures.signedIn(), transport: transport), transport: transport), transport)
    }

    private func body(_ request: HTTPRequest) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: request.body ?? Data()) as? [String: Any])
    }

    private static func conversation() -> [String: Any] { [
        "id": 7, "mode": "voice", "voice": true, "label": "Live Mode", "mode_label": "Voice", "status": "active", "title": "Live Mode · Oct 15",
        "agent_root": "live-mode", "model": "gpt-realtime-2.1-mini", "instructions_source": "x@abc:AGENTS.md",
        "mcp_servers": ["zimmer", "demo-clock"], "responding": false, "error_message": NSNull(),
        "turns": [
            ["id": 1, "role": "user", "source": "spoken", "content": "Is main green?", "tool_name": NSNull(), "tool_arguments": NSNull(), "tool_output": NSNull(), "tool_error": false],
            ["id": 2, "role": "tool", "source": NSNull(), "content": NSNull(), "tool_name": "zimmer", "call_id": "c1",
             "tool_arguments": ["tool": "quick_router", "arguments": ["prompt": "check main"]], "tool_output": "Started #9", "tool_error": false],
        ],
    ] }

    func testAvailabilityDecodesWithItsReasonsAndEachModesModel() async throws {
        let (api, transport) = client([{ _ in
            let shared: [String: Any] = ["agent_root": "live-mode", "available": false, "key_configured": false, "root_present": true,
                                         "reasons": ["LIVE_OPENAI_API_KEY is not set."]]
            return Fixtures.json(200, shared.merging(["label": "Live Mode", "modes": [
                shared.merging(["mode": "text", "label": "Text", "model": "gpt-6-luna"]) { $1 },
                shared.merging(["mode": "voice", "label": "Voice", "model": "gpt-realtime-2.1-mini"]) { $1 },
            ]]) { $1 })
        }])
        let availability = try await api.liveAvailability()
        XCTAssertEqual(transport.sent.first?.url.path, "/api/v1/live")
        XCTAssertFalse(availability.available)
        XCTAssertEqual(availability.agentRoot, "live-mode")
        XCTAssertEqual(availability.reasons, ["LIVE_OPENAI_API_KEY is not set."])
        XCTAssertEqual(availability.models, [.text: "gpt-6-luna", .voice: "gpt-realtime-2.1-mini"])
    }

    func testAvailabilityFromAServerThatStillHasTwoModesReadsTheTypedOne() async throws {
        let (api, _) = client([{ _ in Fixtures.json(200, ["modes": [
            ["mode": "text", "label": "Live Mode", "agent_root": "live-mode", "model": "gpt-6-luna", "available": true, "reasons": []],
            ["mode": "voice", "label": "Live Voice", "agent_root": "live-voice", "model": "gpt-realtime-2.1-mini", "available": false, "reasons": ["no root"]],
        ]]) }])
        let availability = try await api.liveAvailability()
        XCTAssertTrue(availability.available)
        XCTAssertEqual(availability.agentRoot, "live-mode")
        XCTAssertEqual(availability.reasons, [])
    }

    func testAConversationDecodesWithItsTurnsAndTheGatewayToolItCalled() async throws {
        let (api, transport) = client([{ _ in Fixtures.json(200, LiveAPITests.conversation()) }])
        let conversation = try await api.liveConversation(7, afterTurn: 0)
        XCTAssertEqual(transport.sent.first?.url.path, "/api/v1/live_conversations/7")
        XCTAssertEqual(transport.sent.first?.url.query, "after_turn_id=0")
        XCTAssertEqual(conversation.status, .active)
        XCTAssertEqual(conversation.mcpServers, ["zimmer", "demo-clock"])
        let turns = try XCTUnwrap(conversation.turns)
        XCTAssertEqual(turns.map(\.role), [.user, .tool])
        XCTAssertEqual(turns[1].toolLabel, "zimmer → quick_router")
    }

    func testTheIndexReadsTheOneCurrentConversation() async throws {
        let (api, _) = client([{ _ in Fixtures.json(200, ["live_conversations": [LiveAPITests.conversation()], "current_id": 7, "current": ["voice": 7]]) }])
        let overview = try await api.liveConversations()
        XCTAssertEqual(overview.current, 7)
        XCTAssertEqual(overview.conversations.map(\.id), [7])
    }

    func testTheIndexFromAServerWithoutCurrentIDReadsTheKeyedOne() async throws {
        let (api, _) = client([{ _ in Fixtures.json(200, ["live_conversations": [], "current": ["text": NSNull(), "voice": 7]]) }])
        let overview = try await api.liveConversations()
        XCTAssertEqual(overview.current, 7)
    }

    func testSwitchingModePostsTheMode() async throws {
        let (api, transport) = client([{ _ in Fixtures.json(200, LiveAPITests.conversation()) }])
        let conversation = try await api.setLiveMode(7, mode: .voice)
        XCTAssertEqual(transport.sent.first?.url.path, "/api/v1/live_conversations/7/mode")
        XCTAssertEqual(try body(transport.sent[0])["mode"] as? String, "voice")
        XCTAssertEqual(conversation.mode, .voice)
    }

    func testStartMessageAndFinishSendWhatTheServerTakes() async throws {
        let (api, transport) = client([
            { _ in Fixtures.json(201, LiveAPITests.conversation()) },
            { _ in Fixtures.json(201, ["id": 3, "role": "user", "source": "typed", "content": "hello", "tool_error": false]) },
            { _ in Fixtures.json(200, LiveAPITests.conversation().merging(["status": "ended"]) { $1 }) },
        ])
        _ = try await api.startLiveConversation(.text)
        let turn = try await api.sendLiveMessage(7, content: "hello")
        let ended = try await api.finishLiveConversation(7)
        XCTAssertEqual(transport.sent.map(\.url.path), ["/api/v1/live_conversations", "/api/v1/live_conversations/7/messages", "/api/v1/live_conversations/7/finish"])
        XCTAssertEqual(try body(transport.sent[0])["mode"] as? String, "text")
        XCTAssertEqual(try body(transport.sent[1])["content"] as? String, "hello")
        XCTAssertEqual(turn.source, "typed")
        XCTAssertEqual(ended.status, .ended)
    }

    func testTheVoiceRelayEndpoints() async throws {
        let (api, transport) = client([
            { _ in Fixtures.json(200, ["client_secret": "ek_1", "expires_at": 1, "model": "gpt-realtime-2.1-mini",
                                       "calls_url": "https://api.openai.com/v1/realtime/calls",
                                       "websocket_url": "wss://api.openai.com/v1/realtime?model=gpt-realtime-2.1-mini", "tools": [],
                                       "listening": "wake_word"]) },
            { _ in Fixtures.json(200, ["output": "Enabled demo-clock.", "error": false, "tools_changed": true, "turn_id": 4,
                                       "tools": [["type": "function", "name": "demo-clock__current_time"]]]) },
            { _ in Fixtures.json(201, ["id": 5, "role": "assistant", "source": "spoken", "content": "Done.", "tool_error": false]) },
            { _ in Fixtures.json(200, ["respond": false, "dropped": true]) },
        ])
        let secret = try await api.liveClientSecret(7)
        XCTAssertEqual(secret.clientSecret, "ek_1")
        XCTAssertEqual(secret.listening, "wake_word")
        XCTAssertEqual(try body(transport.sent[0])["listening_modes"] as? String, "1", "the app says it asks for its own replies")
        XCTAssertEqual(secret.websocketURL.absoluteString, "wss://api.openai.com/v1/realtime?model=gpt-realtime-2.1-mini")

        let result = try await api.relayLiveToolCall(7, name: "enable_mcp_server", arguments: "{\"name\":\"demo-clock\"}", callID: "call_1")
        XCTAssertTrue(result.toolsChanged)
        XCTAssertEqual(result.tools?.array?.first?["name"]?.string, "demo-clock__current_time")
        let relay = try body(transport.sent[1])
        XCTAssertEqual(relay["name"] as? String, "enable_mcp_server")
        XCTAssertEqual(relay["arguments"] as? String, "{\"name\":\"demo-clock\"}")
        XCTAssertEqual(relay["call_id"] as? String, "call_1")

        let kept = try await api.recordLiveTurn(7, role: .assistant, content: "Done.", gated: false)
        XCTAssertEqual(kept, LiveHeard(respond: true), "a turn alone, as a server from before Listening answers, is kept and answered")
        XCTAssertEqual(transport.sent.map(\.url.path)[1...2], ["/api/v1/live_conversations/7/tool_calls", "/api/v1/live_conversations/7/turns"])
        XCTAssertEqual(try body(transport.sent[2])["role"] as? String, "assistant")
        XCTAssertNil(try body(transport.sent[2])["listening_modes"])

        let dropped = try await api.recordLiveTurn(7, role: .user, content: "talking to a friend", gated: true)
        XCTAssertEqual(dropped, LiveHeard(respond: false, dropped: true))
        XCTAssertEqual(try body(transport.sent[3])["listening_modes"] as? String, "1")
    }

    func testAStatusThisVersionDoesNotKnowReadsAsEnded() throws {
        var json = LiveAPITests.conversation()
        json["status"] = "archived_somehow"
        let data = try JSONSerialization.data(withJSONObject: json)
        let conversation = try ZimmerJSON.decoder.decode(LiveConversation.self, from: data)
        XCTAssertEqual(conversation.status, .ended)
        XCTAssertFalse(conversation.status.isOpen)
    }

    /// `GET /api/v1/live/settings`, or a write's answer (`written`), as the server renders it.
    private static func settings(written: Bool = false) -> [String: Any] {
        var json: [String: Any] = [
            "settings": ["text_model": "gpt-6-sol", "text_temperature": NSNull(), "voice_speed": 0.75] as [String: Any],
            "overrides": ["text_model", "voice_speed"],
            "guidance": "Keep answers short.",
            "updated_at": "2026-10-16T12:00:00.000Z",
            "updated_by": "agent:live conversation #7",
            "fields": [
                ["key": "text_model", "path": "text", "type": "enum", "label": "Text model", "help": "Answers typed turns.",
                 "options": [["value": "gpt-6-luna", "label": "gpt-6-luna — fastest"], ["value": "gpt-6-sol", "label": "gpt-6-sol — stronger"]],
                 "default": "gpt-6-luna"] as [String: Any],
                ["key": "text_temperature", "path": "text", "type": "float", "label": "Text temperature", "help": "", "min": 0, "max": 2] as [String: Any],
                ["key": "voice_speed", "path": "voice", "type": "float", "label": "Speaking speed", "help": "",
                 "min": 0.25, "max": 1.5, "default": 1, "mid_call": true] as [String: Any],
            ],
            "guidance_max_length": 8000,
            "history": [
                ["id": 4, "actor_kind": "agent", "actor": "live conversation #7", "live_conversation_id": 7,
                 "changes": ["guidance": ["before": "", "after": "Keep answers short."], "voice_speed": ["before": 1, "after": 0.75]] as [String: Any],
                 "created_at": "2026-10-16T11:59:00Z"] as [String: Any],
                ["id": 3, "actor_kind": "human", "actor": "the iOS app", "live_conversation_id": NSNull(),
                 "changes": ["text_model": ["before": NSNull(), "after": "gpt-6-sol"] as [String: Any]] as [String: Any],
                 "created_at": "2026-10-16T11:00:00Z"] as [String: Any],
            ],
        ]
        if written {
            json["changed"] = true
            json["summary"] = "Speaking speed 0.75."
        }
        return json
    }

    func testLiveSettingsDecodeWithTheirFieldsAndHistory() async throws {
        let (api, transport) = client([{ _ in Fixtures.json(200, LiveAPITests.settings()) }])
        let settings = try await api.liveSettings()
        XCTAssertEqual(transport.sent.first?.url.path, "/api/v1/live/settings")
        XCTAssertEqual(transport.sent.first?.method, "GET")
        XCTAssertEqual(settings.value("text_model"), .string("gpt-6-sol"))
        XCTAssertEqual(settings.value("voice_speed"), .number(0.75))
        XCTAssertEqual(settings.value("text_temperature"), .null, "a setting with no value is null, not missing")
        XCTAssertTrue(settings.isOverridden("voice_speed"))
        XCTAssertFalse(settings.isOverridden("text_temperature"))
        XCTAssertEqual(settings.guidance, "Keep answers short.")
        XCTAssertEqual(settings.guidanceMaxLength, 8000)
        XCTAssertNotNil(settings.updatedAt)
        XCTAssertNil(settings.changed, "a read carries no write's answer")

        XCTAssertEqual(settings.fields(on: "text").map(\.key), ["text_model", "text_temperature"])
        XCTAssertEqual(settings.fields(on: "voice").map(\.key), ["voice_speed"])
        let model = settings.fields[0]
        XCTAssertEqual(model.type, .choice)
        XCTAssertEqual(model.options.map(\.value), ["gpt-6-luna", "gpt-6-sol"])
        XCTAssertEqual(model.defaultValue, .string("gpt-6-luna"))
        XCTAssertEqual(model.label(for: .string("gpt-6-sol")), "gpt-6-sol — stronger")
        XCTAssertNil(settings.fields[1].defaultValue, "no default is \"not set\"")
        let speed = settings.fields[2]
        XCTAssertEqual(speed.type, .float)
        XCTAssertEqual(speed.min, 0.25)
        XCTAssertEqual(speed.max, 1.5)
        XCTAssertEqual(speed.midCall, true)
        XCTAssertEqual(speed.defaultValue?.liveSettingText, "1", "a whole number reads without its .0")

        XCTAssertEqual(settings.history.map(\.id), [4, 3])
        let agent = settings.history[0]
        XCTAssertTrue(agent.byAgent)
        XCTAssertTrue(agent.touchesGuidance)
        XCTAssertEqual(agent.liveConversationID, 7)
        XCTAssertEqual(agent.keys, ["guidance", "voice_speed"])
        XCTAssertEqual(agent.changes["voice_speed"]?.after, .number(0.75))
        let person = settings.history[1]
        XCTAssertFalse(person.byAgent)
        XCTAssertFalse(person.touchesGuidance)
        XCTAssertNil(person.liveConversationID)
        XCTAssertNil(person.changes["text_model"]?.before, "a setting that was not set reads as nil before")
    }

    func testLiveSettingsWritesAndTheMidCallSessionUpdate() async throws {
        let (api, transport) = client([
            { _ in Fixtures.json(200, LiveAPITests.settings(written: true)) },
            { _ in Fixtures.json(200, LiveAPITests.settings(written: true)) },
            { _ in Fixtures.json(200, LiveAPITests.settings(written: true)) },
            { _ in Fixtures.json(200, ["session": ["type": "realtime", "audio": ["output": ["speed": 0.75]]] as [String: Any]]) },
        ])
        let written = try await api.updateLiveSettings([
            "voice_speed": .number(0.75), "text_max_output_tokens": .number(512), "text_model": .string("default"),
        ])
        XCTAssertEqual(written.changed, true)
        XCTAssertEqual(written.summary, "Speaking speed 0.75.")
        XCTAssertEqual(transport.sent[0].method, "PATCH")
        let sent = try body(transport.sent[0])
        XCTAssertEqual((sent["voice_speed"] as? NSNumber)?.doubleValue, 0.75)
        XCTAssertEqual((sent["text_max_output_tokens"] as? NSNumber)?.intValue, 512)
        XCTAssertEqual(sent["text_model"] as? String, "default")
        XCTAssertEqual(sent.count, 3, "only what was passed is sent")

        _ = try await api.resetLiveSettings()
        _ = try await api.restoreLiveGuidance(changeID: 4)
        let session = try await api.liveSessionUpdate(7)
        XCTAssertEqual(transport.sent.map(\.url.path), [
            "/api/v1/live/settings", "/api/v1/live/settings/reset", "/api/v1/live/settings/changes/4/restore_guidance",
            "/api/v1/live_conversations/7/session_update",
        ])
        XCTAssertEqual(transport.sent.dropFirst().map(\.method), ["POST", "POST", "POST"])
        XCTAssertEqual(session["audio"]?["output"]?["speed"], .number(0.75))
    }

    func testTheFixturesLiveSettingsApplyChangesAndRestoreTheGuidance() async throws {
        let api = FakeZimmerAPI()
        let start = try await api.liveSettings()
        XCTAssertEqual(start.value("voice_speed"), .number(1))
        XCTAssertEqual(start.guidance, "")

        let faster = try await api.updateLiveSettings(["voice_speed": .number(3), "guidance": .string("Be brief.")])
        XCTAssertEqual(faster.changed, true)
        XCTAssertEqual(faster.value("voice_speed"), .number(1.5), "a number is clamped to its range")
        XCTAssertEqual(faster.guidance, "Be brief.")
        XCTAssertEqual(faster.overrides, ["voice_speed"])
        await XCTAssertThrowsAsync(try await api.updateLiveSettings(["voice_name": .string("nobody")]), "a choice not offered is refused")

        let change = try XCTUnwrap(faster.history.first)
        XCTAssertTrue(change.touchesGuidance)
        let restored = try await api.restoreLiveGuidance(changeID: change.id)
        XCTAssertEqual(restored.guidance, "")
        let reset = try await api.resetLiveSettings()
        XCTAssertEqual(reset.value("voice_speed"), .number(1))
        XCTAssertEqual(reset.overrides, [])
    }

    func testTheFixtureKeepsOneOpenConversationAndAnswersTypedMessages() async throws {
        let api = FakeZimmerAPI()
        let first = try await api.startLiveConversation(.text)
        let second = try await api.startLiveConversation(.text)
        let overview = try await api.liveConversations()
        XCTAssertEqual(overview.current, second.id)
        XCTAssertEqual(overview.conversations.first { $0.id == first.id }?.status, .ended)
        XCTAssertEqual(overview.conversations.first { $0.id == 21 }?.status, .ended, "starting ends the open voice conversation too")

        _ = try await api.sendLiveMessage(second.id, content: "please look into the poller")
        let turns = try await api.liveConversation(second.id, afterTurn: nil).turns ?? []
        XCTAssertEqual(turns.map(\.role), [.user, .tool, .assistant])
        let newer = try await api.liveConversation(second.id, afterTurn: turns[0].id).turns ?? []
        XCTAssertEqual(newer.count, 2)
        await XCTAssertThrowsAsync(try await api.sendLiveMessage(first.id, content: "again"), "an ended conversation takes no messages")
        await XCTAssertThrowsAsync(try await api.liveClientSecret(second.id), "no secret while voice is off")

        let spoken = try await api.setLiveMode(second.id, mode: .voice)
        XCTAssertEqual(spoken.model, "gpt-realtime-2.1-mini")
        await XCTAssertThrowsAsync(try await api.sendLiveMessage(second.id, content: "typed"), "no typing while voice is on")
        _ = try await api.liveClientSecret(second.id)
        let typed = try await api.setLiveMode(second.id, mode: .text)
        XCTAssertEqual(typed.mode, .text)
        let after = try await api.liveConversation(second.id, afterTurn: nil)
        XCTAssertEqual(after.turns?.count, 3, "the thread survives the switch")
    }
}

final class RealtimeConductorTests: XCTestCase {
    private func event(_ json: String) -> JSONValue { JSONValue.parse(json)! }

    private func sent(_ effects: [RealtimeConductor.Effect]) -> [String] {
        effects.compactMap { effect in
            if case let .send(value) = effect {
                let type = value["type"]?.string ?? "?"
                if let callID = value["item"]?["call_id"]?.string { return "\(type):\(callID)" }
                return type
            }
            return nil
        }
    }

    private func relays(_ effects: [RealtimeConductor.Effect]) -> [String] {
        effects.compactMap { if case let .relay(callID, _, _) = $0 { return callID } else { return nil } }
    }

    private let done = #"{"type":"response.done","response":{"status":"completed","output":[{"type":"function_call","call_id":"a1","name":"list_mcp_servers","arguments":"{}"}]}}"#

    func testACallIsRelayedThenAnsweredThenOneResponseIsRequested() {
        var conductor = RealtimeConductor()
        _ = conductor.handle(event(#"{"type":"response.created"}"#))
        let started = conductor.handle(event(#"{"type":"response.function_call_arguments.done","call_id":"a1","name":"list_mcp_servers","arguments":"{}"}"#))
        XCTAssertEqual(relays(started), ["a1"])
        XCTAssertTrue(started.contains(.state(.working)))

        XCTAssertEqual(sent(conductor.handle(event(done))), [], "the result is not in yet")
        XCTAssertEqual(sent(conductor.relayed(callID: "a1", result: LiveToolResult(output: "[]"))),
                       ["conversation.item.create:a1", "response.create"])
    }

    func testAResultThatBeatsTheResponsesEndStillGetsExactlyOneRequest() {
        var conductor = RealtimeConductor()
        _ = conductor.handle(event(#"{"type":"response.created"}"#))
        _ = conductor.handle(event(#"{"type":"response.function_call_arguments.done","call_id":"a1","name":"list_mcp_servers","arguments":"{}"}"#))
        XCTAssertEqual(sent(conductor.relayed(callID: "a1", result: LiveToolResult(output: "[]"))), ["conversation.item.create:a1"])
        XCTAssertEqual(sent(conductor.handle(event(done))), ["response.create"])
        let again = conductor.handle(event(done))
        XCTAssertEqual(sent(again), [], "a duplicate done asks for nothing more")
        XCTAssertEqual(relays(again), [], "and does not run the finished call again")
    }

    func testSeveralCallsWaitForTheLastResult() {
        var conductor = RealtimeConductor()
        _ = conductor.handle(event(#"{"type":"response.created"}"#))
        let both = #"{"type":"response.done","response":{"status":"completed","output":[{"type":"function_call","call_id":"a1","name":"x","arguments":"{}"},{"type":"function_call","call_id":"a2","name":"y","arguments":"{}"}]}}"#
        XCTAssertEqual(relays(conductor.handle(event(both))), ["a1", "a2"], "calls only seen in response.done are relayed too")
        XCTAssertEqual(sent(conductor.relayed(callID: "a2", result: LiveToolResult(output: "2"))), ["conversation.item.create:a2"])
        XCTAssertEqual(sent(conductor.relayed(callID: "a1", result: LiveToolResult(output: "1"))), ["conversation.item.create:a1", "response.create"])
    }

    func testTheRequestWaitsForAResponseAlreadyRunning() {
        var conductor = RealtimeConductor()
        _ = conductor.handle(event(#"{"type":"response.created"}"#))
        _ = conductor.handle(event(#"{"type":"response.function_call_arguments.done","call_id":"a1","name":"x","arguments":"{}"}"#))
        _ = conductor.handle(event(done))
        _ = conductor.handle(event(#"{"type":"response.created"}"#)) // the user spoke mid-tool
        XCTAssertEqual(sent(conductor.relayed(callID: "a1", result: LiveToolResult(output: "1"))), ["conversation.item.create:a1"])
        XCTAssertEqual(sent(conductor.handle(event(#"{"type":"response.done","response":{"status":"completed","output":[{"type":"message"}]}}"#))),
                       ["response.create"])
    }

    func testACancelledResponsesCallsAreNotRun() {
        var conductor = RealtimeConductor()
        _ = conductor.handle(event(#"{"type":"response.created"}"#))
        let cancelled = conductor.handle(event(#"{"type":"response.done","response":{"status":"cancelled","output":[{"type":"function_call","call_id":"c1","name":"x","arguments":"{"}]}}"#))
        XCTAssertEqual(relays(cancelled), [])
        XCTAssertEqual(sent(cancelled), [])
    }

    func testACallAlreadyRelayedForACancelledResponseIsAnsweredButNotFollowedUp() {
        var conductor = RealtimeConductor()
        _ = conductor.handle(event(#"{"type":"response.created"}"#))
        _ = conductor.handle(event(#"{"type":"response.function_call_arguments.done","call_id":"k1","name":"x","arguments":"{}"}"#))
        _ = conductor.handle(event(#"{"type":"response.done","response":{"status":"cancelled","output":[{"type":"function_call","call_id":"k1","name":"x","arguments":"{}"}]}}"#))
        XCTAssertEqual(sent(conductor.relayed(callID: "k1", result: LiveToolResult(output: "1"))), ["conversation.item.create:k1"])
        _ = conductor.handle(event(#"{"type":"response.created"}"#))
        XCTAssertEqual(sent(conductor.handle(event(#"{"type":"response.done","response":{"status":"completed","output":[{"type":"message"}]}}"#))), [],
                       "nothing was left waiting on it")
    }

    func testAToolChangeUpdatesTheSessionsTools() {
        var conductor = RealtimeConductor()
        _ = conductor.handle(event(#"{"type":"response.function_call_arguments.done","call_id":"e1","name":"enable_mcp_server","arguments":"{\"name\":\"clock\"}"}"#))
        let tools = JSONValue.parse(#"[{"type":"function","name":"clock__now"}]"#)
        let effects = conductor.relayed(callID: "e1", result: LiveToolResult(output: "Enabled", toolsChanged: true, tools: tools))
        XCTAssertEqual(sent(effects), ["conversation.item.create:e1", "session.update"])
        guard case let .send(update) = effects[1] else { return XCTFail("expected a session.update") }
        XCTAssertEqual(update["session"]?["tools"], tools)
    }

    func testASettingsChangeSendsZimmersSessionInsteadOfTheToolsOnlyOne() {
        var conductor = RealtimeConductor()
        _ = conductor.handle(event(#"{"type":"response.function_call_arguments.done","call_id":"s1","name":"zimmer","arguments":"{}"}"#))
        let tools = JSONValue.parse(#"[{"type":"function","name":"zimmer"}]"#)
        let session = JSONValue.parse(#"{"type":"realtime","instructions":"Be brief.","tools":[{"type":"function","name":"zimmer"}],"audio":{"output":{"speed":0.75}}}"#)
        let effects = conductor.relayed(callID: "s1", result: LiveToolResult(output: "Saved", toolsChanged: true, tools: tools, session: session))
        XCTAssertEqual(sent(effects), ["conversation.item.create:s1", "session.update"], "one session.update, not two")
        guard case let .send(update) = effects[1] else { return XCTFail("expected a session.update") }
        XCTAssertEqual(update, RealtimeConductor.sessionUpdate(session!))
        XCTAssertEqual(update["session"], session)
        XCTAssertEqual(update["session"]?["audio"]?["output"]?["speed"], .number(0.75))
    }

    func testASessionUpdateCarriesTheSessionAsGiven() {
        let session = JSONValue.object(["type": .string("realtime"), "max_output_tokens": .string("inf")])
        let update = RealtimeConductor.sessionUpdate(session)
        XCTAssertEqual(update["type"]?.string, "session.update")
        XCTAssertEqual(update["session"], session)
    }

    func testAFailedRelayStillAnswersTheModel() {
        var conductor = RealtimeConductor()
        _ = conductor.handle(event(#"{"type":"response.function_call_arguments.done","call_id":"f1","name":"x","arguments":"{}"}"#))
        let effects = conductor.relayed(callID: "f1", result: nil, failure: "Couldn't reach Zimmer.")
        guard case let .send(item) = effects.first else { return XCTFail("expected the output item") }
        XCTAssertEqual(item["item"]?["output"]?.string, "Zimmer could not run that: Couldn't reach Zimmer..")
    }

    func testTranscriptsAudioAndBargeIn() {
        var conductor = RealtimeConductor()
        XCTAssertEqual(conductor.handle(event(#"{"type":"conversation.item.input_audio_transcription.completed","transcript":" Is main green? "}"#)),
                       [.record(role: .user, text: "Is main green?")])
        XCTAssertEqual(conductor.handle(event(#"{"type":"response.output_audio_transcript.done","transcript":"Yes."}"#)),
                       [.record(role: .assistant, text: "Yes.")])
        XCTAssertEqual(conductor.handle(event(#"{"type":"response.output_audio.delta","item_id":"r1","delta":"AAABAA=="}"#)),
                       [.replyStarted(itemID: "r1"), .play(Data([0, 0, 1, 0])), .state(.speaking)])
        XCTAssertEqual(conductor.handle(event(#"{"type":"response.output_audio.delta","item_id":"r1","delta":"AAA="}"#)),
                       [.play(Data([0, 0])), .state(.speaking)], "the same item keeps counting")
        XCTAssertEqual(conductor.handle(event(#"{"type":"input_audio_buffer.speech_started"}"#)), [.interrupt(itemID: "r1"), .state(.listening)])
        XCTAssertEqual(conductor.handle(event(#"{"type":"input_audio_buffer.speech_started"}"#)), [.state(.listening)], "nothing left playing to cut")
        let truncate = RealtimeConductor.truncate(itemID: "r1", audioEndMs: 1_250)
        XCTAssertEqual(truncate["type"]?.string, "conversation.item.truncate")
        XCTAssertEqual(truncate["audio_end_ms"], .number(1_250))
        XCTAssertEqual(conductor.handle(event(#"{"type":"error","error":{"message":"bad"}}"#)), [.failure("bad")])
    }

    func testMicrophoneAudioIsResampledTo24kPCM16() {
        let oneSecondAt48k = [Float](repeating: 0.5, count: 48_000)
        let pcm = RealtimeAudio.pcm16(from: oneSecondAt48k, sampleRate: 48_000)
        XCTAssertEqual(pcm.count, 24_000 * 2)
        let back = RealtimeAudio.floats(fromPCM16: pcm)
        XCTAssertEqual(back.count, 24_000)
        XCTAssertEqual(back[100], 0.5, accuracy: 0.001)
        XCTAssertEqual(RealtimeAudio.pcm16(from: [2, -2], sampleRate: 24_000), Data([0xFF, 0x7F, 0x01, 0x80]), "clamped to the 16-bit range")

        let append = RealtimeConductor.appendAudio(Data([1, 2]))
        XCTAssertEqual(append["type"]?.string, "input_audio_buffer.append")
        XCTAssertEqual(append["audio"]?.string, "AQI=")
    }

    func testAMutedMicrophoneSendsSilenceSoTheTurnCanEnd() {
        let muted = RealtimeConductor.appendAudio(Data([1, 2, 3, 4]), muted: true)
        XCTAssertEqual(muted["type"]?.string, "input_audio_buffer.append", "still sent: sending nothing leaves the server's turn open")
        XCTAssertEqual(muted["audio"]?.string.flatMap { Data(base64Encoded: $0) }, Data(count: 4), "as much silence as the microphone gave")
    }

    func testAGatedCallAsksZimmerAboutEachLineAndAsksForTheReplyItself() {
        var conductor = RealtimeConductor(listening: "wake_word")
        XCTAssertTrue(conductor.gated)
        _ = conductor.handle(event(#"{"type":"response.output_audio.delta","item_id":"r1","delta":"AAA="}"#))
        XCTAssertEqual(conductor.handle(event(#"{"type":"input_audio_buffer.speech_started"}"#)), [],
                       "speech does not cut the reply off: it may not be meant for the call")
        XCTAssertEqual(conductor.handle(event(#"{"type":"conversation.item.input_audio_transcription.completed","item_id":"u1","transcript":" One Banana Republic. "}"#)),
                       [.hear(itemID: "u1", text: "One Banana Republic.")])
        XCTAssertEqual(conductor.heard(itemID: "u1", respond: false),
                       [.send(.object(["type": .string("conversation.item.delete"), "item_id": .string("u1")]))])
        XCTAssertEqual(conductor.heard(itemID: "u2", respond: true), [.send(.object(["type": .string("response.create")]))])
        XCTAssertEqual(conductor.heard(itemID: "u3", respond: true), [], "one already asked for and not yet created: a second would be refused")
        _ = conductor.handle(event(#"{"type":"response.created"}"#))
        XCTAssertEqual(conductor.handle(event(#"{"type":"response.done","response":{"status":"completed","output":[]}}"#)),
                       [.send(.object(["type": .string("response.create")])), .state(.listening)], "then the waiting one goes")
    }

    func testAGatedLineNobodyCouldReadIsDropped() {
        var conductor = RealtimeConductor(listening: "dynamic")
        let delete = { (id: String) in
            [RealtimeConductor.Effect.send(.object(["type": .string("conversation.item.delete"), "item_id": .string(id)])), .state(.listening)]
        }
        XCTAssertEqual(conductor.handle(event(#"{"type":"conversation.item.input_audio_transcription.completed","item_id":"u1","transcript":"  "}"#)), delete("u1"))
        XCTAssertEqual(conductor.handle(event(#"{"type":"conversation.item.input_audio_transcription.failed","item_id":"u2"}"#)), delete("u2"))
        var always = RealtimeConductor()
        XCTAssertEqual(always.handle(event(#"{"type":"conversation.item.input_audio_transcription.failed","item_id":"u2"}"#)), [])
    }

    func testARefusedRequestDoesNotBlockTheNext() {
        var conductor = RealtimeConductor(listening: "wake_word")
        _ = conductor.heard(itemID: "u1", respond: true)
        _ = conductor.handle(event(#"{"type":"error","error":{"message":"Conversation already has an active response"}}"#))
        XCTAssertEqual(conductor.heard(itemID: "u2", respond: true), [.send(.object(["type": .string("response.create")]))])
    }

    func testAGatedReplyWaitsForAResponseAlreadyRunning() {
        var conductor = RealtimeConductor(listening: "dynamic")
        _ = conductor.handle(event(#"{"type":"response.created"}"#))
        XCTAssertEqual(conductor.heard(itemID: "u1", respond: true), [], "never on top of a running response")
        XCTAssertEqual(conductor.handle(event(#"{"type":"response.done","response":{"status":"completed","output":[]}}"#)),
                       [.send(.object(["type": .string("response.create")])), .state(.listening)])
    }

    func testTheSessionOpenAIAppliedSaysWhetherTheCallIsGated() {
        var conductor = RealtimeConductor(listening: "always")
        XCTAssertFalse(conductor.gated)
        XCTAssertEqual(conductor.handle(event(#"{"type":"conversation.item.input_audio_transcription.completed","item_id":"u1","transcript":"hi"}"#)),
                       [.record(role: .user, text: "hi")])
        _ = conductor.handle(event(#"{"type":"session.updated","session":{"type":"realtime","audio":{"input":{"turn_detection":{"type":"semantic_vad","create_response":false}}}}}"#))
        XCTAssertTrue(conductor.gated)
        _ = conductor.handle(event(#"{"type":"session.updated","session":{"type":"realtime","tools":[]}}"#))
        XCTAssertTrue(conductor.gated, "a session without turn detection leaves it as it was")
        _ = conductor.handle(event(#"{"type":"response.function_call_arguments.done","call_id":"f1","name":"update_live_settings","arguments":"{}"}"#))
        _ = conductor.relayed(callID: "f1", result: LiveToolResult(output: "ok", session: JSONValue.parse(#"{"audio":{"input":{"turn_detection":{"create_response":true}}}}"#)))
        XCTAssertTrue(conductor.gated, "what was sent changes nothing until OpenAI says it applied it")
        _ = conductor.handle(event(#"{"type":"session.created","session":{"audio":{"input":{"turn_detection":{"create_response":true}}}}}"#))
        XCTAssertFalse(conductor.gated)
    }

    func testMutedIsSaidBesideTheCallsState() {
        XCTAssertEqual(LiveVoiceState.speaking.label(muted: true), "Speaking · Muted")
        XCTAssertEqual(LiveVoiceState.listening.label(muted: false), "Listening")
        XCTAssertEqual(LiveVoiceState.idle.label(muted: true), "Call ended")
    }

    func testAFailedResponseSaysWhyAndGoesBackToListening() {
        var conductor = RealtimeConductor()
        _ = conductor.handle(event(#"{"type":"response.created"}"#))
        XCTAssertEqual(
            conductor.handle(event(#"{"type":"response.done","response":{"status":"failed","status_details":{"type":"failed","error":{"type":"invalid_request_error","message":"Invalid turn_detection"}},"output":[]}}"#)),
            [.failure("Invalid turn_detection"), .state(.listening)]
        )
        XCTAssertEqual(
            conductor.handle(event(#"{"type":"response.done","response":{"status":"failed","output":[]}}"#)),
            [.failure("OpenAI could not answer that."), .state(.listening)]
        )
    }
}
