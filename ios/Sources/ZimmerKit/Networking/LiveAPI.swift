import Foundation

/// Live Mode over `/api/v1/live*` — the same rules the web's `/live` pages keep
/// (`LiveConversations::Actions` on the server).
public protocol LiveAPI: Sendable {
    /// The same Live Mode calls, each saying it comes from `surface`. Zimmer records the client
    /// driving a conversation from its writes (`live_conversations.client_surface`, last writer
    /// wins), and a call from the car is what tells the live model the person is driving.
    func live(from surface: ClientSource.Surface) -> any LiveAPI
    /// Can Live Mode start, and if not, why not.
    func liveAvailability() async throws -> LiveAvailability
    /// The newest conversations and the open one.
    func liveConversations() async throws -> LiveOverview
    /// One conversation with its turns; `afterTurn` reads only turns newer than that one.
    func liveConversation(_ id: Int, afterTurn: Int?) async throws -> LiveConversation
    /// Start a fresh conversation, typed or spoken from the start, ending the open one. `standby`:
    /// from the one kept ready (`liveStandby`), which becomes the current one. `again`: this tap may
    /// have been answered already, and then it is answered the same. One that is gone starts another, so
    /// the answer says which conversation it is.
    func startLiveConversation(_ mode: LiveMode, standby: Int?, again: Bool) async throws -> LiveConversation
    /// The conversation Zimmer keeps ready for the next New, made or brought up to date. Asking ends
    /// nothing and starts nothing, and there is only ever one.
    func liveStandby() async throws -> LiveConversation
    /// Go back to an earlier conversation, ending the open one; `nil` is the one left most
    /// recently. `from` is the conversation this screen believes is current, 0 for none: another
    /// having taken over since is refused (409). The target already being current changes nothing.
    func switchLiveConversation(_ id: Int?, from: Int?) async throws -> LiveSwitch
    func finishLiveConversation(_ id: Int) async throws -> LiveConversation
    /// Typed ⇄ spoken, in the same conversation. Voice must be on before a call can mint its
    /// secret; typing waits for it to be off.
    func setLiveMode(_ id: Int, mode: LiveMode) async throws -> LiveConversation
    /// Typed: a message. The reply arrives as a later turn.
    func sendLiveMessage(_ id: Int, content: String) async throws -> LiveTurn
    /// Voice: how the call runs. The app says which engines it can run (`LiveVoiceEngine.runnable`);
    /// Zimmer answers with a Realtime secret, or, on `gpt_live_claude`, with no secret: the call
    /// starts with `startGptLiveSession`. An engine the settings chose that cannot run falls back to
    /// Realtime, and the answer says why (`LiveCallGrant.choice`). `engines`: what to say this app
    /// can run — `[]` asks for Realtime, as after GPT-Live failed to start.
    func liveCallGrant(_ id: Int, engines: [String]) async throws -> LiveCallGrant
    /// Standby: what a call on this conversation would run on, asked ahead of the tap, for a
    /// connection held ready until then (`LiveWarmStart`). On Realtime, a secret; on GPT-Live, none,
    /// and the session is started with `startGptLiveSession`. Changes nothing on the conversation and
    /// needs no voice. 409 when none may be held: paid standby is off or its daily cap is spent, or the
    /// conversation is not one a call could be on.
    func livePrewarmGrant(_ id: Int) async throws -> LiveCallGrant
    /// Voice, `gpt_live_claude`: the phone's WebRTC offer, which Zimmer starts the GPT-Live session
    /// with (the OpenAI key stays on the server); OpenAI's SDP answer back. 409 when the call is no
    /// longer to run on GPT-Live (a cap reached, the setting changed since `liveCallGrant`).
    /// `standby`: held ready for a tap, inference paused, and nothing on the conversation changed.
    func startGptLiveSession(_ id: Int, sdp: String, standby: Bool) async throws -> GptLiveAnswer
    /// Voice, `gpt_live_claude`: GPT-Live delegated a request; Claude answers it, in chunks to
    /// append as commentary. `pendingUserText`: the person's line still in flight.
    func answerLiveDelegation(_ id: Int, delegationID: String, pendingUserText: String) async throws -> LiveDelegation
    /// Voice: what the call measured about its cost and speed, for the voice-engine ledger. At most
    /// 50 events a request.
    func reportLiveUsage(_ id: Int, events: [LiveUsageEvent]) async throws
    /// Voice: run a function call the model made; send back what this returns.
    func relayLiveToolCall(_ id: Int, name: String, arguments: String, callID: String) async throws -> LiveToolResult
    /// Voice: a finished transcript line, so the thread carries what was said. `gated`: the call
    /// asks for its own replies (Listening is wake word or dynamic), so Zimmer decides whether this
    /// line is answered — and drops, unwritten, one it is not.
    func recordLiveTurn(_ id: Int, role: LiveTurn.Role, content: String, gated: Bool) async throws -> LiveHeard
    /// Voice: the `session` of a `session.update` that brings an open call up to the current
    /// Live settings and guidance — sent after they changed somewhere else, such as the settings
    /// screen.
    ///
    /// `recordingModel`: the model the call runs on, for Zimmer to record on the conversation. A
    /// call on a warm connection (`LiveWarmStart`) sends it, because its prewarm mint recorded nothing.
    func liveSessionUpdate(_ id: Int, recordingModel model: String?) async throws -> JSONValue
    /// Voice: what the app's calls did, for the shipped logs (`LiveTelemetry`). The answer
    /// carries the level in force, which the app adopts.
    func reportLiveTelemetry(_ batch: LiveTelemetryBatch) async throws -> LiveTelemetryAnswer

