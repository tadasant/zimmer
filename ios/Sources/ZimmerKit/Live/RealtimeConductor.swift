import Foundation

/// What a Live Mode voice call is doing, for the screen and the car.
public enum LiveVoiceState: String, Sendable, Equatable {
    case idle, connecting, listening, thinking, speaking, working

    public var label: String {
        switch self {
        case .idle: return "Call ended"
        case .connecting: return "Connecting…"
        case .listening: return "Listening"
        case .thinking: return "Thinking…"
        case .speaking: return "Speaking"
        case .working: return "Working on it…"
        }
    }

    /// The call's status line, on the phone and in the car: muted is said beside the state, not
    /// instead of it, so a reply under way still shows.
    public func label(muted: Bool) -> String {
        muted && self != .idle ? "\(label) · Muted" : label
    }
}

/// The Realtime protocol half of a Live Mode voice call, with no I/O: OpenAI's server events go in,
/// and what to do about them comes out. The same sequencing as the web's call dock
/// (`live_voice_controller.js`), so the phone and the browser behave alike:
///
/// - a function call is relayed to Zimmer as soon as its arguments are complete
///   (`response.function_call_arguments.done`), several side by side;
/// - each result goes back as a `function_call_output` item, followed by a `session.update` when
///   the call enabled or disabled a server or changed a Live setting (Zimmer's `session` when it
///   sent one, otherwise just the tools);
/// - once the response that asked for them is done and every result is in, exactly one
///   `response.create` — and never on top of a response already running (the user speaking
///   mid-tool starts one), in which case it waits for that response to finish;
/// - a response the user talked over (`cancelled`) asks for nothing more: a call first seen in
///   its `response.done` is not run, and one already relayed is answered but not followed up;
/// - each call runs once, however often its events repeat;
/// - finished transcript lines are recorded, and the user starting to speak stops the reply
///   that is playing and tells OpenAI how much of it was heard (`conversation.item.truncate`,
///   which a WebSocket client sends itself — over WebRTC the server does it);
/// - with Listening gated (wake word, dynamic) turn detection starts no reply and cuts none off:
///   a finished user line comes out as `hear`, Zimmer says whether to answer it, and `heard`
///   asks for the reply — or deletes the line from the call;
/// - OpenAI's `error` events, and a response that ended `failed`, come out as `failure` so the
///   call can say what went wrong instead of sitting in Listening.
public struct RealtimeConductor: Sendable {
    public enum Effect: Equatable, Sendable {
        /// Send this client event to OpenAI.
        case send(JSONValue)
        /// Run this function call through Zimmer, then call `relayed(callID:result:)`.
        case relay(callID: String, name: String, arguments: String)
        /// A finished transcript line, for the thread.
        case record(role: LiveTurn.Role, text: String)
        /// Gated: record this user line with Zimmer, which says whether to answer it; then call
        /// `heard(itemID:respond:)`.
        case hear(itemID: String?, text: String)
        /// Play this reply audio: 16-bit mono PCM at 24 kHz.
        case play(Data)
        /// A new reply item started playing: count its audio from here.
        case replyStarted(itemID: String)
        /// The user started talking over reply `itemID`: stop playing it, and send
        /// `truncate(itemID:audioEndMs:)` with how much of it was played.
        case interrupt(itemID: String)
        case state(LiveVoiceState)
        case failure(String)
    }

    /// Every call ever started, so a repeated event never runs one twice.
    private var seen: Set<String> = []
    /// Calls started and not yet answered.
    private var inFlight: Set<String> = []
    /// Calls of a cancelled response: answered when their result comes, followed up never.
    private var dropped: Set<String> = []
    /// The reply item whose audio is playing.
    private var playingItem: String?
    /// Answered calls, until the response that asked for them is done.
    private var answered: Set<String> = []
    /// The calls of a finished response still waiting on their results.
    private var awaiting: Set<String> = []
    private var responseActive = false
    /// A `response.create` was sent and its `response.created` has not come: a second one now
    /// would be refused for the response already on its way.
    private var requested = false
    private var pendingResponse = false
    /// The call asks for its own replies (Listening is wake word or dynamic).
    public private(set) var gated = false

    public init(listening: String? = nil) {
        gated = Self.gates(listening)
    }

    /// Whether a call with this Listening mode asks for its own replies.
    public static func gates(_ listening: String?) -> Bool {
        listening == "wake_word" || listening == "dynamic"
    }

    /// The session OpenAI says the call has (`session.created`, `session.updated`): its turn
    /// detection says from here on whether the call is gated (`create_response: false`). What
    /// OpenAI applied, not what was sent, so a refused `session.update` changes nothing.
    mutating func note(session: JSONValue) {
        guard case let .bool(creates)? = session["audio"]?["input"]?["turn_detection"]?["create_response"] else { return }
        gated = !creates
    }

