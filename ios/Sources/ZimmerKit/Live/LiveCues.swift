import Foundation

/// The sounds a Live voice call makes besides Zimmer's voice, so a driver knows what the call is
/// doing without looking. Silence on a call can mean working, stuck or not heard; these tell them
/// apart. They have to carry over road and engine noise on car audio, so they sit near the level
/// of the reply's speech and their fundamentals between 430 and 800 Hz, above the band where a
/// car's noise is loudest; only *failed* and *ended* stay low, because low means *not good*, and
/// they carry on their octave instead.
///
/// They are also heard many times an hour on a long drive, so they are mellow rather than
/// bright: a rounded 30 ms attack and a 30 ms release on every note, no fundamental above G5
/// (784 Hz), only a trace of the octave on the high notes, and no odd harmonics, which make a low
/// note buzz. The two loops, the sounds heard most, are pure sine pulses in the C5 range. The
/// rules, and how to add or change a cue, are in `ios/LIVE_CUES.md`.
///
/// - **pressed**: two quick, level notes (F5, F5), the moment Talk is pressed, before any
///   request is made, on an engine with no microphone. Level, not rising: the call is not on
///   yet;
/// - **connected**: two rising notes (D5 then G5), once, when the call is up and listening;
/// - **heard**: one short note (D5, the first note of *connected*), when the person stops
///   talking and Zimmer takes the line on. It waits `heardLead`, so an answer that starts within
///   it gets none;
/// - **thinking**: one soft sine pulse (C5, 90 ms) every 1.2 seconds, while the model works on
///   an answer and no tool is running. It gives up after `ceiling`;
/// - **working**: a pair (A4 then C5) every 2.5 seconds, while a tool runs, for as long as one
///   runs. Lower, longer and slower than the thinking pulse, so the two never pass for each other;
/// - **failed**: two low notes falling a minor third (F4 then D4), each with a strong octave:
///   a tool failed, a reply failed or was cut short, or no answer came;
/// - **ended**: one low note (E4), with its octave, when the person hangs up;
/// - **disconnected**: the connected notes falling (G5 then D5), once, when a call drops.
///
/// Rising means *on*, falling means *off*. Each is synthesized here at the reply's 24 kHz rate: no
/// audio files.
///
/// None of them should reach OpenAI's turn detection: they play through the same voice-processing
/// engine as the reply, so the echo canceller has them as reference, and while a cue sounds the
/// microphone is sent as silence (`LiveCueGate`).
public enum LiveCue: String, Sendable, CaseIterable {
    case pressed, connected, heard, thinking, working, failed, ended, disconnected

    /// The sound itself: mono float samples in -1…1.
    public func samples(sampleRate: Double = RealtimeAudio.sampleRate) -> [Float] {
        switch self {
        case .pressed:
            return Self.note(698.46, length: 0.085, peak: 0.5, rate: sampleRate) + Self.note(698.46, length: 0.1, peak: 0.5, rate: sampleRate)
        case .connected:
            return Self.note(587.33, length: 0.13, peak: 0.5, rate: sampleRate) + Self.note(783.99, length: 0.18, peak: 0.5, rate: sampleRate)
        case .heard:
            return Self.note(587.33, length: 0.14, peak: 0.52, rate: sampleRate)
        case .disconnected:
            return Self.note(783.99, length: 0.13, peak: 0.5, rate: sampleRate) + Self.note(587.33, length: 0.2, peak: 0.5, rate: sampleRate)
        case .thinking:
            return Self.tap(523.25, length: 0.09, peak: 0.345, rate: sampleRate)
        case .working:
            return Self.tap(440, length: 0.12, peak: 0.345, rate: sampleRate) + Self.tap(523.25, length: 0.12, peak: 0.345, rate: sampleRate)
        case .failed:
            return Self.note(349.23, length: 0.15, peak: 0.53, octave: Self.lowOctave, rate: sampleRate)
                + Self.note(293.66, length: 0.25, peak: 0.53, octave: Self.lowOctave, rate: sampleRate)
        case .ended:
            return Self.note(329.63, length: 0.23, peak: 0.425, octave: Self.lowOctave, rate: sampleRate)
        }
    }

    /// How long it sounds. Worked out once: the gate reads it for every microphone buffer.
    public var duration: TimeInterval { Self.durations[self] ?? 0 }

    private static let durations = Dictionary(uniqueKeysWithValues: allCases.map {
        ($0, Double($0.samples().count) / RealtimeAudio.sampleRate)
    })

    /// How long after the person stops talking the *heard* note comes.
    public static let heardLead: TimeInterval = 0.35

    /// How often the cue repeats, for the two that loop.
    /// Thinking pulses a little slower than once a second: often enough to say the call is alive,
    /// not so often that a long answer turns into a metronome.
    public var period: TimeInterval { self == .working ? 2.5 : 1.2 }

    /// How long after it is asked for the loop's first sound comes. Thinking leaves room for the
    /// *heard* note before its first pulse.
    public var lead: TimeInterval { self == .working ? 0.35 : 1.0 }

