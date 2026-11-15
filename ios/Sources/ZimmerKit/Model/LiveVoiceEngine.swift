import Foundation

/// The voice engines a call can run on (`LiveConversations::VoiceEngine` on the server). The app
/// tells Zimmer which non-default ones it can run (`engines` on `client_secret`); Zimmer answers
/// with the engine the call runs on, and when that is not the one the Live settings asked for,
/// why not.
public enum LiveVoiceEngine {
    /// OpenAI Realtime: a client secret, a WebSocket from the phone. The default.
    public static let realtime = "openai_realtime"
    /// OpenAI's GPT-Live as the full-duplex voice, Claude doing the work: a WebRTC session Zimmer
    /// starts from the phone's offer (`gpt_live_session`), and every delegation answered by
    /// Zimmer (`delegations`).
    public static let gptLive = "gpt_live_claude"
    /// What this app can run besides the default, sent on every `client_secret`.
    public static let runnable = [gptLive]
}

/// What Zimmer decided about the engine for one call: `engine` runs it, `requested` is what the
/// settings asked for, and a `fallbackReason` says why they differ. `warning`: the engine is past
/// 80% of a spend cap.
public struct LiveEngineChoice: Decodable, Sendable, Equatable {
    public let engine: String
    public let requested: String?
    public let fallbackReason: String?
    public let warning: String?

    public init(engine: String, requested: String? = nil, fallbackReason: String? = nil, warning: String? = nil) {
        self.engine = engine
        self.requested = requested
        self.fallbackReason = fallbackReason
        self.warning = warning
    }

    enum CodingKeys: String, CodingKey {
        case engine, requested, warning
        case fallbackReason = "fallback_reason"
    }

    /// What the person is told about it, or nil when there is nothing to say: the web dock's
    /// words for the same thing.
    public var note: String? {
        if let fallbackReason, !fallbackReason.isEmpty { return "On OpenAI Realtime: \(fallbackReason)." }
        if let warning, !warning.isEmpty { return warning }
        return nil
    }

    /// For a call from the car, where nothing is read: put to the Realtime model as an unrecorded
    /// line, so the driver hears why the engine they chose is not the one answering.
    public var spokenFallback: String? {
        guard let fallbackReason, !fallbackReason.isEmpty else { return nil }
        return Self.spokenLine("this call is on OpenAI Realtime, not the \(requested ?? "chosen") engine, because \(fallbackReason).")
    }

    /// Zimmer's note as a line for the Realtime model to say, briefly, before anything else.
    public static func spokenLine(_ note: String) -> String {
        "(Zimmer: \(note) Say that in one short sentence, then stop.)"
    }
}

/// `POST …/client_secret`'s answer: a Realtime secret, or — on `gpt_live_claude` — no secret, only
/// the engine, and the call starts with `startGptLiveSession`. A server from before engines sends
/// the secret alone, and that is Realtime.
public struct LiveCallGrant: Decodable, Sendable, Equatable {
    public enum Engine: Sendable, Equatable {
        case realtime(LiveClientSecret)
        case gptLive
    }

    public let engine: Engine
    /// Nil from a server from before engines.
    public let choice: LiveEngineChoice?
    public let model: String
    /// How much the app reports about the call (`LiveTelemetryLevel`, or `off`).
    public let telemetry: String?

    public init(engine: Engine, choice: LiveEngineChoice? = nil, model: String, telemetry: String? = nil) {
        self.engine = engine
        self.choice = choice
        self.model = model
        self.telemetry = telemetry
    }

    public var realtime: LiveClientSecret? {
        if case let .realtime(secret) = engine { return secret }
        return nil
    }

    public var isGptLive: Bool { engine == .gptLive }

    /// Which lines the call answers. GPT-Live does its own turn-taking and answers every one.
    public var listening: String? { realtime?.listening }

