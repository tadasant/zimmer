import Foundation

/// The fake's live conversations: one Live Mode thread already under way with voice on (a spoken
/// question, a delegation through the Zimmer gateway, a spoken answer), so the screens have
/// something to show, and typed turns that are answered at once.
struct FakeLiveState: Sendable {
    var conversations: [Int: LiveConversation]
    var turns: [Int: [LiveTurn]]
    var nextConversationID = 30
    var nextTurnID = 500
    /// The Live settings set away from their default, by key.
    var settingOverrides: [String: JSONValue] = [:]
    var guidance = ""
    var settingsHistory: [LiveSettingChange] = []
    var nextSettingChangeID = 1
    /// Every call-telemetry batch the app sent.
    var telemetryBatches: [LiveTelemetryBatch] = []

    /// A few of the server's fields, enough for the settings screen to show each kind.
    static let settingFields: [LiveSettingField] = [
        LiveSettingField(key: "text_model", path: "text", type: .choice, label: "Text model",
                         help: "Answers typed turns, through Chat Completions with tools.",
                         options: [.init(value: "gpt-6-luna", label: "gpt-6-luna — fastest (today's default)"),
                                   .init(value: "gpt-6-sol", label: "gpt-6-sol — stronger, slower")],
                         defaultValue: .string("gpt-6-luna")),
        LiveSettingField(key: "voice_name", path: "voice", type: .choice, label: "Voice",
                         help: "Takes effect on the next call: OpenAI fixes a call's voice once it has spoken.",
                         options: ["marin", "cedar", "alloy", "verse"].map { LiveSettingField.Option(value: $0, label: $0) },
                         defaultValue: .string("marin"), midCall: false),
        LiveSettingField(key: "voice_speed", path: "voice", type: .float, label: "Speaking speed",
                         help: "A multiple of normal speed, 0.25 to 1.5. Changes mid-call, from the next reply.",
                         min: 0.25, max: 1.5, defaultValue: .number(1.0), midCall: true),
    ]