    /// Zimmer's answer for a line `hear` sent: ask for the reply once nothing else is running, or
    /// take the line out of the call.
    public mutating func heard(itemID: String?, respond: Bool) -> [Effect] {
        if respond {
            pendingResponse = true
            return sendPendingResponse()
        }
        guard let itemID else { return [] }
        return [.send(.object(["type": .string("conversation.item.delete"), "item_id": .string(itemID)]))]
    }

    /// A line the person did not speak, put to the model as if typed: what the car sends when
    /// the driver taps *Talk about it* on a session, so the call opens on that session rather
    /// than on silence. A user message item, then a reply asked for under the usual rule —
    /// once nothing else is running.
    public mutating func open(with text: String) -> [Effect] {
        pendingResponse = true
        let item: JSONValue = .object([
            "type": .string("message"), "role": .string("user"),
            "content": .array([.object(["type": .string("input_text"), "text": .string(text)])]),
        ])
        return [.send(.object(["type": .string("conversation.item.create"), "item": item]))] + sendPendingResponse()
    }

    /// One server event.
    public mutating func handle(_ event: JSONValue) -> [Effect] {
        switch event["type"]?.string {
        case "input_audio_buffer.speech_started":
            // Gated, speech does not cut the reply off: it may not be meant for the call at all.
            if gated { return playingItem == nil ? [.state(.listening)] : [] }
            defer { playingItem = nil }
            return (playingItem.map { [Effect.interrupt(itemID: $0)] } ?? []) + [.state(.listening)]
        case "response.created":
            responseActive = true
            requested = false
            return [.state(.thinking)]
        case "session.created", "session.updated":
            note(session: event["session"] ?? .null)
            return []
        case "response.output_audio.delta":
            guard let delta = event["delta"]?.string, let audio = Data(base64Encoded: delta) else { return [] }
            var effects: [Effect] = []
            if let item = event["item_id"]?.string, item != playingItem {
                playingItem = item
                effects.append(.replyStarted(itemID: item))
            }
            return effects + [.play(audio), .state(.speaking)]
        case "response.function_call_arguments.done":
            guard let callID = event["call_id"]?.string, let name = event["name"]?.string else { return [] }
            return start(callID: callID, name: name, arguments: event["arguments"]?.string ?? "{}")
        case "response.done":
            responseActive = false
            playingItem = nil
            if event["response"]?["status"]?.string == "failed" {
                let message = event["response"]?["status_details"]?["error"]?["message"]?.string
                return finish(event["response"]) + [.failure(message ?? "OpenAI could not answer that."), .state(.listening)]
            }
            return finish(event["response"])
        case "conversation.item.input_audio_transcription.completed":
            guard gated else { return record(.user, event["transcript"]?.string) }
            guard let text = event["transcript"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
                return heard(itemID: event["item_id"]?.string, respond: false)
            }
            return [.hear(itemID: event["item_id"]?.string, text: text)]
        case "conversation.item.input_audio_transcription.failed":
            // Gated, a line nobody could read is not one to answer.
            return gated ? heard(itemID: event["item_id"]?.string, respond: false) : []
        case "response.output_audio_transcript.done":
            return record(.assistant, event["transcript"]?.string)
        case "error":
            // A refused `response.create` never gets its `response.created`.
            requested = false
            return [.failure(event["error"]?["message"]?.string ?? "OpenAI reported an error.")]
        default:
            return []
        }
    }

    /// Zimmer answered a relayed call (`result`), or could not be reached (`failure`).
    public mutating func relayed(callID: String, result: LiveToolResult?, failure: String? = nil) -> [Effect] {
        guard inFlight.remove(callID) != nil else { return [] }
        var effects: [Effect] = []
        if let session = result?.session {
            effects.append(.send(Self.sessionUpdate(session)))
        } else if let result, result.toolsChanged, let tools = result.tools {
            effects.append(.send(Self.sessionUpdate(.object(["type": .string("realtime"), "tools": tools]))))
        }
        let output = result?.output ?? "Zimmer could not run that: \(failure ?? "no answer")."
        effects.insert(.send(.object([
            "type": .string("conversation.item.create"),
            "item": .object(["type": .string("function_call_output"), "call_id": .string(callID), "output": .string(output)]),
        ])), at: 0)
        if dropped.remove(callID) != nil {
            // Its response was talked over; nothing waits on it.
        } else if awaiting.remove(callID) != nil {
            if awaiting.isEmpty { pendingResponse = true }
        } else {
            answered.insert(callID)
        }
        return effects + sendPendingResponse()
    }