    /// How long the loop may run before it gives up. Thinking: a reply that never comes (a refused
    /// request, a transcript that never arrives) must not tick for ever. Working: far longer than
    /// any tool call, because a relay always ends in a result or an error; this catches only
    /// a call whose relay somehow never came back.
    public var ceiling: TimeInterval { self == .working ? 600 : 45 }

    /// One period of the loop: the sound, then silence to the end of the period.
    public func loop(sampleRate: Double = RealtimeAudio.sampleRate) -> [Float] {
        let sound = samples(sampleRate: sampleRate)
        return sound + [Float](repeating: 0, count: max(0, Int(period * sampleRate) - sound.count))
    }

    /// How much of its octave a low note carries: enough to put its energy at 600–700 Hz, where a
    /// car's noise leaves it heard, while it still reads as low.
    static let lowOctave = 0.45
    /// How long a note takes to reach full level, and to fade to nothing at its end.
    static let attack: TimeInterval = 0.03
    static let release: TimeInterval = 0.03

    /// A soft, round note: the fundamental and a trace of its octave (more for the low notes),
    /// never an odd harmonic. A raised-cosine `attack` and `release`, so it neither clicks nor
    /// snaps on, and an exponential fade between them, like a soft mallet on a wooden bar.
    static func note(_ frequency: Double, length: TimeInterval, peak: Float, octave: Double = 0.06, rate: Double) -> [Float] {
        let count = Int(length * rate)
        let attack = Self.attack * rate
        let release = Self.release * rate
        return (0..<count).map { index in
            let t = Double(index) / rate
            let rise = 0.5 - 0.5 * cos(.pi * min(1, Double(index) / attack))
            let end = 0.5 - 0.5 * cos(.pi * min(1, Double(count - 1 - index) / release))
            let fade = exp(-t / (length / 2))
            let tone = sin(2 * .pi * frequency * t) + octave * sin(4 * .pi * frequency * t)
            return Float(tone / (1 + octave) * rise * end * fade) * peak
        }
    }

    /// A pulse: a pure sine with a raised-cosine envelope, half of it rising, so it swells in and
    /// out with no click at either end and no partial above its own pitch.
    static func tap(_ frequency: Double, length: TimeInterval, peak: Float, rate: Double) -> [Float] {
        let count = Int(length * rate)
        return (0..<count).map { index in
            let t = Double(index) / rate
            let envelope = 0.5 - 0.5 * cos(2 * .pi * Double(index) / Double(count))
            return Float(sin(2 * .pi * frequency * t) * envelope) * peak
        }
    }
}

/// When the microphone is sent as silence because a cue is sounding. One-shot cues close it for
/// their length plus a tail; a loop closes it for each repeat plus a tail. Read on the audio
/// thread for every microphone buffer, so it is a value the engine swaps whole.
public struct LiveCueGate: Sendable, Equatable {
    /// Room after the sound for the room's echo to die and the canceller to settle. The cues are
    /// near speech level, so a car's cabin rings on after them for longer than a quiet tone's.
    public static let tail: TimeInterval = 0.12

    /// A one-shot cue's window: closed from `closedFrom` until `closedUntil`. A cue waiting its
    /// turn leaves the microphone open until it sounds.
    public var closedFrom: TimeInterval = 0
    public var closedUntil: TimeInterval = 0
    /// The cue looping, and when its first repeat sounds; nil when none is.
    public var loop: LiveCue?
    public var loopStart: TimeInterval?
    /// From scheduling a sound to the microphone delivering it: the route's output and input
    /// latency and one I/O buffer. On Bluetooth or a car it is often 100–250 ms, so each window
    /// is held open that much longer.
    public var latency: TimeInterval = 0

    public init() {}

    /// A one-shot cue starting at `start`; `now` is when it was scheduled.
    public mutating func oneShot(_ cue: LiveCue, at start: TimeInterval, now: TimeInterval? = nil) {
        closedFrom = closedUntil > (now ?? start) ? min(closedFrom, start) : start
        closedUntil = max(closedUntil, start + cue.duration + Self.tail + latency)
    }

    public mutating func clearOneShots() {
        closedFrom = 0
        closedUntil = 0
    }

    public mutating func startLoop(_ cue: LiveCue, at start: TimeInterval) {
        loop = cue
        loopStart = start
    }

    public mutating func stopLoop() {
        loop = nil
        loopStart = nil
    }

    /// Whether the microphone buffer spanning `start ..< start + length` is to be sent as silence.
    public func closes(_ start: TimeInterval, length: TimeInterval) -> Bool {
        let end = start + length
        if start < closedUntil && end > closedFrom { return true }
        guard let loop, let loopStart, end > loopStart else { return false }
        let window = loop.duration + Self.tail + latency
        // The repeat that began at or before this buffer's start, and the one after it.
        let index = floor((start - loopStart) / loop.period)
        let repeatStart = loopStart + max(0, index) * loop.period
        if start < repeatStart + window && end > repeatStart { return true }
        let next = repeatStart + loop.period
        return end > next && start < next + window
    }
}

