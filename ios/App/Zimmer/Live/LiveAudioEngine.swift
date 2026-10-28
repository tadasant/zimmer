@preconcurrency import AVFoundation
import Foundation
import ZimmerKit
import os

/// A Live Mode voice call's audio on the phone: the open microphone up, OpenAI's spoken reply down.
///
/// Built the way Motet's Play Live is (`AVLiveAudio` in tadasant/motet): one `AVAudioEngine`
/// with the input node's voice processing switched on — Apple's echo canceller — and the reply
/// played through a player node on the *same* engine, so the canceller has the reply as its
/// reference and the model does not hear itself. The microphone's float samples are resampled
/// to the 16-bit 24 kHz PCM the Realtime API takes (`RealtimeAudio`, tested in ZimmerKit).
///
/// The engine can stop under a call (AirPods connecting, the car connecting or disconnecting, a
/// phone call): every node call is guarded on it running, and a configuration change rebuilds
/// the tap and restarts it, or says it could not through `failed`.
///
/// **Main actor only.** Every engine change — start, stop, a restart after a route change — is
/// made on the main thread, one at a time. A route change used to restart the engine on the
/// notification's own thread while a hang-up stopped it on the main one, and AVAudioEngine
/// does not survive two threads reconfiguring it at once. The one thing that runs elsewhere is
/// the microphone tap, on the audio thread; it is built outside the actor (`makeTap`), so it
/// is not main-actor code that Swift 6 would stop the app for running off the main thread, and
/// it reads only the lock-guarded `FrameSink`.
@MainActor
final class LiveAudioEngine {
    enum Failure: Error, CustomStringConvertible {
        case microphoneDenied
        case noInput

        var description: String {
            switch self {
            case .microphoneDenied: return "Microphone access is off for Zimmer. Turn it on in Settings → Zimmer to talk to Live Mode."
            case .noInput: return "No microphone is available."
            }
        }
    }

