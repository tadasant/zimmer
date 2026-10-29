import Foundation

/// The sounds a Live voice call makes besides Zimmer's voice, so a driver knows what the call is
/// doing without looking:
///
/// - **connected**: two soft rising notes (E5 then B5, a fifth apart, bell-like and quick to fade),
///   once, when the call is up and listening;
/// - **thinking**: one quiet, low, rounded tick (a 520 Hz tap, 45 ms) about once a second, from
///   the moment the person stops talking until Zimmer's voice starts, through tool calls too —
///   so there is no dead air between *I heard you* and the answer. The first tick waits
///   `thinkingLead`, so an answer that starts within it gets none;
/// - **disconnected**: the connected notes falling (B5 then E5), once, when a call drops.
///
/// Rising means *on*, falling means *off*, and the tick shares neither pitch nor shape with the
/// notes. Each is synthesized here at the reply's 24 kHz rate: no audio files.
///
/// None of them should reach OpenAI's turn detection: they play through the same voice-processing
/// engine as the reply, so the echo canceller has them as reference, and while a cue sounds the
/// microphone is sent as silence (`LiveCueGate`).
public enum LiveCue: String, Sendable, CaseIterable {
    case connected, thinking, disconnected

    /// The sound itself: mono float samples in -1…1.
    public func samples(sampleRate: Double = RealtimeAudio.sampleRate) -> [Float] {
        switch self {
        case .connected:
            return Self.note(659.25, length: 0.11, peak: 0.22, rate: sampleRate) + Self.note(987.77, length: 0.16, peak: 0.22, rate: sampleRate)
        case .disconnected:
            return Self.note(987.77, length: 0.11, peak: 0.2, rate: sampleRate) + Self.note(659.25, length: 0.18, peak: 0.2, rate: sampleRate)
        case .thinking:
            return Self.tick(rate: sampleRate)
        }
    }

    /// How long it sounds. Worked out once: the gate reads it for every microphone buffer.
    public var duration: TimeInterval {
        switch self {
        case .connected: return Self.connectedDuration
        case .disconnected: return Self.disconnectedDuration
        case .thinking: return Self.tickDuration
        }
    }

    private static let connectedDuration = Double(LiveCue.connected.samples().count) / RealtimeAudio.sampleRate
    private static let disconnectedDuration = Double(LiveCue.disconnected.samples().count) / RealtimeAudio.sampleRate
    private static let tickDuration = Double(LiveCue.thinking.samples().count) / RealtimeAudio.sampleRate

    /// How long the tick may run with no answer before it gives up: a reply that never comes
    /// (a refused request, a transcript that never arrives) must not tick for ever.
    public static let thinkingCeiling: TimeInterval = 45

    /// How often the thinking tick repeats.
    public static let thinkingPeriod: TimeInterval = 1.0
    /// How long after the person stops talking the first tick comes.
    public static let thinkingLead: TimeInterval = 0.35

    /// One period of the thinking loop: the tick, then silence to the end of the period.
    public static func thinkingLoop(sampleRate: Double = RealtimeAudio.sampleRate) -> [Float] {
        let tick = tick(rate: sampleRate)
        return tick + [Float](repeating: 0, count: max(0, Int(thinkingPeriod * sampleRate) - tick.count))
    }

    /// A bell-ish note: the fundamental and a little of its octave, a 5 ms attack, an exponential fade.
    static func note(_ frequency: Double, length: TimeInterval, peak: Float, rate: Double) -> [Float] {
        let count = Int(length * rate)
        let attack = 0.005 * rate
        return (0..<count).map { index in
            let t = Double(index) / rate
            let rise = min(1, Double(index) / attack)
            let fade = exp(-t / (length / 3.2))
            let tone = sin(2 * .pi * frequency * t) + 0.25 * sin(4 * .pi * frequency * t)
            return Float(tone / 1.25 * rise * fade) * peak
        }
    }

    /// A soft, low tap: a sine burst with a raised-cosine envelope, so it has no click at either end.
    static func tick(rate: Double) -> [Float] {
        let length = 0.045
        let count = Int(length * rate)
        return (0..<count).map { index in
            let t = Double(index) / rate
            let envelope = 0.5 - 0.5 * cos(2 * .pi * Double(index) / Double(count))
            return Float(sin(2 * .pi * 520 * t) * envelope) * 0.07
        }
    }
}

/// When the microphone is sent as silence because a cue is sounding. One-shot cues close it for
/// their length plus a tail; the thinking loop closes it for each tick plus a tail. Read on the
/// audio thread for every microphone buffer, so it is a value the engine swaps whole.
public struct LiveCueGate: Sendable, Equatable {
    /// Room after the sound for the room's echo to die and the canceller to settle.
    public static let tail: TimeInterval = 0.08

    /// Closed until then (a one-shot cue).
    public var closedUntil: TimeInterval = 0
    /// The thinking loop: when its first tick sounds; nil when it is not playing.
    public var loopStart: TimeInterval?
    /// From scheduling a sound to the microphone delivering it: the route's output and input
    /// latency and one I/O buffer. On Bluetooth or a car it is often 100–250 ms, so each window
    /// is held open that much longer.
    public var latency: TimeInterval = 0

    public init() {}