    static func sample() -> FakeLiveState {
        let voice = LiveConversation(
            id: 21, mode: .voice, status: .active, title: "Live Mode · this morning", agentRoot: "live-mode",
            model: "gpt-realtime-2.1-mini", instructionsSource: "tadasant/tadasant-internal@4f2a9c:artifacts/agent-roots/live-mode/AGENTS.md",
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
    /// The fake keeps no record of which client spoke: the same one answers for every surface.
    public nonisolated func live(from surface: ClientSource.Surface) -> any LiveAPI { self }

    public func liveAvailability() async throws -> LiveAvailability {
        LiveAvailability(agentRoot: "live-mode", available: true,
                         models: [.text: "gpt-6-luna", .voice: "gpt-realtime-2.1-mini"])
    }

    public func liveConversations() async throws -> LiveOverview {
        let all = liveState.conversations.values.sorted { $0.id > $1.id }
        return LiveOverview(conversations: all, current: all.first { $0.status.isOpen }?.id)
    }

    public func liveConversation(_ id: Int, afterTurn: Int?) async throws -> LiveConversation {
        guard let conversation = liveState.conversations[id] else { throw ZimmerError.http(status: 404, message: "Live conversation not found") }
        let turns = (liveState.turns[id] ?? []).filter { afterTurn == nil || $0.id > afterTurn! }
        return conversation.with(turns: turns)
    }

    public func startLiveConversation(_ mode: LiveMode) async throws -> LiveConversation {
        for (id, conversation) in liveState.conversations where conversation.status.isOpen {
            liveState.conversations[id] = conversation.with(status: .ended)
        }
        let id = liveState.nextConversationID
        liveState.nextConversationID += 1
        let conversation = LiveConversation(
            id: id, mode: mode, status: .active, title: "Live Mode · now", agentRoot: "live-mode",
            model: Self.liveModel(mode), mcpServers: ["zimmer"]
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

    public func setLiveMode(_ id: Int, mode: LiveMode) async throws -> LiveConversation {
        guard let conversation = liveState.conversations[id], conversation.status.isOpen else {
            throw ZimmerError.http(status: 409, message: "This conversation has ended. Start a new one.")
        }
        let switched = conversation.with(mode: mode)
        liveState.conversations[id] = switched
        return switched
    }

    static func liveModel(_ mode: LiveMode) -> String { mode == .voice ? "gpt-realtime-2.1-mini" : "gpt-6-luna" }

    /// Answers at once, as the reply job would a moment later: a delegation for anything that
    /// sounds like work, a short answer otherwise.
    public func sendLiveMessage(_ id: Int, content: String) async throws -> LiveTurn {
        guard let conversation = liveState.conversations[id], conversation.status.isOpen else {
            throw ZimmerError.http(status: 409, message: "This conversation has ended. Start a new one.")
        }
        guard conversation.mode == .text else { throw ZimmerError.http(status: 422, message: "Voice is on for this conversation. Turn it off to type.") }
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
        guard liveState.conversations[id]?.mode == .voice else { throw ZimmerError.http(status: 409, message: "Voice is off for this conversation. Turn it on first.") }
        return LiveClientSecret(clientSecret: "ek_fixture", model: "gpt-realtime-2.1-mini",
                                websocketURL: URL(string: "wss://realtime.invalid/v1/realtime?model=gpt-realtime-2.1-mini")!)
    }

    public func reportLiveTelemetry(_ batch: LiveTelemetryBatch) async throws -> LiveTelemetryAnswer {
        liveState.telemetryBatches.append(batch)
        return LiveTelemetryAnswer(accepted: batch.events.count, telemetry: "debug")
    }

    public func relayLiveToolCall(_ id: Int, name: String, arguments: String, callID: String) async throws -> LiveToolResult {
        _ = appendLiveTurn(id, LiveTurn(id: 0, role: .tool, toolName: name, toolOutput: "ok"))
        return LiveToolResult(output: "ok")
    }

    public func recordLiveTurn(_ id: Int, role: LiveTurn.Role, content: String, gated: Bool) async throws -> LiveHeard {
        _ = appendLiveTurn(id, LiveTurn(id: 0, role: role, source: "spoken", content: content))
        return LiveHeard(respond: true)
    }

    public func liveSessionUpdate(_ id: Int) async throws -> JSONValue {
        guard liveState.conversations[id]?.status == .active else { throw ZimmerError.http(status: 409, message: "This conversation is not active.") }
        let speed = liveState.settingOverrides["voice_speed"] ?? .number(1.0)
        return .object(["type": .string("realtime"), "audio": .object(["output": .object(["speed": speed])])])
    }

    public func liveSettings() async throws -> LiveSettings {
        liveSettingsPayload()
    }

    /// The server's rules, in small: an unknown key or a choice not offered is refused with
    /// nothing saved, a number is clamped to its range, `""` or `"default"` puts a setting back.
    public func updateLiveSettings(_ changes: [String: JSONValue]) async throws -> LiveSettings {
        var overrides = liveState.settingOverrides
        var guidance = liveState.guidance
        var problems: [String] = []
        for (key, value) in changes {
            switch key {
            case "guidance":
                guidance = value.liveSettingText.trimmingCharacters(in: .whitespacesAndNewlines)
            case "append_guidance":
                let line = value.liveSettingText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !line.isEmpty { guidance = guidance.isEmpty ? line : guidance + "\n" + line }
            default:
                guard let field = FakeLiveState.settingFields.first(where: { $0.key == key }) else {
                    problems.append("\(key) is not a Live setting.")
                    continue
                }
                let text = value.liveSettingText
                if text.isEmpty || text == "default" {
                    overrides[key] = nil
                } else if field.type == .choice {
                    if field.options.contains(where: { $0.value == text }) { overrides[key] = .string(text) }
                    else { problems.append("\(text) is not a choice for \(field.label).") }
                } else if var number = value.number {
                    if let low = field.min { number = Swift.max(low, number) }
                    if let high = field.max { number = Swift.min(high, number) }
                    overrides[key] = .number(field.type == .integer ? number.rounded() : number)
                } else {
                    problems.append("\(field.label) takes a number.")
                }
            }
        }
        guard problems.isEmpty else { throw ZimmerError.http(status: 422, message: problems.joined(separator: " ")) }
        return recordSettings(overrides: overrides, guidance: guidance)
    }

    public func resetLiveSettings() async throws -> LiveSettings {
        recordSettings(overrides: [:], guidance: liveState.guidance)
    }

    public func restoreLiveGuidance(changeID: Int) async throws -> LiveSettings {
        guard let change = liveState.settingsHistory.first(where: { $0.id == changeID }) else {
            throw ZimmerError.http(status: 404, message: "Settings change not found")
        }
        guard let diff = change.changes["guidance"] else {
            throw ZimmerError.http(status: 422, message: "That edit did not touch the guidance")
        }
        return recordSettings(overrides: liveState.settingOverrides, guidance: diff.before?.liveSettingText ?? "")
    }

    private func effectiveSetting(_ key: String, in overrides: [String: JSONValue]) -> JSONValue {
        overrides[key] ?? FakeLiveState.settingFields.first { $0.key == key }?.defaultValue ?? .null
    }

    /// Saves what changed as one history entry, a person's, and answers as a write does.
    private func recordSettings(overrides: [String: JSONValue], guidance: String) -> LiveSettings {
        var diff: [String: LiveSettingChange.Diff] = [:]
        for field in FakeLiveState.settingFields {
            let before = effectiveSetting(field.key, in: liveState.settingOverrides)
            let after = effectiveSetting(field.key, in: overrides)
            if before != after { diff[field.key] = LiveSettingChange.Diff(before: before, after: after) }
        }
        if guidance != liveState.guidance { diff["guidance"] = LiveSettingChange.Diff(before: .string(liveState.guidance), after: .string(guidance)) }
        guard !diff.isEmpty else { return liveSettingsPayload(changed: false, summary: "Nothing changed.") }
        liveState.settingOverrides = overrides
        liveState.guidance = guidance
        let change = LiveSettingChange(id: liveState.nextSettingChangeID, actorKind: "human", actor: "the iOS app",
                                       changes: diff, createdAt: Date())
        liveState.nextSettingChangeID += 1
        liveState.settingsHistory.insert(change, at: 0)
        return liveSettingsPayload(changed: true, summary: "Changed \(change.keys.joined(separator: ", ")).")
    }

    private func liveSettingsPayload(changed: Bool? = nil, summary: String? = nil) -> LiveSettings {
        let fields = FakeLiveState.settingFields
        var settings: [String: JSONValue] = [:]
        for field in fields { settings[field.key] = effectiveSetting(field.key, in: liveState.settingOverrides) }
        return LiveSettings(settings: settings, overrides: liveState.settingOverrides.keys.sorted(), guidance: liveState.guidance,
                            updatedAt: liveState.settingsHistory.first?.createdAt,
                            updatedBy: liveState.settingsHistory.first.map { "\($0.actorKind):\($0.actor)" },
                            fields: fields, history: liveState.settingsHistory, changed: changed, summary: summary)
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
    func with(status: Status? = nil, mode: LiveMode? = nil, turns: [LiveTurn]? = nil) -> LiveConversation {
        LiveConversation(id: id, mode: mode ?? self.mode, status: status ?? self.status, title: title, agentRoot: agentRoot,
                         model: mode.map(FakeZimmerAPI.liveModel) ?? model,
                         instructionsSource: instructionsSource, mcpServers: mcpServers, responding: responding,
                         errorMessage: errorMessage, turns: turns ?? self.turns)
    }
}