    private static let log = Logger(subsystem: "com.tadasant.zimmer", category: "live-audio")
    private static let replyFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: RealtimeAudio.sampleRate, channels: 1, interleaved: false)!

    /// Where the tap sends the microphone's frames: the one thing the audio thread touches.
    final class FrameSink: @unchecked Sendable {
        private let lock = NSLock()
        private var frames: (@Sendable (Data) -> Void)?

        func set(_ frames: (@Sendable (Data) -> Void)?) {
            lock.withLock { self.frames = frames }
        }

        func send(_ pcm: Data) {
            let frames = lock.withLock { self.frames }
            frames?(pcm)
        }
    }

    private let sink = FrameSink()
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var failed: (@Sendable (String) -> Void)?
    private var observers: [NSObjectProtocol] = []
    /// Bumped by every start and stop, so a start still waiting on the permission prompt, or a
    /// late stop from an older call, cannot touch a newer call's engine.
    private var token = 0
    /// The reply item playing now: when its audio started, and how much of it was queued.
    private var replyStartedAt: Date?
    private var replyQueuedMs = 0

    /// Open the microphone and the reply player. `frames` gets PCM16 at 24 kHz, about 21 ms at a
    /// time. Returns the token `stop(token:)` takes.
    @discardableResult
    func start(frames: @escaping @Sendable (Data) -> Void, failed: @escaping @Sendable (String) -> Void) async throws -> Int {
        stop()
        token += 1
        let mine = token
        guard await AVAudioApplication.requestRecordPermission() else { throw Failure.microphoneDenied }
        // A newer start (or a stop) came while the permission prompt was up.
        guard token == mine else { throw CancellationError() }

        let session = AVAudioSession.sharedInstance()
        // `.voiceChat` is the mode a call runs in; `.allowBluetooth` lets AirPods or the car be
        // the microphone.
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP])
        try session.setActive(true)

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        self.engine = engine
        self.player = player
        sink.set(frames)
        self.failed = failed
        do {
            try configure(engine: engine, player: player)
        } catch {
            stop()
            throw error
        }
        observe(engine)
        return mine
    }

    private func configure(engine: AVAudioEngine, player: AVAudioPlayerNode) throws {
        let input = engine.inputNode
        // The echo canceller. Not fatal when refused: the mic still works, and headphones
        // sidestep echo entirely.
        do {
            try input.setVoiceProcessingEnabled(true)
        } catch {
            Self.log.error("voice processing refused, so the reply may echo: \(error.localizedDescription, privacy: .public)")
        }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw Failure.noInput }
        input.removeTap(onBus: 0)
        // No format: the tap takes the node's own, whatever the route made it. A format read
        // a moment earlier can disagree with the hardware once the car's microphone takes
        // over, and a tap whose format disagrees is an exception, not an error.
        input.installTap(onBus: 0, bufferSize: 1_024, format: nil, block: Self.makeTap(sink))
        if player.engine == nil { engine.attach(player) }
        engine.connect(player, to: engine.mainMixerNode, format: Self.replyFormat)
        engine.prepare()
        try engine.start()
        player.play()
    }

    /// The microphone tap, made outside the main actor: it runs on the audio thread. It reads
    /// the rate from each buffer, so a route change that moves the hardware rate cannot leave it
    /// resampling at the old one.
    private nonisolated static func makeTap(_ sink: FrameSink) -> AVAudioNodeTapBlock {
        { buffer, _ in
            guard let channel = buffer.floatChannelData?[0], buffer.format.sampleRate > 0 else { return }
            let samples = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
            sink.send(RealtimeAudio.pcm16(from: samples, sampleRate: buffer.format.sampleRate))
        }
    }

    /// Route changes, interruptions and a media-services reset, each handled on the main queue
    /// where every other engine change is made.
    private func observe(_ engine: AVAudioEngine) {
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()
        observers = [
            center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.restartIfStopped() }
            },
            center.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: .main) { [weak self] note in
                guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                      AVAudioSession.InterruptionType(rawValue: raw) == .ended else { return }
                MainActor.assumeIsolated { self?.restartIfStopped() }
            },
            // The audio daemon restarted: every engine and node is dead, and touching this one
            // again would crash. End the call; the car's retry, or the person, starts a new one.
            center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: session, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let report = self.failed
                    self.abandon()
                    report?("The phone's audio restarted. Start the call again.")
                }
            },
        ]
    }

    private func restartIfStopped() {
        guard let engine, let player, !engine.isRunning else { return }
        player.stop()
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            try configure(engine: engine, player: player)
            Self.log.notice("live audio engine restarted after a configuration change")
        } catch {
            Self.log.error("live audio engine could not restart: \(error.localizedDescription, privacy: .public)")
            failed?("The microphone stopped when the audio route changed. Start the call again.")
        }
    }

    /// Queue a chunk of the reply: 16-bit mono PCM at 24 kHz.
    func play(_ pcm16: Data) {
        let samples = RealtimeAudio.floats(fromPCM16: pcm16)
        guard !samples.isEmpty,
              let buffer = AVAudioPCMBuffer(pcmFormat: Self.replyFormat, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else { return }
        samples.withUnsafeBufferPointer { source in
            channel.update(from: source.baseAddress!, count: samples.count)
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        guard let engine, let player, engine.isRunning else { return }
        if replyStartedAt == nil { replyStartedAt = Date() }
        replyQueuedMs += samples.count * 1_000 / Int(RealtimeAudio.sampleRate)
        player.scheduleBuffer(buffer, completionHandler: nil)
    }

    /// A new reply item starts: count its audio from zero.
    func replyStarted() {
        replyStartedAt = nil
        replyQueuedMs = 0
    }

    /// Drop the reply that is playing — the user started talking over it — and say roughly how
    /// many milliseconds of it were heard: the time since it started, up to what was queued.
    @discardableResult
    func stopPlayback() -> Int {
        let elapsed = replyStartedAt.map { Int(Date().timeIntervalSince($0) * 1_000) } ?? 0
        let heard = min(elapsed, replyQueuedMs)
        replyStartedAt = nil
        replyQueuedMs = 0
        if let engine, let player, engine.isRunning {
            player.stop()
            player.play()
        }
        return heard
    }

    /// Close the microphone and the player. With a `token`, only if it is still that start's call.
    func stop(token expected: Int? = nil) {
        if let expected, expected != token { return }
        let engine = self.engine
        let player = self.player
        abandon()
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        player?.stop()
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Forget the call's engine without touching it.
    private func abandon() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        token += 1
        replyStartedAt = nil
        replyQueuedMs = 0
        engine = nil
        player = nil
        sink.set(nil)
        failed = nil
    }
}
