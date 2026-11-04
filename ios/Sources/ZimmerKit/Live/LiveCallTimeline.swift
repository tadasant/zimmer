import Foundation

/// What a call's OpenAI server events say happened, as telemetry, with the timings between them:
/// turn detection as OpenAI applied it, speech starting and stopping, how long from the end of
/// speech to the reply starting and to the first audio, each response's outcome, and errors.
///
/// Pure: the time comes in with each event (`at`, seconds on any monotonic clock), so it is
/// tested on Linux. `LiveCall` feeds it every server event and tracks what comes out.
public struct LiveCallTimeline: Sendable {
    private var startedAt: TimeInterval?
    private var speechStartedAt: TimeInterval?
    private var speechStoppedAt: TimeInterval?
    private var responseCreatedAt: TimeInterval?
    private var firstAudioSeen = false
    /// Bytes of 16-bit PCM in the response under way.
    private var responseAudioBytes = 0
    private var turns = 0
    private var responses = 0

    public init() {}

    /// The call started connecting at `at`.
    public mutating func started(at: TimeInterval) {
        startedAt = at
    }

    /// Seconds since the call started connecting.
    public func sinceStart(_ at: TimeInterval) -> TimeInterval? { startedAt.map { at - $0 } }

    /// Counts for the call's last event.
    public var summary: [String: JSONValue] { ["turns": .int(turns), "responses": .int(responses)] }

