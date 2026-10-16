import XCTest
@testable import ZimmerKit

/// Live Mode and Live Voice: what the app sends and reads over `/api/v1/live*`, and the Realtime
/// sequencing a Live Voice call runs (the same rules as the web's call dock).
final class LiveAPITests: XCTestCase {
    private func client(_ handlers: [ScriptedTransport.Handler]) -> (ZimmerHTTPClient, ScriptedTransport) {
        let transport = ScriptedTransport(handlers)
        return (ZimmerHTTPClient(auth: AuthSession(store: Fixtures.signedIn(), transport: transport), transport: transport), transport)
    }

    private func body(_ request: HTTPRequest) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: request.body ?? Data()) as? [String: Any])
    }

    private static func conversation() -> [String: Any] { [
        "id": 7, "mode": "voice", "label": "Live Voice", "status": "active", "title": "Live Voice · Oct 15",
        "agent_root": "live-voice", "model": "gpt-realtime-2.1-mini", "instructions_source": "x@abc:AGENTS.md",
        "mcp_servers": ["zimmer", "demo-clock"], "responding": false, "error_message": NSNull(),
        "turns": [
            ["id": 1, "role": "user", "source": "spoken", "content": "Is main green?", "tool_name": NSNull(), "tool_arguments": NSNull(), "tool_output": NSNull(), "tool_error": false],
            ["id": 2, "role": "tool", "source": NSNull(), "content": NSNull(), "tool_name": "zimmer", "call_id": "c1",
             "tool_arguments": ["tool": "quick_router", "arguments": ["prompt": "check main"]], "tool_output": "Started #9", "tool_error": false],
        ],
    ] }

    func testModesDecodeWithTheirReasons() async throws {
        let (api, transport) = client([{ _ in Fixtures.json(200, ["modes": [
            ["mode": "text", "label": "Live Mode", "agent_root": "live-mode", "model": "gpt-6-luna", "available": true, "key_configured": true, "root_present": true, "reasons": []],
            ["mode": "voice", "label": "Live Voice", "agent_root": "live-voice", "model": "gpt-realtime-2.1-mini", "available": false, "key_configured": false, "root_present": true,
             "reasons": ["LIVE_OPENAI_API_KEY is not set."]],
        ]]) }])
        let modes = try await api.liveModes()
        XCTAssertEqual(transport.sent.first?.url.path, "/api/v1/live")
        XCTAssertEqual(modes.map(\.mode), [.text, .voice])
        XCTAssertFalse(modes[1].available)
        XCTAssertEqual(modes[1].reasons, ["LIVE_OPENAI_API_KEY is not set."])
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

    func testTheIndexMapsEachModesCurrentConversation() async throws {
        let (api, _) = client([{ _ in Fixtures.json(200, ["live_conversations": [LiveAPITests.conversation()], "current": ["text": NSNull(), "voice": 7]]) }])
        let overview = try await api.liveConversations()
        XCTAssertEqual(overview.current, [.voice: 7])
        XCTAssertEqual(overview.conversations.map(\.id), [7])
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
                                       "websocket_url": "wss://api.openai.com/v1/realtime?model=gpt-realtime-2.1-mini", "tools": []]) },
            { _ in Fixtures.json(200, ["output": "Enabled demo-clock.", "error": false, "tools_changed": true, "turn_id": 4,
                                       "tools": [["type": "function", "name": "demo-clock__current_time"]]]) },
            { _ in Fixtures.json(201, ["id": 5, "role": "assistant", "source": "spoken", "content": "Done.", "tool_error": false]) },
        ])
        let secret = try await api.liveClientSecret(7)
        XCTAssertEqual(secret.clientSecret, "ek_1")
        XCTAssertEqual(secret.websocketURL.absoluteString, "wss://api.openai.com/v1/realtime?model=gpt-realtime-2.1-mini")

        let result = try await api.relayLiveToolCall(7, name: "enable_mcp_server", arguments: "{\"name\":\"demo-clock\"}", callID: "call_1")
        XCTAssertTrue(result.toolsChanged)
        XCTAssertEqual(result.tools?.array?.first?["name"]?.string, "demo-clock__current_time")
        let relay = try body(transport.sent[1])
        XCTAssertEqual(relay["name"] as? String, "enable_mcp_server")
        XCTAssertEqual(relay["arguments"] as? String, "{\"name\":\"demo-clock\"}")
        XCTAssertEqual(relay["call_id"] as? String, "call_1")

        _ = try await api.recordLiveTurn(7, role: .assistant, content: "Done.")
        XCTAssertEqual(transport.sent.map(\.url.path).suffix(2), ["/api/v1/live_conversations/7/tool_calls", "/api/v1/live_conversations/7/turns"])
        XCTAssertEqual(try body(transport.sent[2])["role"] as? String, "assistant")
    }

    func testAStatusThisVersionDoesNotKnowReadsAsEnded() throws {
        var json = LiveAPITests.conversation()
        json["status"] = "archived_somehow"
        let data = try JSONSerialization.data(withJSONObject: json)
        let conversation = try ZimmerJSON.decoder.decode(LiveConversation.self, from: data)
        XCTAssertEqual(conversation.status, .ended)
        XCTAssertFalse(conversation.status.isOpen)
    }

    func testTheFixtureKeepsOneOpenConversationPerModeAndAnswersTypedMessages() async throws {
        let api = FakeZimmerAPI()
        let first = try await api.startLiveConversation(.text)
        let second = try await api.startLiveConversation(.text)
        let overview = try await api.liveConversations()
        XCTAssertEqual(overview.current[.text], second.id)
        XCTAssertEqual(overview.conversations.first { $0.id == first.id }?.status, .ended)

        _ = try await api.sendLiveMessage(second.id, content: "please look into the poller")
        let turns = try await api.liveConversation(second.id, afterTurn: nil).turns ?? []
        XCTAssertEqual(turns.map(\.role), [.user, .tool, .assistant])
        let newer = try await api.liveConversation(second.id, afterTurn: turns[0].id).turns ?? []
        XCTAssertEqual(newer.count, 2)
        await XCTAssertThrowsAsync(try await api.sendLiveMessage(first.id, content: "again"), "an ended conversation takes no messages")
        await XCTAssertThrowsAsync(try await api.sendLiveMessage(21, content: "typed"), "a voice conversation takes no typed messages")
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
}
