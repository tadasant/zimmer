@preconcurrency import AVFoundation
import Foundation
import ZimmerKit
import os

/// Live Voice's audio on the phone: the open microphone up, OpenAI's spoken reply down.
///
/// Built the way Motet's Play Live is (`AVLiveAudio` in tadasant/motet): one `AVAudioEngine`
/// with the input node's voice processing switched on — Apple's echo canceller — and the reply
/// played through a player node on the *same* engine, so the canceller has the reply as its
/// reference and the model does not hear itself. The microphone's float samples are resampled
/// to the 16-bit 24 kHz PCM the Realtime API takes (`RealtimeAudio`, tested in ZimmerKit).
///
/// The engine can stop under a call (AirPods connecting, a phone call): every node call is
/// guarded on it running, and a configuration change rebuilds the tap and restarts it, or says
/// it could not through `failed`.
final class LiveAudioEngine: @unchecked Sendable {
    enum Failure: Error, CustomStringConvertible {
        case microphoneDenied
        case noInput

        var description: String {
            switch self {
            case .microphoneDenied: return "Microphone access is off for Zimmer. Turn it on in Settings → Zimmer to use Live Voice."
            case .noInput: return "No microphone is available."
            }
        }
    }

    private static let log = Logger(subsystem: "com.tadasant.zimmer", category: "live-audio")
    private static let replyFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: RealtimeAudio.sampleRate, channels: 1, interleaved: false)!

    private let lock = NSLock()
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var frames: (@Sendable (Data) -> Void)?
    private var failed: (@Sendable (String) -> Void)?
    private var observers: [NSObjectProtocol] = []

    /// Open the microphone and the reply player. `frames` gets PCM16 at 24 kHz, about 21 ms at a time.
    func start(frames: @escaping @Sendable (Data) -> Void, failed: @escaping @Sendable (String) -> Void) async throws {
        stop()
        guard await AVAudioApplication.requestRecordPermission() else { throw Failure.microphoneDenied }

        let session = AVAudioSession.sharedInstance()
        // `.voiceChat` is the mode a call runs in; `.allowBluetooth` lets AirPods or the car be
        // the microphone.
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP])
        try session.setActive(true)

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        lock.withLock {
            self.engine = engine
            self.player = player
            self.frames = frames
            self.failed = failed
        }
        do {
            try configure(engine: engine, player: player)
        } catch {
            stop()
            throw error
        }
        observe(engine)
    }

    private func configure(engine: AVAudioEngine, player: AVAudioPlayerNode) throws {
        let input = engine.inputNode
        // The echo canceller. Not fatal when refused: the mic still works, and headphones
        // sidestep echo entirely.
        try? input.setVoiceProcessingEnabled(true)
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw Failure.noInput }
        let rate = format.sampleRate
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1_024, format: format) { [weak self] buffer, _ in
            guard let self, let channel = buffer.floatChannelData?[0] else { return }
            let samples = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
            let sink = self.lock.withLock { self.frames }
            sink?(RealtimeAudio.pcm16(from: samples, sampleRate: rate))
        }
        if player.engine == nil { engine.attach(player) }
        engine.connect(player, to: engine.mainMixerNode, format: Self.replyFormat)
        engine.prepare()
        try engine.start()
        player.play()
    }

    private func observe(_ engine: AVAudioEngine) {
        let center = NotificationCenter.default
        let restart: @Sendable (Notification) -> Void = { [weak self] _ in self?.restartIfStopped() }
        let added = [
            center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil, using: restart),
            center.addObserver(forName: AVAudioSession.interruptionNotification, object: AVAudioSession.sharedInstance(), queue: nil) { [weak self] note in
                guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                      AVAudioSession.InterruptionType(rawValue: raw) == .ended else { return }
                self?.restartIfStopped()
            },
        ]
        lock.withLock { observers = added }
    }

    private func restartIfStopped() {
        let current = lock.withLock { () -> (AVAudioEngine, AVAudioPlayerNode)? in
            guard let engine, let player else { return nil }
            return (engine, player)
        }
        guard let (engine, player) = current, !engine.isRunning else { return }
        player.stop()
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            try configure(engine: engine, player: player)
            Self.log.notice("live audio engine restarted after a configuration change")
        } catch {
            Self.log.error("live audio engine could not restart: \(error.localizedDescription, privacy: .public)")
            let report = lock.withLock { failed }
            report?("The microphone stopped when the audio route changed. Start the call again.")
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
        let state = lock.withLock { () -> (AVAudioEngine, AVAudioPlayerNode)? in
            guard let engine, let player else { return nil }
            return (engine, player)
        }
        guard let (engine, player) = state, engine.isRunning else { return }
        player.scheduleBuffer(buffer, completionHandler: nil)
    }

    /// Drop the reply that is playing — the user started talking over it.
    func stopPlayback() {
        let state = lock.withLock { () -> (AVAudioEngine, AVAudioPlayerNode)? in
            guard let engine, let player else { return nil }
            return (engine, player)
        }
        guard let (engine, player) = state, engine.isRunning else { return }
        player.stop()
        player.play()
    }

    func stop() {
        let (engine, player, observers) = lock.withLock { () -> (AVAudioEngine?, AVAudioPlayerNode?, [NSObjectProtocol]) in
            defer {
                self.engine = nil
                self.player = nil
                self.frames = nil
                self.failed = nil
                self.observers = []
            }
            return (self.engine, self.player, self.observers)
        }
        observers.forEach(NotificationCenter.default.removeObserver)
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        player?.stop()
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