    public mutating func observe(_ event: JSONValue, at: TimeInterval) -> [LiveEvent] {
        switch event["type"]?.string {
        case "session.created", "session.updated":
            let name = event["type"]?.string == "session.created" ? "realtime.session_created" : "realtime.session_updated"
            let session = event["session"] ?? .null
            let input = session["audio"]?["input"] ?? .null
            let detection = input["turn_detection"] ?? .null
            let sinceStart = sinceStart(at)
            return [LiveEvent(.info, name) {
                [
                    "model": session["model"] ?? .null,
                    "max_output_tokens": session["max_output_tokens"] ?? .null,
                    "turn_detection": detection["type"] ?? .string("none"),
                    "eagerness": detection["eagerness"] ?? .null,
                    "threshold": detection["threshold"] ?? .null,
                    "silence_duration_ms": detection["silence_duration_ms"] ?? .null,
                    "prefix_padding_ms": detection["prefix_padding_ms"] ?? .null,
                    "create_response": detection["create_response"] ?? .null,
                    "interrupt_response": detection["interrupt_response"] ?? .null,
                    "idle_timeout_ms": detection["idle_timeout_ms"] ?? .null,
                    "noise_reduction": input["noise_reduction"]?["type"] ?? .string("off"),
                    "input_format": input["format"]?["type"] ?? .null,
                    "input_rate": input["format"]?["rate"] ?? .null,
                    "transcription": input["transcription"]?["model"] ?? .null,
                    "since_start_ms": .ms(sinceStart),
                ]
            }]
        case "input_audio_buffer.speech_started":
            speechStartedAt = at
            speechStoppedAt = nil
            let audioStart = event["audio_start_ms"]
            return [LiveEvent(.debug, "vad.speech_started") { ["audio_start_ms": audioStart ?? .null] }]
        case "input_audio_buffer.speech_stopped":
            speechStoppedAt = at
            turns += 1
            let spoke = speechStartedAt.map { at - $0 }
            let audioEnd = event["audio_end_ms"]
            return [LiveEvent(.debug, "vad.speech_stopped") { ["audio_end_ms": audioEnd ?? .null, "speech_ms": .ms(spoke)] }]
        case "input_audio_buffer.timeout_triggered":
            // Server VAD's idle timeout: no speech for `idle_timeout_ms`.
            return [LiveEvent(.info, "vad.timeout") { ["audio_end_ms": event["audio_end_ms"] ?? .null] }]
        case "input_audio_buffer.committed":
            let sinceStop = speechStoppedAt.map { at - $0 }
            return [LiveEvent(.debug, "vad.committed") { ["since_speech_end_ms": .ms(sinceStop)] }]
        case "response.created":
            responseCreatedAt = at
            firstAudioSeen = false
            responseAudioBytes = 0
            responses += 1
            let sinceStop = speechStoppedAt.map { at - $0 }
            return [LiveEvent(.debug, "response.created") { ["since_speech_end_ms": .ms(sinceStop)] }]
        case "response.output_audio.delta":
            responseAudioBytes += event["delta"]?.string.flatMap { Data(base64Encoded: $0) }?.count ?? 0
            guard !firstAudioSeen else { return [] }
            firstAudioSeen = true
            let sinceStop = speechStoppedAt.map { at - $0 }
            let sinceCreated = responseCreatedAt.map { at - $0 }
            // The number a driver feels: from going quiet to hearing Zimmer.
            return [LiveEvent(.info, "response.first_audio") { ["since_speech_end_ms": .ms(sinceStop), "since_response_ms": .ms(sinceCreated)] }]
        case "response.done":
            let response = event["response"] ?? .null
            let status = response["status"]?.string ?? "unknown"
            let took = responseCreatedAt.map { at - $0 }
            let calls = (response["output"]?.array ?? []).filter { $0["type"]?.string == "function_call" }.count
            let audio = firstAudioSeen
            let audioMs = responseAudioBytes * 1_000 / (2 * Int(RealtimeAudio.sampleRate))
            responseCreatedAt = nil
            if status == "failed" {
                let message = response["status_details"]?["error"]?["message"]
                return [LiveEvent(.error, "response.failed") { ["duration_ms": .ms(took), "message": message ?? .null] }]
            }
            let reason = response["status_details"]?["reason"]
            // Cut short is the one ending that is a problem without being an error: the person
            // lost the end of a reply, or a tool call.
            return [LiveEvent(status == "incomplete" ? .warn : .debug, "response.done") {
                ["status": .string(status), "reason": reason ?? .null, "duration_ms": .ms(took), "had_audio": .bool(audio), "audio_ms": .int(audioMs),
                 "function_calls": .int(calls)]
            }]
        case "conversation.item.truncated":
            // OpenAI took the truncate; one it refused is a `realtime.error`.
            let item = event["item_id"]
            let audioEnd = event["audio_end_ms"]
            return [LiveEvent(.debug, "reply.truncated") { ["item_id": item ?? .null, "audio_end_ms": audioEnd ?? .null] }]
        case "conversation.item.input_audio_transcription.completed":
            // Its length only: never what was said.
            let characters = event["transcript"]?.string?.count
            return [LiveEvent(.debug, "transcript.user") { ["characters": .int(characters)] }]
        case "conversation.item.input_audio_transcription.failed":
            let message = event["error"]?["message"]
            return [LiveEvent(.warn, "transcript.failed") { ["message": message ?? .null] }]
        case "error":
            let error = event["error"] ?? .null
            return [LiveEvent(.error, "realtime.error") {
                ["code": error["code"] ?? .null, "error_type": error["type"] ?? .null, "message": error["message"] ?? .null,
                 "client_event": error["event_id"] ?? .null]
            }]
        case "rate_limits.updated":
            return []
        default:
            return []
        }
    }
}

/// The events the call, its audio and the car report, one place to read them all. Names are
/// `area.what`; the level says what a threshold keeps.
public extension LiveEvent {
    // The call

    static func callStarting(surface: String, opening: Bool) -> LiveEvent {
        LiveEvent(.info, "call.starting") { ["surface": .string(surface), "opening": .bool(opening)] }
    }

    static func secretMinted(ms: TimeInterval, model: String, listening: String?, telemetry: String?) -> LiveEvent {
        LiveEvent(.info, "call.secret_minted") {
            ["duration_ms": .ms(ms), "model": .string(model), "listening": .text(listening), "telemetry": .text(telemetry)]
        }
    }

