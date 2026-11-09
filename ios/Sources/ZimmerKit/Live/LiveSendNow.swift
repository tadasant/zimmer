import Foundation

/// Send now's tap handling and what it reports: the debounce, and the timings that say whether
/// turn detection needs tuning. What a tap does to the call is `RealtimeConductor.endTurn()`.
///
/// **One tap is one send.** A tap within `debounce` of the last one that counted is ignored before
/// the call is asked, so a bounce on a car's touchscreen cannot end the next turn the moment it
/// starts. The conductor makes it idempotent past that: a turn ends once, by the tap or by turn
/// detection, whichever is first.
///
/// **What it reports, never what was said:**
///
/// - `turn.send_now`: every tap, its outcome (`submitted`, `ignored_empty`, `ignored_in_flight`,
///   `ignored_debounced`), the turn detection in force, the time since turn detection heard the
///   speech start, the time since the microphone last carried a voice (`since_last_voice_ms`, a
///   level estimate from the audio's loudness, `voiceLevel`), and for a tap that found nothing to
///   send, how long since turn detection ended the turn itself, which is a driver reaching for the
///   button as the call moved on.
/// - `turn.send_now_followup`: for a tap that sent, whether turn detection would have ended the
///   turn soon anyway. `vad_turn_end_after_ms` is when OpenAI's own `speech_stopped` for that
///   speech arrived after the tap, if it did within `followWindow`; `estimated_auto_after_ms` is,
///   under Silence, the pause still to run when the driver tapped (the setting's silence minus the
///   time since the last voice), and nothing under Semantic, whose wait is the model's. `auto_soon`
///   is either of them inside `soon`: a tap that saved the driver little.
///
/// Pure, with the time handed in, so it is tested on Linux.
public struct LiveSendNow: Sendable {
    public enum Outcome: String, Sendable, CaseIterable {
        case submitted
        case ignoredEmpty = "ignored_empty"
        case ignoredInFlight = "ignored_in_flight"
        case ignoredDebounced = "ignored_debounced"
    }

    /// Taps closer together than this are one tap.
    public static let debounce: TimeInterval = 0.8
    /// How long after a send turn detection's own end of that turn is looked for.
    public static let followWindow: TimeInterval = 5
    /// Turn detection ending the turn within this of the tap: the tap saved little.
    public static let soon: TimeInterval = 1.5
    /// RMS of 16-bit samples, as a fraction of full scale, above which the microphone counts as
    /// carrying a voice (about -34 dBFS). An estimate for the log, never a decision.
    public static let voiceLevel: Double = 0.02

    private var lastTap: TimeInterval?
    private var speechStartedAt: TimeInterval?
    private var turnEndedAt: TimeInterval?
    private var lastVoiceAt: TimeInterval?
    private var detection = "semantic_vad"
    private var eagerness: JSONValue = .null
    private var silenceMs: Double?
    /// A send waiting to hear whether turn detection would have ended the turn itself.
    private var watching: (tappedAt: TimeInterval, estimate: TimeInterval?)?

    public init() {}

    /// The microphone's audio as sent: notes when it last carried a voice. Muted audio is
    /// silence and is not handed in.
    public mutating func heard(pcm16 data: Data, at: TimeInterval) {
        guard Self.level(pcm16: data) >= Self.voiceLevel else { return }
        lastVoiceAt = at
    }

    /// RMS of 16-bit little-endian PCM, 0…1.
    static func level(pcm16 data: Data) -> Double {
        let count = data.count / 2
        guard count > 0 else { return 0 }
        var sum = 0.0
        data.withUnsafeBytes { raw in
            for index in 0..<count {
                let sample = Double(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: index * 2, as: Int16.self))) / Double(Int16.max)
                sum += sample * sample
            }
        }
        return (sum / Double(count)).squareRoot()
    }

    /// A server event: turn detection's settings, and its starts and ends of speech. Returns the
    /// follow-up for a send when turn detection's own end of that turn arrives.
    public mutating func observe(_ event: JSONValue, at: TimeInterval) -> [LiveEvent] {
        switch event["type"]?.string {
        case "session.created", "session.updated":
            // A `session.updated` that does not name turn detection leaves it as it was.
            guard let found = event["session"]?["audio"]?["input"]?["turn_detection"], let type = found["type"]?.string else { return [] }
            detection = type
            eagerness = found["eagerness"] ?? .null
            silenceMs = found["silence_duration_ms"]?.number
            return []
        case "input_audio_buffer.speech_started":
            // A new turn: a send still watching heard nothing from turn detection about its own.
            let unanswered = watching != nil ? expire(at: at, force: true) : []
            speechStartedAt = at
            turnEndedAt = nil
            return unanswered
        case "input_audio_buffer.speech_stopped":
            guard let sent = watching else {
                turnEndedAt = at
                return []
            }
            watching = nil
            return [Self.followup(observed: at - sent.tappedAt, estimate: sent.estimate)]
        default:
            return []
        }
    }

    /// A tap. False when it is within `debounce` of the last one that counted, which is then not
    /// handed to the call.
    public mutating func tap(at: TimeInterval) -> Bool {
        if let lastTap, at - lastTap < Self.debounce { return false }
        lastTap = at
        return true
    }

    /// What the tap at `at` came to, for the log. A send starts watching for turn detection's own
    /// end of that turn.
    public mutating func record(_ outcome: Outcome, surface: String, at: TimeInterval) -> LiveEvent {
        let sinceVoice = lastVoiceAt.map { at - $0 }
        let sinceStart = speechStartedAt.map { at - $0 }
        let sinceEnd = outcome == .ignoredEmpty ? turnEndedAt.map { at - $0 } : nil
        if outcome == .submitted {
            var estimate: TimeInterval?
            if detection == "server_vad", let silenceMs, let sinceVoice {
                estimate = max(0, silenceMs / 1_000 - sinceVoice)
            }
            watching = (at, estimate)
        }
        let fields: [String: JSONValue] = [
            "outcome": .string(outcome.rawValue),
            "surface": .string(surface),
            "turn_detection": .string(detection),
            "eagerness": eagerness,
            "silence_duration_ms": silenceMs.map(JSONValue.number) ?? .null,
            "since_speech_started_ms": .ms(sinceStart),
            "since_last_voice_ms": .ms(sinceVoice),
            "since_turn_ended_ms": .ms(sinceEnd),
        ]
        return LiveEvent(.info, "turn.send_now") { fields }
    }

    /// The follow-up for a send whose window ran out with no word from turn detection. `force`:
    /// the window is cut short by a new turn.
    public mutating func expire(at: TimeInterval, force: Bool = false) -> [LiveEvent] {
        guard let sent = watching, force || at - sent.tappedAt >= Self.followWindow else { return [] }
        watching = nil
        return [Self.followup(observed: nil, estimate: sent.estimate)]
    }

    private static func followup(observed: TimeInterval?, estimate: TimeInterval?) -> LiveEvent {
        let soon = [observed, estimate].contains { $0.map { $0 <= Self.soon } ?? false }
        return LiveEvent(.info, "turn.send_now_followup") {
            ["vad_turn_end_after_ms": .ms(observed), "estimated_auto_after_ms": .ms(estimate), "auto_soon": .bool(soon)]
        }
    }
}