    /// The Live settings, each field's choices or range, the guidance, and recent history.
    func liveSettings() async throws -> LiveSettings
    /// Change some: setting keys (a string or a number; `""` or `"default"` puts one back),
    /// `guidance` to replace it, `append_guidance` to add a line. 422 on an unknown key or a
    /// value not among a field's options; a number out of range is clamped and `summary` says so.
    func updateLiveSettings(_ changes: [String: JSONValue]) async throws -> LiveSettings
    /// Every setting back to its default. The guidance is kept.
    func resetLiveSettings() async throws -> LiveSettings
    /// The guidance as it was before change `changeID`. 422 when that change did not touch it.
    func restoreLiveGuidance(changeID: Int) async throws -> LiveSettings
}

extension LiveAPI {
    /// The grant for a call, saying every engine this app can run.
    public func liveCallGrant(_ id: Int) async throws -> LiveCallGrant {
        try await liveCallGrant(id, engines: LiveVoiceEngine.runnable)
    }

    /// A fresh conversation, not from one kept ready.
    public func startLiveConversation(_ mode: LiveMode) async throws -> LiveConversation {
        try await startLiveConversation(mode, standby: nil, again: false)
    }

    /// The session for a call that is starting now.
    public func startGptLiveSession(_ id: Int, sdp: String) async throws -> GptLiveAnswer {
        try await startGptLiveSession(id, sdp: sdp, standby: false)
    }

    /// The `session.update` for an open call, recording nothing.
    public func liveSessionUpdate(_ id: Int) async throws -> JSONValue {
        try await liveSessionUpdate(id, recordingModel: nil)
    }
}

struct LiveUsageAnswer: Decodable {
    let recorded: Int?
}

struct LiveSessionUpdateResponse: Decodable {
    let session: JSONValue
}

/// `current_id` is the open conversation; a server from before voice folded into Live Mode sends
/// only `current`, keyed by mode.
struct LiveIndexResponse: Decodable {
    let live_conversations: [LiveConversation]
    let current_id: Int?
    let current: [String: Int?]?

    var currentID: Int? { current_id ?? current?.values.compactMap { $0 }.max() }
}

// `ZimmerHTTPClient: ZimmerAPI`, which refines `LiveAPI`.
extension ZimmerHTTPClient {
    public func liveAvailability() async throws -> LiveAvailability {
        try await get("/api/v1/live")
    }

    public func liveConversations() async throws -> LiveOverview {
        let response: LiveIndexResponse = try await get("/api/v1/live_conversations")
        return LiveOverview(conversations: response.live_conversations, current: response.currentID)
    }

    public func liveConversation(_ id: Int, afterTurn: Int?) async throws -> LiveConversation {
        var query: [String: String] = [:]
        if let afterTurn { query["after_turn_id"] = String(afterTurn) }
        return try await get("/api/v1/live_conversations/\(id)", query: query)
    }

    public func startLiveConversation(_ mode: LiveMode, standby: Int?, again: Bool) async throws -> LiveConversation {
        var body: [String: Any] = ["mode": mode.rawValue]
        if let standby { body["standby_id"] = standby }
        if again { body["again"] = "1" }
        return try await post("/api/v1/live_conversations", json: body)
    }

    public func liveStandby() async throws -> LiveConversation {
        try await post("/api/v1/live_conversations/standby", json: [:])
    }

    public func switchLiveConversation(_ id: Int?, from: Int?) async throws -> LiveSwitch {
        var body: [String: Any] = [:]
        if let id { body["id"] = id }
        if let from { body["from_id"] = from }
        return try await post("/api/v1/live_conversations/switch", json: body)
    }

    public func finishLiveConversation(_ id: Int) async throws -> LiveConversation {
        try await post("/api/v1/live_conversations/\(id)/finish", json: [:])
    }

