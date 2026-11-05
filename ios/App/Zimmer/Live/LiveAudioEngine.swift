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
/// the tap and restarts it, or says it could not through `failed`. When the microphone goes
/// quiet anyway, `LiveCall`'s watchdog covers it with silence so OpenAI's turn still ends, and
/// asks for `recoverIfStopped()`.
///
/// **The cues** (`LiveCue`) play on two more player nodes on the same engine, so the echo
/// canceller has them as reference like the reply; and while one sounds, the microphone is sent
/// as silence (`LiveCueGate`), so OpenAI's turn detection never takes a cue for speech. One node
/// holds the loop and the other the one-shots, because a buffer scheduled behind a looping
/// buffer never plays. A cue never talks over the reply: it waits out what is still queued.
///
/// Every step is reported to `LiveTelemetry`: the permission, the audio session as configured,
/// the route and its changes, interruptions, the engine starting, restarting or failing.
///
/// **Main actor, and one owner at a time.** This class is main-actor only, and every decision
/// about the engine is made there. The calls that can block go to one serial queue instead
/// (`queue`), because they do block: `engine.start()` once took 770 s with the main thread
/// waiting on it, so nothing could time the call out, press End or draw the screen. An engine
/// on that queue is not in `self.engine`: it is built there and handed over when it is up, it
/// is handed back for a restart, and it is given away for good to be torn down, so two threads
/// never reconfigure it at once, which AVAudioEngine does not survive. An engine stuck on the
/// queue is simply given up on; whatever comes back is torn down there. The other thing that
/// runs off the main thread is the microphone tap, on the audio thread; it is built outside the
/// actor (`makeTap`), so it is not main-actor code that Swift 6 would stop the app for running
/// off the main thread, and it reads only the lock-guarded `FrameSink`.
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

    private nonisolated static let log = Logger(subsystem: "com.tadasant.zimmer", category: "live-audio")
    nonisolated(unsafe) private static let replyFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: RealtimeAudio.sampleRate, channels: 1, interleaved: false)!
    /// Where the audio calls that can block run, one at a time.
    private nonisolated static let queue = DispatchQueue(label: "com.tadasant.zimmer.live-audio", qos: .userInitiated)

    /// Where the tap sends the microphone's frames, and when a cue closes them to silence: the
    /// one thing the audio thread touches.
    final class FrameSink: @unchecked Sendable {
        private let lock = NSLock()
        private var frames: (@Sendable (Data) -> Void)?
        private var gate = LiveCueGate()
        private var lastBuffer: TimeInterval?

        func set(_ frames: (@Sendable (Data) -> Void)?) {
            lock.withLock {
                self.frames = frames
                gate = LiveCueGate()
                lastBuffer = nil
            }
        }

        /// When the microphone last delivered a buffer, on the audio thread's clock: what the
        /// watchdog reads, so frames still queued for the main actor never count as a stall.
        var lastAudio: TimeInterval? { lock.withLock { lastBuffer } }

        func changeGate(_ change: (inout LiveCueGate) -> Void) {
            lock.withLock { change(&gate) }
        }

        /// `seconds`: how much audio the buffer holds, which ended about now.
        func send(_ pcm: Data, seconds: TimeInterval) {
            let now = ProcessInfo.processInfo.systemUptime
            let (frames, closed) = lock.withLock { () -> ((@Sendable (Data) -> Void)?, Bool) in
                lastBuffer = now
                return (self.frames, gate.closes(now - seconds, length: seconds))
            }
            frames?(closed ? Data(count: pcm.count) : pcm)
        }
    }

    /// One call's engine and its players, as handed between the main actor and `queue`.
    private struct Graph: @unchecked Sendable {
        let engine: AVAudioEngine
        let player: AVAudioPlayerNode
        let cuePlayer: AVAudioPlayerNode
        let loopPlayer: AVAudioPlayerNode

        func configure(sink: FrameSink, restart: Bool) throws {
            let input = engine.inputNode
            // The echo canceller. Not fatal when refused: the mic still works, and headphones
            // sidestep echo entirely.
            var voiceProcessing = true
            do {
                try input.setVoiceProcessingEnabled(true)
            } catch {
                voiceProcessing = false
                LiveAudioEngine.log.error("voice processing refused, so the reply may echo: \(error.localizedDescription, privacy: .public)")
            }
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else { throw Failure.noInput }
            input.removeTap(onBus: 0)
            // No format: the tap takes the node's own, whatever the route made it. A format read
            // a moment earlier can disagree with the hardware once the car's microphone takes
            // over, and a tap whose format disagrees is an exception, not an error.
            input.installTap(onBus: 0, bufferSize: 1_024, format: nil, block: LiveAudioEngine.makeTap(sink))
            if player.engine == nil { engine.attach(player) }
            if cuePlayer.engine == nil { engine.attach(cuePlayer) }
            if loopPlayer.engine == nil { engine.attach(loopPlayer) }
            engine.connect(player, to: engine.mainMixerNode, format: LiveAudioEngine.replyFormat)
            engine.connect(cuePlayer, to: engine.mainMixerNode, format: LiveAudioEngine.replyFormat)
            engine.connect(loopPlayer, to: engine.mainMixerNode, format: LiveAudioEngine.replyFormat)
            engine.prepare()
            try engine.start()
            player.play()
            cuePlayer.play()
            loopPlayer.play()
            // How long a cue takes from scheduling to coming back through the microphone.
            let session = AVAudioSession.sharedInstance()
            let latency = session.outputLatency + session.inputLatency + session.ioBufferDuration
            sink.changeGate { $0.latency = latency }
            LiveAudioEngine.telemetry.track(.audioEngineStarted(inputRate: format.sampleRate, inputChannels: Int(format.channelCount),
                                                                voiceProcessing: voiceProcessing && input.isVoiceProcessingEnabled, restart: restart))
        }

        func tearDown(deactivate: Bool) {
            engine.inputNode.removeTap(onBus: 0)
            player.stop()
            cuePlayer.stop()
            loopPlayer.stop()
            engine.stop()
            if deactivate { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
        }
    }

    private nonisolated static let telemetry = LiveTelemetry.shared

    /// Run `work` on `queue`, waiting without holding the main actor.
    private nonisolated static func onQueue(_ work: @escaping @Sendable () throws -> Void) async throws {
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    try work()
                    done.resume()
                } catch {
                    done.resume(throwing: error)
                }
            }
        }
    }

    /// `.voiceChat` is the mode a call runs in; `.allowBluetooth` lets AirPods or the car be the
    /// microphone.
    private nonisolated static func activateSession() throws {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP])
            try session.setActive(true)
        } catch {
            telemetry.track(.audioEngineFailed("audio session: \(error.localizedDescription)", restart: false))
            throw error
        }
        telemetry.track(.audioSessionConfigured(session))
    }

    private let sink = FrameSink()
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    /// The one-shot cues' own player, so stopping the reply (the person talked over it) never
    /// cuts a cue and stopping a cue never cuts the reply.
    private var cuePlayer: AVAudioPlayerNode?
    /// The looping cue's own player.
    private var loopPlayer: AVAudioPlayerNode?
    private var looping: LiveCue?
    /// When the last one-shot scheduled finishes: the next plays after it, whatever it asked for.
    private var cuesEnd: TimeInterval = 0
    /// Engines out on `queue` being started or restarted: the audio session is theirs.
    private var bringingUp = 0
    /// The microphone permission prompt is waiting on the person.
    private(set) var awaitingPermission = false
    /// Between an interruption's `.began` and its `.ended`: the session belongs to someone else
    /// (a phone call, Siri), and reactivating it would fail and end the call.
    private(set) var interrupted = false
    /// The last call's engine, kept up to play its farewell cue.
    private var farewell: (task: Task<Void, Never>, graph: Graph)?
    private var failed: (@Sendable (String) -> Void)?
    private var observers: [NSObjectProtocol] = []
    /// Bumped by every start and stop, so a start still waiting on the permission prompt, or a
    /// late stop from an older call, cannot touch a newer call's engine.
    private var token = 0
    /// Bumped when the audio daemon restarts: an engine from before it is dead, and touching it
    /// would crash, so one that comes back from `queue` afterwards is left alone.
    private var resets = 0
    /// What is queued on the reply player, and how far through it the speaker is.
    private var playout = LiveReplyPlayout()

    /// Open the microphone and the reply player. `frames` gets PCM16 at 24 kHz, about 21 ms at a
    /// time. Returns the token `stop(token:)` takes.
    @discardableResult
    func start(frames: @escaping @Sendable (Data) -> Void, failed: @escaping @Sendable (String) -> Void) async throws -> Int {
        stop()
        interrupted = false
        token += 1
        let mine = token
        let asked = ProcessInfo.processInfo.systemUptime
        awaitingPermission = AVAudioApplication.shared.recordPermission == .undetermined
        let granted = await AVAudioApplication.requestRecordPermission()
        awaitingPermission = false
        Self.telemetry.track(.micPermission(granted: granted, ms: ProcessInfo.processInfo.systemUptime - asked))
        guard granted else { throw Failure.microphoneDenied }
        // A newer start (or a stop) came while the permission prompt was up.
        guard token == mine else { throw CancellationError() }

        let graph = Graph(engine: AVAudioEngine(), player: AVAudioPlayerNode(), cuePlayer: AVAudioPlayerNode(), loopPlayer: AVAudioPlayerNode())
        let sink = self.sink
        sink.set(frames)
        self.failed = failed
        observe(graph.engine)
        let resetsThen = resets
        bringingUp += 1
        var failure: Error?
        do {
            try await Self.onQueue {
                try Self.activateSession()
                do {
                    try graph.configure(sink: sink, restart: false)
                } catch {
                    Self.telemetry.track(.audioEngineFailed(String(describing: error), restart: false))
                    throw error
                }
            }
        } catch {
            failure = error
        }
        bringingUp -= 1
        // Hung up, or replaced, while the engine was starting: it comes back to be torn down.
        guard token == mine else {
            if resets == resetsThen { retire(graph) }
            throw CancellationError()
        }
        if let failure {
            stop()
            if resets == resetsThen { retire(graph) }
            throw failure
        }
        engine = graph.engine
        player = graph.player
        cuePlayer = graph.cuePlayer
        loopPlayer = graph.loopPlayer
        return mine
    }

    /// Tear an engine down on `queue`. The audio session goes with it unless another call has it.
    private func retire(_ graph: Graph) {
        let deactivate = engine == nil && bringingUp == 0
        Self.queue.async { graph.tearDown(deactivate: deactivate) }
    }

    /// The microphone tap, made outside the main actor: it runs on the audio thread. It reads
    /// the rate from each buffer, so a route change that moves the hardware rate cannot leave it
    /// resampling at the old one.
    private nonisolated static func makeTap(_ sink: FrameSink) -> AVAudioNodeTapBlock {
        { buffer, _ in
            guard let channel = buffer.floatChannelData?[0], buffer.format.sampleRate > 0 else { return }
            let samples = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
            let rate = buffer.format.sampleRate
            sink.send(RealtimeAudio.pcm16(from: samples, sampleRate: rate), seconds: Double(buffer.frameLength) / rate)
        }
    }

    /// Route changes, interruptions and a media-services reset, each handled on the main queue
    /// where every other engine change is made.
    private func observe(_ engine: AVAudioEngine) {
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()
        observers = [
            center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    Self.telemetry.track(.audioConfigurationChanged(running: self?.engine?.isRunning ?? false))
                    self?.recoverIfStopped()
                }
            },
            center.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: .main) { [weak self] note in
                guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                      let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
                let options = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt).map(AVAudioSession.InterruptionOptions.init(rawValue:))
                let reason = note.userInfo?[AVAudioSessionInterruptionReasonKey] as? UInt
                MainActor.assumeIsolated {
                    Self.telemetry.track(.audioInterruption(began: type == .began, shouldResume: options.map { $0.contains(.shouldResume) },
                                                            reason: reason))
                    self?.interrupted = type == .began
                    if type == .ended { self?.recoverIfStopped() }
                }
            },
            center.addObserver(forName: AVAudioSession.routeChangeNotification, object: session, queue: .main) { note in
                guard let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                      let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return }
                MainActor.assumeIsolated {
                    Self.telemetry.track(.audioRouteChanged(reason: reason, route: AVAudioSession.sharedInstance().currentRoute))
                }
            },
            // The audio daemon restarted: every engine and node is dead, and touching this one
            // again would crash. End the call; the car's retry, or the person, starts a new one.
            center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: session, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    Self.telemetry.track(.mediaServicesReset())
                    guard let self else { return }
                    self.resets += 1
                    let report = self.failed
                    self.abandon()
                    report?("The phone's audio restarted. Start the call again.")
                }
            },
        ]
    }

    /// Restart an engine that stopped under the call: after a configuration change, an
    /// interruption that ended, or the microphone going quiet. A running engine is left alone,
    /// and so is one stopped by an interruption still under way: the session is not ours until
    /// it ends, and the call carries on (its turn kept alive with silence) until then.
    ///
    /// The restart runs on `queue`. Until it comes back the cues and the reply find no engine
    /// here and do nothing, and a hang-up leaves it to be torn down when it does.
    func recoverIfStopped() {
        guard !interrupted, let engine, let player, let cuePlayer, let loopPlayer, !engine.isRunning else { return }
        let graph = Graph(engine: engine, player: player, cuePlayer: cuePlayer, loopPlayer: loopPlayer)
        let sink = self.sink
        let mine = token
        let resetsThen = resets
        // The restart stops the player, on `queue`: what it held will not be heard.
        playout.queueDropped(at: ProcessInfo.processInfo.systemUptime)
        cuesEnd = 0
        sink.changeGate {
            $0.stopLoop()
            $0.clearOneShots()
        }
        self.engine = nil
        self.player = nil
        self.cuePlayer = nil
        self.loopPlayer = nil
        bringingUp += 1
        Task { [weak self] in
            var failure: Error?
            do {
                try await Self.onQueue {
                    graph.player.stop()
                    graph.cuePlayer.stop()
                    graph.loopPlayer.stop()
                    try AVAudioSession.sharedInstance().setActive(true)
                    try graph.configure(sink: sink, restart: true)
                }
            } catch {
                failure = error
            }
            guard let self else { return }
            self.bringingUp -= 1
            guard self.resets == resetsThen else { return }
            guard self.token == mine else {
                self.retire(graph)
                return
            }
            self.engine = graph.engine
            self.player = graph.player
            self.cuePlayer = graph.cuePlayer
            self.loopPlayer = graph.loopPlayer
            if let failure {
                Self.log.error("live audio engine could not restart: \(failure.localizedDescription, privacy: .public)")
                Self.telemetry.track(.audioEngineFailed(failure.localizedDescription, restart: true))
                self.failed?("The microphone stopped when the audio route changed. Start the call again.")
                return
            }
            Self.log.notice("live audio engine restarted after a configuration change")
            // Whatever is meant to be looping now: a stop while the engine was out cleared it.
            if let again = self.looping {
                self.looping = nil
                self.startLoop(again)
            }
        }
    }

    /// When the microphone last delivered audio (system uptime), or nil before it has.
    var lastMicAudio: TimeInterval? { sink.lastAudio }

    // MARK: - Cues

    /// Play a one-shot cue after `delay`, or once the queued reply has played if that is later,
    /// closing the microphone while it sounds. Says whether it was scheduled.
    @discardableResult
    func play(_ cue: LiveCue, after delay: TimeInterval = 0) -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        let free = max(now, cuesEnd)
        let start = max(now + max(delay, replyRemaining), free)
        let silence = [Float](repeating: 0, count: Int((start - free) * RealtimeAudio.sampleRate))
        guard let engine, let cuePlayer, engine.isRunning, let buffer = Self.buffer(silence + cue.samples()) else { return false }
        cuesEnd = start + cue.duration
        sink.changeGate { $0.oneShot(cue, at: start, now: now) }
        cuePlayer.scheduleBuffer(buffer, completionHandler: nil)
        return true
    }

    /// Loop `cue` from its lead, or from the end of the queued reply, until `stopLoop()`.
    func startLoop(_ cue: LiveCue) {
        guard looping == nil else { return }
        // Remembered even with the engine stopped, so `recoverIfStopped()` brings it back.
        looping = cue
        let wait = max(cue.lead, replyRemaining)
        guard let engine, let loopPlayer, engine.isRunning,
              let lead = Self.buffer([Float](repeating: 0, count: Int(wait * RealtimeAudio.sampleRate))),
              let loop = Self.buffer(cue.loop()) else { return }
        let start = ProcessInfo.processInfo.systemUptime + wait
        sink.changeGate { $0.startLoop(cue, at: start) }
        loopPlayer.scheduleBuffer(lead, completionHandler: nil)
        loopPlayer.scheduleBuffer(loop, at: nil, options: .loops, completionHandler: nil)
    }

    /// A cue with no call up to carry it: the car giving up on a call, which may never have got
    /// its engine started. The engine exists for the cue and the audio session for as long as
    /// it sounds. Skipped while the audio is someone else's, or while an engine is out on
    /// `queue`, stuck or not: a failure cue that sounds minutes late is worse than none. Says
    /// whether it was asked for: once on `queue`, a failure is only logged.
    func playAlone(_ cue: LiveCue) -> Bool {
        guard engine == nil, farewell == nil, bringingUp == 0, !interrupted else { return false }
        let samples = cue.samples()
        Self.queue.async {
            guard let buffer = Self.buffer(samples) else { return }
            let engine = AVAudioEngine()
            let player = AVAudioPlayerNode()
            do {
                try Self.activateSession()
                engine.attach(player)
                engine.connect(player, to: engine.mainMixerNode, format: Self.replyFormat)
                try engine.start()
                player.scheduleBuffer(buffer, completionHandler: nil)
                player.play()
                Thread.sleep(forTimeInterval: cue.duration + 0.05)
                player.stop()
                engine.stop()
            } catch {
                Self.log.error("cue with no call could not play: \(error.localizedDescription, privacy: .public)")
            }
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
        return true
    }

    /// Stop the loop at once.
    func stopLoop() {
        guard looping != nil else { return }
        looping = nil
        sink.changeGate { $0.stopLoop() }
        guard let engine, let loopPlayer, engine.isRunning else { return }
        loopPlayer.stop()
        loopPlayer.play()
    }

    /// Stop every cue at once, a one-shot still waiting its turn included: the person is talking
    /// or the reply is starting.
    func stopCues() {
        stopLoop()
        cuesEnd = 0
        sink.changeGate { $0.clearOneShots() }
        guard let engine, let cuePlayer, engine.isRunning else { return }
        cuePlayer.stop()
        cuePlayer.play()
    }

    /// How much of the reply is still to come out of the speaker.
    private var replyRemaining: TimeInterval {
        playout.remaining(at: ProcessInfo.processInfo.systemUptime)
    }

    private nonisolated static func buffer(_ samples: [Float]) -> AVAudioPCMBuffer? {
        guard !samples.isEmpty,
              let buffer = AVAudioPCMBuffer(pcmFormat: replyFormat, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else { return nil }
        samples.withUnsafeBufferPointer { source in
            channel.update(from: source.baseAddress!, count: samples.count)
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        return buffer
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
        playout.scheduled(samples: samples.count, at: ProcessInfo.processInfo.systemUptime)
        player.scheduleBuffer(buffer, completionHandler: nil)
    }

    /// A new reply item's audio follows whatever is still queued.
    func replyStarted(itemID: String) {
        playout.started(itemID: itemID, at: ProcessInfo.processInfo.systemUptime)
    }

    /// The user started talking: drop any reply audio still to sound, and say which items were
    /// not heard to the end and how much of each was. The player stops whatever the answer: that
    /// is a model of it, and a player with nothing queued loses nothing.
    func stopPlayback(arriving: String?) -> [LiveReplyPlayout.Cut] {
        if let engine, let player, engine.isRunning {
            player.stop()
            player.play()
        }
        return playout.stop(at: ProcessInfo.processInfo.systemUptime, latency: AVAudioSession.sharedInstance().outputLatency,
                            arriving: arriving)
    }

    /// Close the microphone and the player. With a `token`, only if it is still that start's call.
    /// With a `farewell` cue, the microphone closes at once and the engine stays up just long
    /// enough to play it. Says whether the farewell is playing.
    @discardableResult
    func stop(token expected: Int? = nil, farewell: LiveCue? = nil) -> Bool {
        if let expected, expected != token { return false }
        // The last call's goodbye is cut short rather than left running beside a new engine.
        if let pending = self.farewell {
            self.farewell = nil
            pending.task.cancel()
            retire(pending.graph)
        }
        var current: Graph?
        if let engine, let player, let cuePlayer, let loopPlayer {
            current = Graph(engine: engine, player: player, cuePlayer: cuePlayer, loopPlayer: loopPlayer)
        }
        playout = LiveReplyPlayout()
        let playing = farewell.map { play($0) } ?? false
        abandon()
        guard let graph = current else { return false }
        guard let farewell, playing else {
            retire(graph)
            return false
        }
        Self.queue.async {
            graph.engine.inputNode.removeTap(onBus: 0)
            graph.player.stop()
            graph.loopPlayer.stop()
        }
        let goodbye = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(farewell.duration + 0.05))
            guard !Task.isCancelled, let self, self.farewell?.graph.engine === graph.engine else { return }
            self.farewell = nil
            // A new call may have started meanwhile: it owns the audio session now.
            self.retire(graph)
        }
        self.farewell = (goodbye, graph)
        return true
    }

    /// Forget the call's engine without touching it.
    private func abandon() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        token += 1
        playout = LiveReplyPlayout()
        engine = nil
        player = nil
        cuePlayer = nil
        loopPlayer = nil
        looping = nil
        cuesEnd = 0
        sink.set(nil)
        failed = nil
    }
}