    /// The `session.update` client event carrying `session` — what Zimmer answered for a tool
    /// call that changed a Live setting, or `POST /live_conversations/:id/session_update` after
    /// the settings changed somewhere else.
    public static func sessionUpdate(_ session: JSONValue) -> JSONValue {
        .object(["type": .string("session.update"), "session": session])
    }

    /// Tell OpenAI the user heard only the first `audioEndMs` of reply `itemID`.
    public static func truncate(itemID: String, audioEndMs: Int) -> JSONValue {
        .object([
            "type": .string("conversation.item.truncate"), "item_id": .string(itemID),
            "content_index": .number(0), "audio_end_ms": .number(Double(max(0, audioEndMs))),
        ])
    }

    /// The microphone's audio, as the event that carries it. Muted, the same length of silence:
    /// over a WebSocket the server's turn detection hears only what is sent, so a microphone that
    /// went quiet by sending nothing would leave the turn open forever, stuck in Listening. Silence
    /// lets it end, the way a disabled WebRTC track does in the browser.
    public static func appendAudio(_ pcm16: Data, muted: Bool = false) -> JSONValue {
        let audio = muted ? Data(count: pcm16.count) : pcm16
        return .object(["type": .string("input_audio_buffer.append"), "audio": .string(audio.base64EncodedString())])
    }

    // MARK: - Internals

    private mutating func start(callID: String, name: String, arguments: String) -> [Effect] {
        guard seen.insert(callID).inserted else { return [] }
        inFlight.insert(callID)
        return [.relay(callID: callID, name: name, arguments: arguments), .state(.working)]
    }

    private mutating func finish(_ response: JSONValue?) -> [Effect] {
        var effects = sendPendingResponse()
        let status = response?["status"]?.string
        let calls = (response?["output"]?.array ?? []).filter { $0["type"]?.string == "function_call" }
        guard status == nil || status == "completed" else {
            // Talked over: a call it asked for is not started, and one already relayed is
            // answered without a follow-up.
            for call in calls {
                guard let callID = call["call_id"]?.string else { continue }
                if inFlight.contains(callID) { dropped.insert(callID) }
                answered.remove(callID)
            }
            return effects
        }
        guard !calls.isEmpty else { return effects + [.state(.listening)] }

        for call in calls {
            guard let callID = call["call_id"]?.string else { continue }
            if !seen.contains(callID), let name = call["name"]?.string {
                effects += start(callID: callID, name: name, arguments: call["arguments"]?.string ?? "{}")
            }
            if answered.remove(callID) == nil { awaiting.insert(callID) }
        }
        if awaiting.isEmpty {
            pendingResponse = true
            effects += sendPendingResponse()
        }
        return effects
    }

    private mutating func sendPendingResponse() -> [Effect] {
        guard pendingResponse, !responseActive, !requested else { return [] }
        pendingResponse = false
        requested = true
        return [.send(.object(["type": .string("response.create")]))]
    }

    private func record(_ role: LiveTurn.Role, _ text: String?) -> [Effect] {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return [] }
        return [.record(role: role, text: text)]
    }
}

/// The audio conversions a voice call needs: the microphone's float samples at whatever
/// rate the hardware runs to the 16-bit mono 24 kHz PCM OpenAI takes, and back for playback.
public enum RealtimeAudio {
    public static let sampleRate: Double = 24_000

    /// Linear resampling to 24 kHz, then clamped 16-bit little-endian PCM.
    public static func pcm16(from samples: [Float], sampleRate inputRate: Double) -> Data {
        guard !samples.isEmpty, inputRate > 0 else { return Data() }
        let ratio = inputRate / sampleRate
        let count = max(1, Int((Double(samples.count) / ratio).rounded(.down)))
        var data = Data(capacity: count * 2)
        for index in 0..<count {
            let position = Double(index) * ratio
            let lower = min(Int(position), samples.count - 1)
            let upper = min(lower + 1, samples.count - 1)
            let fraction = Float(position - Double(lower))
            let sample = samples[lower] + (samples[upper] - samples[lower]) * fraction
            let clamped = max(-1, min(1, sample))
            let value = Int16(clamped * Float(Int16.max))
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }

    /// 16-bit little-endian PCM to floats in -1…1.
    public static func floats(fromPCM16 data: Data) -> [Float] {
        stride(from: 0, to: data.count - 1, by: 2).map { offset in
            let value = Int16(littleEndian: Int16(bitPattern: UInt16(data[data.startIndex + offset]) | UInt16(data[data.startIndex + offset + 1]) << 8))
            return Float(value) / Float(Int16.max)
        }
    }
}