    public func setLiveMode(_ id: Int, mode: LiveMode) async throws -> LiveConversation {
        try await post("/api/v1/live_conversations/\(id)/mode", json: ["mode": mode.rawValue])
    }

    public func sendLiveMessage(_ id: Int, content: String) async throws -> LiveTurn {
        try await post("/api/v1/live_conversations/\(id)/messages", json: ["content": content])
    }

    /// Says this app asks for each reply itself when Listening is gated; without it Zimmer builds
    /// the call to answer everything, the way an app from before Listening expects.
    static let listeningModes: [String: String] = ["listening_modes": "1"]

    /// What every mint sends: Listening as above, and the engines this app can run, since Zimmer
    /// picks one only for a client that can.
    static func mint(engines: [String] = LiveVoiceEngine.runnable, _ extra: [String: Any] = [:]) -> [String: Any] {
        var body: [String: Any] = listeningModes
        body["engines"] = engines
        return body.merging(extra) { $1 }
    }

    public func liveCallGrant(_ id: Int, engines: [String]) async throws -> LiveCallGrant {
        try await post("/api/v1/live_conversations/\(id)/client_secret", json: Self.mint(engines: engines))
    }

    /// With the engines, and that this app can hold a GPT-Live session in standby: Zimmer refuses
    /// (409) a GPT-Live pre-warm from one that cannot.
    public func livePrewarmGrant(_ id: Int) async throws -> LiveCallGrant {
        try await post("/api/v1/live_conversations/\(id)/client_secret",
                       json: Self.mint(["prewarm": "1", "standby": "1"]))
    }

    public func startGptLiveSession(_ id: Int, sdp: String, standby: Bool) async throws -> GptLiveAnswer {
        try await post("/api/v1/live_conversations/\(id)/gpt_live_session", json: standby ? ["sdp": sdp, "standby": "1"] : ["sdp": sdp])
    }

    public func answerLiveDelegation(_ id: Int, delegationID: String, pendingUserText: String) async throws -> LiveDelegation {
        try await post("/api/v1/live_conversations/\(id)/delegations", json: ["delegation_id": delegationID, "pending_user_text": pendingUserText])
    }

    public func reportLiveUsage(_ id: Int, events: [LiveUsageEvent]) async throws {
        guard !events.isEmpty else { return }
        let _: LiveUsageAnswer = try await post("/api/v1/live_conversations/\(id)/usage", json: ["events": events.map(\.foundationObject)])
    }

    public func relayLiveToolCall(_ id: Int, name: String, arguments: String, callID: String) async throws -> LiveToolResult {
        try await post("/api/v1/live_conversations/\(id)/tool_calls",
                       json: ["name": name, "arguments": arguments, "call_id": callID, "reattaches": "1", "hangs_up": "1"].merging(Self.listeningModes) { $1 })
    }

    public func recordLiveTurn(_ id: Int, role: LiveTurn.Role, content: String, gated: Bool) async throws -> LiveHeard {
        let line: [String: Any] = ["role": role.rawValue, "content": content]
        return try await post("/api/v1/live_conversations/\(id)/turns", json: gated ? line.merging(Self.listeningModes) { $1 } : line)
    }

    public func liveSessionUpdate(_ id: Int, recordingModel model: String?) async throws -> JSONValue {
        var body: [String: Any] = Self.listeningModes
        if let model { body["model"] = model }
        let response: LiveSessionUpdateResponse = try await post("/api/v1/live_conversations/\(id)/session_update", json: body)
        return response.session
    }

    public func reportLiveTelemetry(_ batch: LiveTelemetryBatch) async throws -> LiveTelemetryAnswer {
        let body = try JSONEncoder().encode(batch)
        let response = try await perform(method: "POST", path: "/api/v1/live/telemetry", query: [:], body: body)
        do {
            return try ZimmerJSON.decoder.decode(LiveTelemetryAnswer.self, from: response.body)
        } catch {
            throw ZimmerError.decoding("live telemetry answer: \(error)")
        }
    }

    public func liveSettings() async throws -> LiveSettings {
        try await get("/api/v1/live/settings")
    }

    public func updateLiveSettings(_ changes: [String: JSONValue]) async throws -> LiveSettings {
        try await patch("/api/v1/live/settings", json: changes.mapValues(\.foundationObject))
    }

    public func resetLiveSettings() async throws -> LiveSettings {
        try await post("/api/v1/live/settings/reset", json: [:])
    }

    public func restoreLiveGuidance(changeID: Int) async throws -> LiveSettings {
        try await post("/api/v1/live/settings/changes/\(changeID)/restore_guidance", json: [:])
    }
}