    enum CodingKeys: String, CodingKey {
        case engine, model, telemetry
        case choice = "voice_engine"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        choice = try c.decodeIfPresent(LiveEngineChoice.self, forKey: .choice)
        telemetry = try c.decodeIfPresent(String.self, forKey: .telemetry)
        let name = try c.decodeIfPresent(String.self, forKey: .engine) ?? LiveVoiceEngine.realtime
        if name == LiveVoiceEngine.gptLive {
            engine = .gptLive
            model = try c.decodeIfPresent(String.self, forKey: .model) ?? "gpt-live-1"
        } else {
            let secret = try LiveClientSecret(from: decoder)
            engine = .realtime(secret)
            model = secret.model
        }
    }
}

/// `POST …/gpt_live_session`'s answer: OpenAI's SDP answer to the phone's offer.
public struct GptLiveAnswer: Decodable, Sendable, Equatable {
    public let sessionID: String?
    public let sdp: String
    public let model: String?

    public init(sessionID: String?, sdp: String, model: String? = nil) {
        self.sessionID = sessionID
        self.sdp = sdp
        self.model = model
    }

    enum CodingKeys: String, CodingKey {
        case sdp, model
        case sessionID = "session_id"
    }
}

/// `POST …/delegations`'s answer: what Claude said, in chunks for GPT-Live to say. `endCall`: hang
/// up once it is said (the person asked to, or a spend cap was reached).
public struct LiveDelegation: Decodable, Sendable, Equatable {
    public let chunks: [String]
    public let endCall: Bool
    public let warning: String?

    public init(chunks: [String], endCall: Bool = false, warning: String? = nil) {
        self.chunks = chunks
        self.endCall = endCall
        self.warning = warning
    }

    enum CodingKeys: String, CodingKey {
        case chunks, warning, text
        case endCall = "end_call"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let chunks = try c.decodeIfPresent([String].self, forKey: .chunks)
        let text = try c.decodeIfPresent(String.self, forKey: .text)
        self.chunks = chunks ?? text.map { [$0] } ?? []
        endCall = try c.decodeIfPresent(Bool.self, forKey: .endCall) ?? false
        warning = try c.decodeIfPresent(String.self, forKey: .warning)
    }
}

/// One row for Zimmer's voice-engine ledger (`POST …/usage`, `LiveConversations::UsageReport`):
/// volumes and timings, never money. `key` is unique to the call, so a batch sent twice counts once.
public struct LiveUsageEvent: Encodable, Sendable, Equatable {
    public let engine: String
    public let operation: String
    public let key: String
    public var seconds: Double?
    public var firstAudioMs: Int?
    public var details: [String: JSONValue]?

    public init(engine: String, operation: String, key: String, seconds: Double? = nil, firstAudioMs: Int? = nil,
                details: [String: JSONValue]? = nil) {
        self.engine = engine
        self.operation = operation
        self.key = key
        self.seconds = seconds
        self.firstAudioMs = firstAudioMs
        self.details = details
    }

    enum CodingKeys: String, CodingKey {
        case engine, operation, key, seconds, details
        case firstAudioMs = "first_audio_ms"
    }

    public var foundationObject: [String: Any] {
        var object: [String: Any] = ["engine": engine, "operation": operation, "key": key]
        if let seconds { object["seconds"] = seconds }
        if let firstAudioMs { object["first_audio_ms"] = firstAudioMs }
        if let details { object["details"] = details.mapValues(\.foundationObject) }
        return object
    }
}

public extension LiveEvent {
    /// The engine a call runs on, and why not the one asked for.
    static func engineChosen(_ grant: LiveCallGrant) -> LiveEvent {
        let fellBack = grant.choice?.fallbackReason?.isEmpty == false
        return LiveEvent(fellBack ? .warn : .info, "call.engine") {
            ["engine": .string(grant.isGptLive ? LiveVoiceEngine.gptLive : LiveVoiceEngine.realtime),
             "requested": .text(grant.choice?.requested), "fallback_reason": .text(grant.choice?.fallbackReason),
             "warning": .text(grant.choice?.warning)]
        }
    }
}

public extension LiveEvent {
    /// GPT-Live was granted and could not start; the call went on Realtime.
    static func gptLiveFellBack(_ reason: String) -> LiveEvent {
        LiveEvent(.warn, "call.engine_fell_back") { ["engine": .string(LiveVoiceEngine.gptLive), "reason": .string(reason)] }
    }
}