/// Which cue a call's state change or signal calls for.
///
/// The event-to-cue map, the same on the phone and in the car. The web (`lib/live_cues.js`) has
/// the same map without *pressed*, at its own levels:
///
/// | What happened | Cue |
/// | --- | --- |
/// | Talk was pressed, or a call starts that nobody pressed for (`LiveCall`, not this type) | *pressed*, once |
/// | The call is up | *connected*, once |
/// | The person stopped talking and the line will be answered | *heard* |
/// | The model is working on an answer, no tool running | *thinking* loop |
/// | A tool is running | *working* loop, to its end |
/// | The last tool finished, reply not started | back to the *thinking* loop |
/// | The person starts talking, or a reply starts | every cue stops at once; none starts until they stop |
/// | The person stops, or a reply ends, with a tool still running | *working* loop again |
/// | A tool failed, a reply failed or was cut short, an error ended the wait for an answer | *failed*, once a turn, after the person stops talking |
/// | The thinking or working ceiling passes | the loop stops, *failed* |
/// | The person hangs up | *ended* |
/// | The call drops | *disconnected* |
public struct LiveCueDirector: Sendable, Equatable {
    public enum Action: Equatable, Sendable {
        case play(LiveCue, after: TimeInterval = 0)
        case startLoop(LiveCue)
        case stopLoop
        /// Stop the loop and any one-shot still sounding or waiting to.
        case stopCues
    }

    /// What the call knows beyond its state (`RealtimeConductor.Effect.signal`).
    public enum Signal: Equatable, Sendable {
        /// The person started talking.
        case personTalking
        /// The person stopped talking.
        case personStopped
        /// The person stopped talking and this line will be answered.
        case heardPerson
        /// This many tools are running.
        case toolsRunning(Int)
        /// What the person asked for did not happen.
        case actionFailed
        /// An error ended whatever was going on. A failure only if the call was on something:
        /// a stray protocol error while it waits for the person means nothing to them.
        case noAnswerComing
    }

    private var greeted = false
    private var state: LiveVoiceState = .idle
    private var tools = 0
    private var talking = false
    private var failureSounded = false
    private var failureHeld = false
    private(set) var loop: LiveCue?

    public init() {}

    public mutating func transition(to state: LiveVoiceState) -> [Action] {
        self.state = state
        var actions: [Action] = []
        switch state {
        case .listening:
            if !greeted {
                greeted = true
                actions.append(.play(.connected))
            }
        case .speaking:
            failureSounded = false
            loop = nil
            return [.stopCues]
        case .thinking, .working, .connecting, .idle:
            break
        }
        return settle() + actions
    }

    public mutating func receive(_ signal: Signal) -> [Action] {
        switch signal {
        case .personTalking:
            talking = true
            failureSounded = false
            loop = nil
            return [.stopCues]
        case .personStopped:
            talking = false
            let held = failureHeld ? receive(.actionFailed) : []
            failureHeld = false
            return settle() + held
        case .heardPerson:
            return state == .speaking || talking ? [] : [.play(.heard, after: LiveCue.heardLead)]
        case let .toolsRunning(count):
            tools = count
            return settle()
        case .actionFailed:
            // Never while the person talks: it would close the microphone on them.
            if talking {
                failureHeld = true
                return []
            }
            guard !failureSounded else { return [] }
            failureSounded = true
            return [.play(.failed)]
        case .noAnswerComing:
            return loop == nil ? [] : receive(.actionFailed)
        }
    }

    /// The loop ran past its ceiling with no answer: stop it, and say so.
    public mutating func loopTimedOut() -> [Action] {
        guard loop != nil else { return [] }
        loop = nil
        return [.stopLoop] + receive(.actionFailed)
    }

    /// The call dropped (not hung up): the falling notes.
    public mutating func dropped() -> [Action] {
        farewell(.disconnected)
    }

    /// The person hung up.
    public mutating func hungUp() -> [Action] {
        farewell(.ended)
    }

    private mutating func farewell(_ cue: LiveCue) -> [Action] {
        let quiet: [Action] = greeted || loop != nil ? [.stopCues] : []
        let goodbye: [Action] = greeted ? [.play(cue)] : []
        loop = nil
        state = .idle
        greeted = false
        return quiet + goodbye
    }

    /// The loop the call should be hearing now.
    private var wanted: LiveCue? {
        guard !talking else { return nil }
        switch state {
        case .thinking, .working: return tools > 0 ? .working : .thinking
        case .listening: return tools > 0 ? .working : nil
        case .speaking, .connecting, .idle: return nil
        }
    }

    private mutating func settle() -> [Action] {
        guard wanted != loop else { return [] }
        let stopping: [Action] = loop == nil ? [] : [.stopLoop]
        loop = wanted
        return stopping + (loop.map { [.startLoop($0)] } ?? [])
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
