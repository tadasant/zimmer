import Foundation

/// What a Live Voice call is doing, for the screen and the car.
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
}

/// The Realtime protocol half of a Live Voice call, with no I/O: OpenAI's server events go in,
/// and what to do about them comes out. The same sequencing as the web's call dock
/// (`live_voice_controller.js`), so the phone and the browser behave alike:
///
/// - a function call is relayed to Zimmer as soon as its arguments are complete
///   (`response.function_call_arguments.done`), several side by side;
/// - each result goes back as a `function_call_output` item, preceded by a `session.update` when
///   the call enabled or disabled a server;
/// - once the response that asked for them is done and every result is in, exactly one
///   `response.create` — and never on top of a response already running (the user speaking
///   mid-tool starts one), in which case it waits for that response to finish;
/// - a response the user talked over (`cancelled`) has its calls dropped, not run;
/// - finished transcript lines are recorded, and the user starting to speak stops the reply
///   that is playing.
public struct RealtimeConductor: Sendable {
    public enum Effect: Equatable, Sendable {
        /// Send this client event to OpenAI.
        case send(JSONValue)
        /// Run this function call through Zimmer, then call `relayed(callID:result:)`.
        case relay(callID: String, name: String, arguments: String)
        /// A finished transcript line, for the thread.
        case record(role: LiveTurn.Role, text: String)
        /// Play this reply audio: 16-bit mono PCM at 24 kHz.
        case play(Data)
        /// Stop the reply that is playing — the user started talking.
        case stopPlayback
        case state(LiveVoiceState)
        case failure(String)
    }

    /// Calls started and not yet answered.
    private var inFlight: Set<String> = []
    /// Answered calls, until the response that asked for them is done.
    private var answered: Set<String> = []
    /// The calls of a finished response still waiting on their results.
    private var awaiting: Set<String> = []
    private var responseActive = false
    private var pendingResponse = false

    public init() {}

    /// One server event.
    public mutating func handle(_ event: JSONValue) -> [Effect] {
        switch event["type"]?.string {
        case "input_audio_buffer.speech_started":
            return [.stopPlayback, .state(.listening)]
        case "response.created":
            responseActive = true
            return [.state(.thinking)]
        case "response.output_audio.delta":
            guard let delta = event["delta"]?.string, let audio = Data(base64Encoded: delta) else { return [] }
            return [.play(audio), .state(.speaking)]
        case "response.function_call_arguments.done":
            guard let callID = event["call_id"]?.string, let name = event["name"]?.string else { return [] }
            return start(callID: callID, name: name, arguments: event["arguments"]?.string ?? "{}")
        case "response.done":
            responseActive = false
            return finish(event["response"])
        case "conversation.item.input_audio_transcription.completed":
            return record(.user, event["transcript"]?.string)
        case "response.output_audio_transcript.done":
            return record(.assistant, event["transcript"]?.string)
        case "error":
            return [.failure(event["error"]?["message"]?.string ?? "OpenAI reported an error.")]
        default:
            return []
        }
    }

    /// Zimmer answered a relayed call (`result`), or could not be reached (`failure`).
    public mutating func relayed(callID: String, result: LiveToolResult?, failure: String? = nil) -> [Effect] {
        guard inFlight.remove(callID) != nil else { return [] }
        var effects: [Effect] = []
        if let result, result.toolsChanged, let tools = result.tools {
            effects.append(.send(.object(["type": .string("session.update"),
                                          "session": .object(["type": .string("realtime"), "tools": tools])])))
        }
        let output = result?.output ?? "Zimmer could not run that: \(failure ?? "no answer")."
        effects.insert(.send(.object([
            "type": .string("conversation.item.create"),
            "item": .object(["type": .string("function_call_output"), "call_id": .string(callID), "output": .string(output)]),
        ])), at: 0)
        if awaiting.remove(callID) != nil {
            if awaiting.isEmpty { pendingResponse = true }
        } else {
            answered.insert(callID)
        }
        return effects + sendPendingResponse()
    }

    /// The microphone's audio, as the event that carries it.
    public static func appendAudio(_ pcm16: Data) -> JSONValue {
        .object(["type": .string("input_audio_buffer.append"), "audio": .string(pcm16.base64EncodedString())])
    }

    // MARK: - Internals

    private mutating func start(callID: String, name: String, arguments: String) -> [Effect] {
        guard !inFlight.contains(callID), !answered.contains(callID) else { return [] }
        inFlight.insert(callID)
        return [.relay(callID: callID, name: name, arguments: arguments), .state(.working)]
    }

    private mutating func finish(_ response: JSONValue?) -> [Effect] {
        var effects = sendPendingResponse()
        let status = response?["status"]?.string
        let calls = (response?["output"]?.array ?? []).filter { $0["type"]?.string == "function_call" }
        guard status == nil || status == "completed" else {
            // Talked over: whatever it asked for is not run, and nothing waits on it.
            return effects
        }
        guard !calls.isEmpty else { return effects + [.state(.listening)] }

        for call in calls {
            guard let callID = call["call_id"]?.string else { continue }
            if !inFlight.contains(callID), !answered.contains(callID), let name = call["name"]?.string {
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
        guard pendingResponse, !responseActive else { return [] }
        pendingResponse = false
        return [.send(.object(["type": .string("response.create")]))]
    }

    private func record(_ role: LiveTurn.Role, _ text: String?) -> [Effect] {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return [] }
        return [.record(role: role, text: text)]
    }
}

/// The audio conversions a Live Voice call needs: the microphone's float samples at whatever
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