    /// A one-shot cue starting at `now`.
    public mutating func oneShot(_ cue: LiveCue, at now: TimeInterval) {
        closedUntil = max(closedUntil, now + cue.duration + Self.tail + latency)
    }

    public mutating func startLoop(at now: TimeInterval) {
        loopStart = now + LiveCue.thinkingLead
    }

    public mutating func stopLoop() {
        loopStart = nil
    }

    /// Whether the microphone buffer spanning `start ..< start + length` is to be sent as silence.
    public func closes(_ start: TimeInterval, length: TimeInterval) -> Bool {
        let end = start + length
        if start < closedUntil { return true }
        guard let loopStart, end > loopStart else { return false }
        let window = LiveCue.thinking.duration + Self.tail + latency
        let period = LiveCue.thinkingPeriod
        // The tick that began at or before this buffer's start, and the one after it.
        let index = floor((start - loopStart) / period)
        let tick = loopStart + max(0, index) * period
        if start < tick + window && end > tick { return true }
        let next = tick + period
        return end > next && start < next + window
    }
}

/// Which cue a call's state change calls for.
public struct LiveCueDirector: Sendable, Equatable {
    public enum Action: Equatable, Sendable {
        case play(LiveCue)
        case startThinking
        case stopThinking
    }

    private var greeted = false
    private(set) var thinking = false

    public init() {}

    public mutating func transition(to state: LiveVoiceState) -> [Action] {
        var actions: [Action] = []
        switch state {
        case .listening:
            if !greeted {
                greeted = true
                actions.append(.play(.connected))
            }
            if thinking { thinking = false; actions.insert(.stopThinking, at: 0) }
        case .thinking, .working:
            if !thinking { thinking = true; actions.append(.startThinking) }
        case .speaking, .connecting, .idle:
            if thinking { thinking = false; actions.append(.stopThinking) }
        }
        return actions
    }

    /// The tick ran `LiveCue.thinkingCeiling` with no answer: stop it.
    public mutating func thinkingTimedOut() -> [Action] {
        guard thinking else { return [] }
        thinking = false
        return [.stopThinking]
    }

    /// The call dropped (not hung up): the falling notes.
    public mutating func dropped() -> [Action] {
        let wasThinking = thinking
        thinking = false
        return (wasThinking ? [.stopThinking] : []) + (greeted ? [.play(.disconnected)] : [])
    }
}

/// Keeps OpenAI's turn detection fed when the microphone stops delivering audio.
///
/// Over a WebSocket the server hears only what is sent, and its turn detection measures silence
/// in the audio it receives, not in wall-clock time. A microphone that stops delivering buffers
/// mid-sentence — the audio engine stopped by an interruption that never says it ended, a route
/// change it did not come back from, the system holding the input — leaves the turn open for
/// ever: the call sits in Listening and never answers. This is that failure's guard: when no
/// microphone buffer has come for `stallAfter`, the call sends silence in its place, at the
/// rate the microphone would have, so the turn ends; and it says so (`mic.stalled`). A
/// buffer arriving again ends the stall.
public struct MicWatchdog: Sendable, Equatable {
    public static let stallAfter: TimeInterval = 0.3
    /// The longest silence one tick sends, so a long-asleep timer cannot flood the socket.
    public static let maxChunk: TimeInterval = 0.25

    public private(set) var lastFrame: TimeInterval?
    /// Silence covers the stream up to here.
    private var coveredUntil: TimeInterval?
    public private(set) var stalledSince: TimeInterval?
    private var silenceSent: TimeInterval = 0

    public init() {}

    public enum Change: Equatable, Sendable {
        case stalled(afterMs: Int)
        case resumed(stalledMs: Int, silenceSentMs: Int)
    }

    /// The microphone opened: from now, no buffer for `stallAfter` is a stall.
    public mutating func arm(at now: TimeInterval) {
        lastFrame = now
        coveredUntil = nil
        stalledSince = nil
        silenceSent = 0
    }

    /// A microphone buffer arrived.
    public mutating func frame(at now: TimeInterval) -> Change? {
        lastFrame = now
        coveredUntil = nil
        guard let since = stalledSince else { return nil }
        stalledSince = nil
        let sent = silenceSent
        silenceSent = 0
        return .resumed(stalledMs: Int(((now - since) * 1_000).rounded()), silenceSentMs: Int((sent * 1_000).rounded()))
    }

    /// The timer fired: how many seconds of silence to send now (0 for none), and whether a
    /// stall just began.
    public mutating func tick(at now: TimeInterval) -> (silence: TimeInterval, change: Change?) {
        guard let lastFrame, now - lastFrame >= Self.stallAfter else { return (0, nil) }
        var change: Change?
        if stalledSince == nil {
            stalledSince = lastFrame
            change = .stalled(afterMs: Int(((now - lastFrame) * 1_000).rounded()))
        }
        let from = coveredUntil ?? lastFrame
        let silence = min(Self.maxChunk, max(0, now - from))
        coveredUntil = from + silence
        silenceSent += silence
        return (silence, change)
    }

    /// Silence for `seconds`, as the PCM16 24 kHz bytes `appendAudio` sends.
    public static func silence(_ seconds: TimeInterval) -> Data {
        Data(count: Int(seconds * RealtimeAudio.sampleRate) * 2)
    }
}