    static func connected(sinceStart: TimeInterval?, listening: String?, gated: Bool) -> LiveEvent {
        LiveEvent(.info, "call.connected") { ["since_start_ms": .ms(sinceStart), "listening": .text(listening), "gated": .bool(gated)] }
    }

    static func handedOver(to surface: String) -> LiveEvent {
        LiveEvent(.info, "call.handed_over") { ["surface": .string(surface)] }
    }

    /// The mode in force changed mid-call: a hand-over, or Listening changed while it was up.
    static func listeningChanged(from: String?, to: String?) -> LiveEvent {
        LiveEvent(.info, "listening.changed") { ["from": .text(from), "to": .text(to)] }
    }

    static func callEnded(reason: String, duration: TimeInterval?, summary: [String: JSONValue]) -> LiveEvent {
        LiveEvent(.info, "call.ended") { summary.merging(["reason": .string(reason), "duration_ms": .ms(duration)]) { $1 } }
    }

    static func callFailed(_ message: String, state: LiveVoiceState) -> LiveEvent {
        LiveEvent(.error, "call.failed") { ["message": .string(message), "state": .string(state.rawValue)] }
    }

    static func stateChanged(from: LiveVoiceState, to: LiveVoiceState, muted: Bool) -> LiveEvent {
        LiveEvent(.debug, "call.state") { ["from": .string(from.rawValue), "to": .string(to.rawValue), "muted": .bool(muted)] }
    }

    static func muted(_ muted: Bool) -> LiveEvent {
        LiveEvent(.info, muted ? "call.muted" : "call.unmuted")
    }

    /// Zimmer's verdict on a line a gated call heard (`listening` is the mode that judged it). A
    /// dropped line is a warning: the person said something and got no answer.
    static func lineHeard(respond: Bool, dropped: Bool, ms: TimeInterval, listening: String?) -> LiveEvent {
        LiveEvent(respond ? .debug : .warn, "listening.heard") {
            ["respond": .bool(respond), "dropped": .bool(dropped), "duration_ms": .ms(ms), "listening": .text(listening)]
        }
    }

    /// The person talked over a reply: how long it was and where they cut in.
    static func replyInterrupted(_ cut: LiveReplyPlayout.Cut) -> LiveEvent {
        LiveEvent(.info, "reply.interrupted") { ["item_id": .string(cut.itemID), "audio_ms": .int(cut.audioMs), "heard_ms": .int(cut.heardMs)] }
    }

    static func toolCall(_ name: String, ms: TimeInterval, ok: Bool) -> LiveEvent {
        LiveEvent(ok ? .debug : .warn, "tool.relayed") { ["tool": .string(name), "duration_ms": .ms(ms), "ok": .bool(ok)] }
    }

    static func socketClosed(_ reason: String) -> LiveEvent {
        LiveEvent(.error, "socket.closed") { ["message": .string(reason)] }
    }

    // The microphone

    static func micStalled(afterMs: Int) -> LiveEvent {
        LiveEvent(.warn, "mic.stalled") { ["silent_for_ms": .int(afterMs)] }
    }

    static func micResumed(stalledMs: Int, silenceSentMs: Int) -> LiveEvent {
        LiveEvent(.warn, "mic.resumed") { ["stalled_ms": .int(stalledMs), "silence_sent_ms": .int(silenceSentMs)] }
    }

    // Cues

    static func cue(_ cue: LiveCue) -> LiveEvent {
        LiveEvent(.debug, "cue.played") { ["cue": .string(cue.rawValue)] }
    }

    static func thinkingCue(_ on: Bool) -> LiveEvent {
        LiveEvent(.debug, on ? "cue.thinking_started" : "cue.thinking_stopped")
    }

    static func thinkingTimedOut(after: TimeInterval) -> LiveEvent {
        LiveEvent(.warn, "cue.thinking_timeout") { ["after_ms": .ms(after)] }
    }
}
