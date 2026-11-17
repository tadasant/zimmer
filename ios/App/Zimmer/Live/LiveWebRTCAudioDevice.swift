@preconcurrency import AVFoundation
import Foundation
@preconcurrency import WebRTC
import ZimmerKit
import os

/// libwebrtc's audio device on a GPT-Live call: the call's own `LiveAudioEngine`, not libwebrtc's.
///
/// Left to itself libwebrtc runs its own voice-processing audio unit, and Apple's voice processing
/// turns down every other sound in the app — the cues included, which played from a second engine
/// beside it. Given this device instead (`GptLiveLink`'s factory), libwebrtc opens no audio unit:
/// the call's engine, with voice processing on its input node, hands it the microphone and pulls
/// its playout, so the cues, the microphone and GPT-Live's voice share one voice-processing graph,
/// as on Realtime (`LiveAudioPlan.gptLive`).
///
///   microphone   the engine's tap → `FrameSink` (16-bit, 24 kHz, mono) → `deliver` →
///                libwebrtc's `deliverRecordedData`
///   voice        the engine's source node renders → `render` → libwebrtc's `getPlayoutData`
///                (16-bit, 24 kHz, mono) → floats on the main mixer, beside the cue players
///
/// One for the app's life, as the factory is. libwebrtc says when its playout and recording run;
/// the call's engine says when there is an engine to run them on. Until both, the microphone's
/// frames go nowhere and the voice node plays silence. The audio session is the engine's
/// (`LiveAudioEngine.activateSession`); libwebrtc never touches it.
final class LiveWebRTCAudioDevice: NSObject, RTCAudioDevice, @unchecked Sendable {
    static let shared = LiveWebRTCAudioDevice()

    private static let log = Logger(subsystem: "com.tadasant.zimmer", category: "live-audio")
    private static let telemetry = LiveTelemetry.shared

    private let lock = NSLock()
    private var state = LiveAudioDeviceState()
    private var delegate: (any RTCAudioDeviceDelegate)?
    /// Recorded frames delivered, for the timestamps libwebrtc is handed.
    private var recordedFrames: Double = 0

    // MARK: - What libwebrtc reads: one 24 kHz mono channel each way

    var deviceInputSampleRate: Double { RealtimeAudio.sampleRate }
    var deviceOutputSampleRate: Double { RealtimeAudio.sampleRate }
    var inputNumberOfChannels: Int { 1 }
    var outputNumberOfChannels: Int { 1 }
    var inputIOBufferDuration: TimeInterval { AVAudioSession.sharedInstance().ioBufferDuration }
    var outputIOBufferDuration: TimeInterval { AVAudioSession.sharedInstance().ioBufferDuration }
    var inputLatency: TimeInterval { AVAudioSession.sharedInstance().inputLatency }
    var outputLatency: TimeInterval { AVAudioSession.sharedInstance().outputLatency }

    var isInitialized: Bool { lock.withLock { state.initialized } }
    var isPlayoutInitialized: Bool { lock.withLock { state.playoutInitialized } }
    var isPlaying: Bool { lock.withLock { state.playing } }
    var isRecordingInitialized: Bool { lock.withLock { state.recordingInitialized } }
    var isRecording: Bool { lock.withLock { state.recording } }

    // MARK: - libwebrtc's lifecycle calls

    func initialize(with delegate: any RTCAudioDeviceDelegate) -> Bool {
        lock.withLock {
            self.delegate = delegate
            return state.initialize()
        }
    }

    func terminateDevice() -> Bool {
        change("terminated") { state in
            delegate = nil
            return state.terminate()
        }
    }

    func initializePlayout() -> Bool { lock.withLock { state.initializePlayout() } }
    func startPlayout() -> Bool { change("playout_started") { $0.startPlayout() } }
    func stopPlayout() -> Bool { change("playout_stopped") { $0.stopPlayout() } }
    func initializeRecording() -> Bool { lock.withLock { state.initializeRecording() } }

    func startRecording() -> Bool {
        change("recording_started") { state in
            recordedFrames = 0
            return state.startRecording()
        }
    }

    func stopRecording() -> Bool { change("recording_stopped") { $0.stopRecording() } }

    private func change(_ what: String, _ body: (inout LiveAudioDeviceState) -> Bool) -> Bool {
        let (ok, now) = lock.withLock { () -> (Bool, LiveAudioDeviceState) in
            let ok = body(&state)
            return (ok, state)
        }
        Self.log.notice("webrtc audio device \(what, privacy: .public): playing \(now.playing), recording \(now.recording)")
        Self.telemetry.track(.webRTCAudioDevice(what, state: now))
        return ok
    }

    // MARK: - The call's engine

    /// The microphone, from the engine's tap on the audio thread: 16-bit mono PCM at 24 kHz, the
    /// frames a Realtime call sends up its socket.
    func deliver(_ pcm16: Data) {
        let frames = pcm16.count / MemoryLayout<Int16>.size
        guard frames > 0 else { return }
        let taken = lock.withLock { () -> ((any RTCAudioDeviceDelegate), Double)? in
            guard state.recording, let current = self.delegate else { return nil }
            defer { recordedFrames += Double(frames) }
            return (current, recordedFrames)
        }
        guard let taken else { return }
        let recorder = taken.0
        let sampleTime = taken.1
        var flags = AudioUnitRenderActionFlags()
        var timestamp = AudioTimeStamp()
        timestamp.mSampleTime = sampleTime
        timestamp.mFlags = .sampleTimeValid
        pcm16.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            var list = AudioBufferList(mNumberBuffers: 1,
                                       mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(frames * MemoryLayout<Int16>.size),
                                                             mData: UnsafeMutableRawPointer(mutating: base)))
            _ = recorder.deliverRecordedData(&flags, &timestamp, 1, UInt32(frames), &list, nil, nil)
        }
    }

    /// GPT-Live's voice, for the engine's source node on the render thread: `frames` floats into
    /// `output`, through `scratch` (`LiveVoicePull.chunk` samples). Silence while libwebrtc is not
    /// playing; says whether it was.
    func render(into output: UnsafeMutablePointer<Float>, frames: Int, scratch: UnsafeMutablePointer<Int16>) -> Bool {
        guard let player = lock.withLock({ state.playing ? self.delegate : nil }) else {
            output.update(repeating: 0, count: frames)
            return false
        }
        LiveVoicePull.fill(output, frames: frames, scratch: scratch) { samples, count in
            var flags = AudioUnitRenderActionFlags()
            var timestamp = AudioTimeStamp()
            var list = AudioBufferList(mNumberBuffers: 1,
                                       mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(count * MemoryLayout<Int16>.size),
                                                             mData: UnsafeMutableRawPointer(samples)))
            return player.getPlayoutData(&flags, &timestamp, 0, UInt32(count), &list) == noErr
        }
        return true
    }

    /// The engine restarted, or a new call's engine took over: its tap and render threads are new
    /// ones, which libwebrtc is told before it is handed audio from them.
    func audioThreadsChanged() {
        guard let module = lock.withLock({ self.delegate }) else { return }
        module.dispatchAsync {
            module.notifyAudioInputInterrupted()
            module.notifyAudioOutputInterrupted()
        }
    }
}
