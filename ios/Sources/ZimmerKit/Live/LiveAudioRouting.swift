import Foundation

/// What a call's one audio engine runs, per voice engine. The app's `LiveAudioEngine` builds its
/// graph from this, so whether the cues, the microphone and the voice share one voice-processing
/// graph is decided here, where it is tested on Linux.
///
/// Apple's voice processing (the echo canceller) turns down every sound in the app that does not
/// go through its own audio unit. So everything a call makes heard has to come out of the same
/// engine as the microphone: the cues on its players, and the voice on its own node, whether it
/// arrives as Realtime's audio deltas or is pulled from libwebrtc on a GPT-Live call.
public struct LiveAudioPlan: Sendable, Equatable {
    /// Where the voice comes from.
    public enum Voice: String, Sendable, Equatable {
        /// Realtime's `response.output_audio.delta`s, scheduled on a player node.
        case scheduled
        /// libwebrtc's playout, pulled by a source node on the engine's render thread
        /// (`LiveWebRTCAudioDevice`): GPT-Live's voice.
        case webRTC
    }

    /// Where the microphone's frames go.
    public enum Microphone: String, Sendable, Equatable {
        /// Up the Realtime WebSocket as `input_audio_buffer.append`.
        case socket
        /// Into libwebrtc as its recorded audio (`LiveWebRTCAudioDevice`).
        case webRTC
    }

    public let voice: Voice
    public let microphone: Microphone
    /// The input node's voice processing is switched on: the echo canceller, with everything
    /// the engine plays (cues and voice) as its reference.
    public let voiceProcessing: Bool
    /// A sounding cue closes the microphone to silence (`LiveCueGate`). Off on GPT-Live: it has no
    /// speech events, so a call learns the person is talking only from their transcript, and a
    /// closed microphone would cut words out of what GPT-Live hears (the web dock drops the gate
    /// on GPT-Live for the same reason). The echo canceller has the cues as reference instead.
    public let gatesMicrophone: Bool

    /// A Realtime call: the microphone up the socket, the reply scheduled, the gate on.
    public static let realtime = LiveAudioPlan(voice: .scheduled, microphone: .socket, voiceProcessing: true, gatesMicrophone: true)
    /// A GPT-Live call: libwebrtc's microphone and voice on the same engine as the cues.
    public static let gptLive = LiveAudioPlan(voice: .webRTC, microphone: .webRTC, voiceProcessing: true, gatesMicrophone: false)

    /// For the log: what this engine carries.
    public var label: String { "\(microphone.rawValue)-mic/\(voice.rawValue)-voice" }
}

/// The state behind libwebrtc's `RTCAudioDevice` contract, apart from the audio: what libwebrtc has
/// initialized and started, and whether a call's engine gets anything from it. libwebrtc calls
/// these in its own order (initialize, then initialize and start playout and recording as the
/// connection's media flows, then stop and terminate); each says whether it succeeded.
public struct LiveAudioDeviceState: Sendable, Equatable {
    public private(set) var initialized = false
    public private(set) var playoutInitialized = false
    public private(set) var playing = false
    public private(set) var recordingInitialized = false
    public private(set) var recording = false

    public init() {}

    public mutating func initialize() -> Bool {
        initialized = true
        return true
    }

    public mutating func terminate() -> Bool {
        self = LiveAudioDeviceState()
        return true
    }

    public mutating func initializePlayout() -> Bool {
        guard initialized else { return false }
        playoutInitialized = true
        return true
    }

    public mutating func startPlayout() -> Bool {
        guard playoutInitialized else { return false }
        playing = true
        return true
    }

    public mutating func stopPlayout() -> Bool {
        playing = false
        playoutInitialized = false
        return true
    }

    public mutating func initializeRecording() -> Bool {
        guard initialized else { return false }
        recordingInitialized = true
        return true
    }

    public mutating func startRecording() -> Bool {
        guard recordingInitialized else { return false }
        recording = true
        return true
    }

    public mutating func stopRecording() -> Bool {
        recording = false
        recordingInitialized = false
        return true
    }
}

/// Pulls libwebrtc's playout — 16-bit PCM — into the float buffer an engine's source node renders,
/// a scratch buffer's worth at a time, with no allocation on the render thread.
public enum LiveVoicePull {
    /// The scratch buffer's size, in frames. A render asks for one hardware buffer, usually
    /// 256–1,024 frames; a larger ask is pulled in pieces.
    public static let chunk = 2_048

    /// Fill `frames` floats of `output`, `chunk` frames at a time through `scratch` (which holds at
    /// least `chunk`). `pull` fills its pointer with that many samples and says whether it could;
    /// a piece it could not fill is silence. Says whether everything came from `pull`.
    @discardableResult
    public static func fill(_ output: UnsafeMutablePointer<Float>, frames: Int, scratch: UnsafeMutablePointer<Int16>,
                            pull: (UnsafeMutablePointer<Int16>, Int) -> Bool) -> Bool {
        var done = 0
        var all = true
        while done < frames {
            let count = min(chunk, frames - done)
            if pull(scratch, count) {
                for index in 0..<count { output[done + index] = Float(scratch[index]) / Float(Int16.max) }
            } else {
                all = false
                (output + done).update(repeating: 0, count: count)
            }
            done += count
        }
        return all
    }
}

