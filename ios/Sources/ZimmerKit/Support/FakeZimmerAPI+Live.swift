import Foundation

/// The fake's live conversations: one Live Voice thread already under way (a spoken question,
/// a delegation through the Zimmer gateway, a spoken answer), so the screens have something to
/// show, and a Live Mode that answers every typed message.
struct FakeLiveState: Sendable {
    var conversations: [Int: LiveConversation]
    var turns: [Int: [LiveTurn]]
    var nextConversationID = 30
    var nextTurnID = 500

    static func sample() -> FakeLiveState {
        let voice = LiveConversation(
            id: 21, mode: .voice, status: .active, title: "Live Voice · this morning", agentRoot: "live-voice",
            model: "gpt-realtime-2.1-mini", instructionsSource: "tadasant/tadasant-internal@4f2a9c:artifacts/agent-roots/live-voice/AGENTS.md",
            mcpServers: ["zimmer"]
        )
        let turns: [LiveTurn] = [
            LiveTurn(id: 401, role: .user, source: "spoken", content: "Is the flaky poller test still failing on main?"),
            LiveTurn(id: 402, role: .tool, toolName: "zimmer", zimmerTool: "quick_router",
                     toolOutput: "Started session #1101 — Investigate the flaky transcript poller test"),
            LiveTurn(id: 403, role: .assistant, source: "spoken",
                     content: "I've started a session to look into it. I'll tell you what it finds."),
        ]
        return FakeLiveState(conversations: [21: voice], turns: [21: turns])
    }
}

extension FakeZimmerAPI {
    public func liveModes() async throws -> [LiveModeAvailability] {
        [
            LiveModeAvailability(mode: .voice, label: "Live Voice", agentRoot: "live-voice", model: "gpt-realtime-2.1-mini", available: true, reasons: []),
            LiveModeAvailability(mode: .text, label: "Live Mode", agentRoot: "live-mode", model: "gpt-6-luna", available: true, reasons: []),
        ]
    }

    public func liveConversations() async throws -> LiveOverview {
        let all = liveState.conversations.values.sorted { $0.id > $1.id }
        var current: [LiveMode: Int] = [:]
        for conversation in all where conversation.status.isOpen && current[conversation.mode] == nil {
            current[conversation.mode] = conversation.id
        }
        return LiveOverview(conversations: all, current: current)
    }

    public func liveConversation(_ id: Int, afterTurn: Int?) async throws -> LiveConversation {
        guard let conversation = liveState.conversations[id] else { throw ZimmerError.http(status: 404, message: "Live conversation not found") }
        let turns = (liveState.turns[id] ?? []).filter { afterTurn == nil || $0.id > afterTurn! }
        return conversation.with(turns: turns)
    }

    public func startLiveConversation(_ mode: LiveMode) async throws -> LiveConversation {
        for (id, conversation) in liveState.conversations where conversation.mode == mode && conversation.status.isOpen {
            liveState.conversations[id] = conversation.with(status: .ended)
        }
        let id = liveState.nextConversationID
        liveState.nextConversationID += 1
        let conversation = LiveConversation(
            id: id, mode: mode, status: .active, title: "\(mode.label) · now", agentRoot: mode == .voice ? "live-voice" : "live-mode",
            model: mode == .voice ? "gpt-realtime-2.1-mini" : "gpt-6-luna", mcpServers: ["zimmer"]
        )
        liveState.conversations[id] = conversation
        liveState.turns[id] = []
        return conversation
    }

    public func finishLiveConversation(_ id: Int) async throws -> LiveConversation {
        guard let conversation = liveState.conversations[id] else { throw ZimmerError.http(status: 404, message: "Live conversation not found") }
        let ended = conversation.with(status: .ended)
        liveState.conversations[id] = ended
        return ended
    }

    /// Answers at once, as the reply job would a moment later: a delegation for anything that
    /// sounds like work, a short answer otherwise.
    public func sendLiveMessage(_ id: Int, content: String) async throws -> LiveTurn {
        guard let conversation = liveState.conversations[id], conversation.status.isOpen else {
            throw ZimmerError.http(status: 409, message: "This conversation has ended. Start a new one.")
        }
        guard conversation.mode == .text else { throw ZimmerError.http(status: 422, message: "Live Voice takes spoken turns, not typed messages.") }
        let user = appendLiveTurn(id, LiveTurn(id: 0, role: .user, source: "typed", content: content))
        if content.lowercased().contains("look into") || content.lowercased().contains("fix") {
            _ = appendLiveTurn(id, LiveTurn(id: 0, role: .tool, toolName: "zimmer", zimmerTool: "quick_router", toolOutput: "Started session #1102"))
            _ = appendLiveTurn(id, LiveTurn(id: 0, role: .assistant, content: "Started a session on that. I'll check back when it has something."))
        } else {
            _ = appendLiveTurn(id, LiveTurn(id: 0, role: .assistant, content: "Got it."))
        }
        return user
    }

    public func liveClientSecret(_ id: Int) async throws -> LiveClientSecret {
        guard liveState.conversations[id]?.mode == .voice else { throw ZimmerError.http(status: 422, message: "Not a Live Voice conversation.") }
        return LiveClientSecret(clientSecret: "ek_fixture", model: "gpt-realtime-2.1-mini",
                                websocketURL: URL(string: "wss://realtime.invalid/v1/realtime?model=gpt-realtime-2.1-mini")!)
    }

    public func relayLiveToolCall(_ id: Int, name: String, arguments: String, callID: String) async throws -> LiveToolResult {
        _ = appendLiveTurn(id, LiveTurn(id: 0, role: .tool, toolName: name, toolOutput: "ok"))
        return LiveToolResult(output: "ok")
    }

    public func recordLiveTurn(_ id: Int, role: LiveTurn.Role, content: String) async throws -> LiveTurn {
        appendLiveTurn(id, LiveTurn(id: 0, role: role, source: "spoken", content: content))
    }

    private func appendLiveTurn(_ id: Int, _ turn: LiveTurn) -> LiveTurn {
        let numbered = LiveTurn(id: liveState.nextTurnID, role: turn.role, source: turn.source, content: turn.content,
                                toolName: turn.toolName, zimmerTool: turn.zimmerTool, toolOutput: turn.toolOutput, toolError: turn.toolError)
        liveState.nextTurnID += 1
        liveState.turns[id, default: []].append(numbered)
        return numbered
    }
}

extension LiveConversation {
    func with(status: Status? = nil, turns: [LiveTurn]? = nil) -> LiveConversation {
        LiveConversation(id: id, mode: mode, status: status ?? self.status, title: title, agentRoot: agentRoot, model: model,
                         instructionsSource: instructionsSource, mcpServers: mcpServers, responding: responding,
                         errorMessage: errorMessage, turns: turns ?? self.turns)
    }
}