/// Answers, from a real call, whether GPT-Live streams the person's transcript while they are
/// still talking, which the *heard* cue depends on (`GptLiveConductor.heardIdle`). GPT-Live's
/// `session.input_transcript.delta` carries each fragment's interval on the session timeline
/// (`start_ms`, `end_ms`), so a run of the person's fragments says both how long they spoke and
/// over how long the fragments arrived. Streamed live, those two are about the same; sent once
/// they stopped, the fragments all arrive at once. No clock offset between the phone and OpenAI is
/// needed for either.
public struct GptLiveInputTiming: Sendable, Equatable {
    /// Fragments further apart than this are two runs: the person spoke again with no answer
    /// between.
    public static let runGap: TimeInterval = 2
    /// One run of the person's transcript, measured when something else starts.
    public struct Run: Sendable, Equatable {
        public let fragments: Int
        /// From the first fragment's start to the last one's end, on GPT-Live's timeline. Nil
        /// when the fragments carried no interval.
        public let spokenMs: Int?
        /// From the first fragment arriving to the last arriving, on the phone.
        public let arrivedOverMs: Int

        public init(fragments: Int, spokenMs: Int?, arrivedOverMs: Int) {
            self.fragments = fragments
            self.spokenMs = spokenMs
            self.arrivedOverMs = arrivedOverMs
        }

        /// The fragments arrived over at least half as long as the person spoke: streamed while
        /// they talked. Nil when there is too little to tell: one fragment, or no intervals, or a
        /// line under half a second.
        public var streamed: Bool? {
            guard fragments > 1, let spokenMs, spokenMs >= 500 else { return nil }
            return arrivedOverMs * 2 >= spokenMs
        }
    }

    private var fragments = 0
    private var firstStartMs: Int?
    private var lastEndMs: Int?
    private var firstArrival: TimeInterval?
    private var lastArrival: TimeInterval?

    public init() {}

    /// Every server event, as it arrives. Returns the run of the person's transcript that just
    /// ended: GPT-Live started answering or delegated, or the person spoke again after `runGap`.
    public mutating func observe(_ event: JSONValue, at now: TimeInterval) -> Run? {
        switch event["type"]?.string {
        case "session.input_transcript.delta":
            var ended: Run?
            if let lastArrival, now - lastArrival > Self.runGap { ended = finish() }
            fragments += 1
            if firstArrival == nil { firstArrival = now }
            lastArrival = now
            if firstStartMs == nil { firstStartMs = Self.milliseconds(event["start_ms"]) }
            if let end = Self.milliseconds(event["end_ms"]) { lastEndMs = end }
            return ended
        case "session.output_transcript.delta", "session.delegation.created":
            return finish()
        default:
            return nil
        }
    }

    /// A timeline value as whole milliseconds; nil for anything that is not a sane number.
    private static func milliseconds(_ value: JSONValue?) -> Int? {
        guard case let .number(number)? = value, number.isFinite, number >= 0, number < 1e12 else { return nil }
        return Int(number)
    }

    /// The run under way, if any: the call is ending.
    public mutating func finish() -> Run? {
        guard fragments > 0, let firstArrival, let lastArrival else { return nil }
        let spoken = firstStartMs.flatMap { start in lastEndMs.map { max(0, $0 - start) } }
        let run = Run(fragments: fragments, spokenMs: spoken, arrivedOverMs: Int(((lastArrival - firstArrival) * 1_000).rounded()))
        self = GptLiveInputTiming()
        return run
    }
}

public extension LiveEvent {
    /// One run of the person's transcript on GPT-Live: whether it streamed while they spoke.
    static func gptLiveInputTiming(_ run: GptLiveInputTiming.Run) -> LiveEvent {
        LiveEvent(.info, "gpt_live.input_transcript") {
            ["fragments": .int(run.fragments), "spoken_ms": .int(run.spokenMs), "arrived_over_ms": .int(run.arrivedOverMs),
             "streamed": run.streamed.map(JSONValue.bool) ?? .null]
        }
    }

    /// libwebrtc started or stopped its playout or recording on the call's engine
    /// (`LiveWebRTCAudioDevice`): the evidence its audio runs on the shared voice-processing graph.
    static func webRTCAudioDevice(_ what: String, state: LiveAudioDeviceState) -> LiveEvent {
        LiveEvent(.info, "audio.webrtc_device") {
            ["what": .string(what), "playing": .bool(state.playing), "recording": .bool(state.recording)]
        }
    }
}
