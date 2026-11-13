import Foundation
import UIKit
import ZimmerKit
import os

/// The one voice call the app can have, shared by the phone's screens and the CarPlay scene — a
/// call started in one carries on in the other.
///
/// Starting a call turns voice on for its conversation first (`POST …/mode`), so Enable voice on
/// a typed thread, Talk on a spoken one and CarPlay's Resume all take the same path: Zimmer
/// mints a secret only for a conversation in voice, with instructions written for speech.
///
/// Every request the call makes names the client driving it: `carplay` for a call the car
/// started or took over, `ios` otherwise. Zimmer records it on the conversation, and from the
/// car the live model's instructions say the person is driving.
///
/// The audio never touches Zimmer. Zimmer mints a short-lived OpenAI Realtime secret whose
/// session config it chose (`POST /live_conversations/:id/client_secret`); the phone opens a
/// WebSocket to OpenAI's `websocket_url` with it, streams the microphone up as
/// `input_audio_buffer.append`, and plays `response.output_audio.delta` back. What to do with
/// every server event is `RealtimeConductor`'s call (ZimmerKit, tested on Linux): function calls
/// are relayed to Zimmer and answered, transcript lines recorded, `response.create` sent once.
///
/// A call is up when its microphone is open and OpenAI has said `session.created`, and not
/// before: *Listening* and the connected notes both mean somebody can hear you.
///
/// Four things keep a driver from having to look: the cues (`LiveCueDirector` has the whole map:
/// up, heard, thinking, a tool running, failed, hung up, dropped; and *pressed*, played here the
/// moment Talk is pressed, `pressed()`); the
/// microphone watchdog (`MicWatchdog`), which sends silence when the microphone stops delivering
/// so OpenAI's turn detection always gets to the end of a turn; the call's health
/// (`LiveCallHealth`), which gives up on a call that will not connect, or whose socket or
/// microphone has gone; and the call log (`LiveTelemetry`), which records every step for whoever
/// reads the trace afterwards.
///
/// **A call follows the current conversation.** Live Mode has one current conversation, and it
/// can move under a call: the live model switching when asked, or another device. A tool call that
/// moved it says so at once (`RealtimeConductor.Effect.reattach`), and a call up looks for any other
/// move every few seconds. Either way the call reconnects (`reattach(to:)`): a Realtime session
/// cannot forget what it heard, so the old thread would stay in the model's head, and a new session
/// starts from the new conversation's own recap. It is the same call to everyone watching: the
/// microphone stays open, mute stays as it was, and the state goes to Connecting… and never idle,
/// so the car's one template stays up.
///
/// **A call can be hung up by voice.** "Hang up" or "stop listening" makes the live model call
/// `hang_up`; Zimmer answers `hang_up`, the conductor asks for nothing more and says `hangUp` once
/// the response that asked is done, and the call ends the way End ends it — hung-up cue and all —
/// as soon as the goodbye has finished sounding — or `hangUpGrace` after Zimmer answered, whatever
/// is still sounding or still to come. Talking over the goodbye stops it, so the call ends sooner.
/// A move to another conversation is not followed meanwhile. `endedByVoice` says so, so the car
/// treats it as the driver's End and not as a drop to retry.
@MainActor
final class LiveCall: ObservableObject {
    static let shared = LiveCall()

    @Published private(set) var state: LiveVoiceState = .idle {
        didSet { if state != oldValue { stateChanged(from: oldValue) } }
    }
    @Published private(set) var conversationID: Int?
    @Published private(set) var muted = false
    @Published private(set) var lastError: String?
    /// The microphone has been out long enough to say so: nothing said is reaching the call.
    @Published private(set) var microphoneLost = false
    /// Bumped on every recorded line or tool call, so an open thread knows to read again.
    @Published private(set) var activity = 0
    /// The phone's way to a call the car left on it. Here rather than on `AppModel`: CarPlay can
    /// run the app with no phone scene and so no model, and this outlives the car's scene.
    @Published private(set) var handover = LiveHandover()
    /// Turn detection heard speech it has not ended the turn on: Send now would send it
    /// (`RealtimeConductor.canEndTurn`). Follows the conductor through every change to it.
    @Published private(set) var canSendNow = false

    private var conductor = RealtimeConductor() {
        didSet { if conductor.canEndTurn != canSendNow { canSendNow = conductor.canEndTurn } }
    }
    /// Send now's debounce and its timings, for the log (`LiveSendNow`).
    private var sendNowLog = LiveSendNow()
    private var sendNowFollowup: Task<Void, Never>?
    /// An opening line given while the call was still connecting: sent once it is up. `recorded`:
    /// the thread carries it, which it does not for the line a call that moved opens with.
    private var pendingOpening: (text: String, recorded: Bool)?
    private var socket: URLSessionWebSocketTask?
    private let audio = LiveAudioEngine()
    /// Moves on with every start and hang-up, so a late answer from an old call is ignored.
    private var generation = 0
    /// The generation the microphone was opened under. Moving to another conversation moves
    /// `generation` to drop the old socket's late answers, and keeps the microphone.
    private var microphoneGeneration: Int?
    /// When this call last asked which conversation is current.
    private var lookedForMove: TimeInterval = 0
    private static let followEvery: TimeInterval = 5
    private let log = Logger(subsystem: "com.tadasant.zimmer", category: "live-call")
    private let telemetry = LiveTelemetry.shared
    private var timeline = LiveCallTimeline()
    private var cues = LiveCueDirector()
    private var watchdog = MicWatchdog()
    private var health = LiveCallHealth()
    /// The microphone's engine is up.
    private var microphoneOpen = false
    /// OpenAI has said `session.created`: the socket works.
    private var sessionOpen = false
    /// The client the secret was minted for: its instructions name it.
    private var mintedFor = ClientSource.Surface.ios
    /// The last call dropped and played the falling notes, so nothing more needs to be heard. A
    /// hang-up's goodbye is not news of a failure and does not count.
    private var saidGoodbye = false
    private var watching: Task<Void, Never>?
    /// When *pressed* last went out for a press that has not become a call yet, so the call it
    /// becomes does not play it again.
    private var pressHeard: TimeInterval?
    /// When Talk was last pressed, heard or not: the startup metric's zero (`call.startup`).
    private var pressedAt: TimeInterval?
    /// This call's tap, until `call.startup` and `call.first_audio` have been logged from it.
    private var tappedAt: TimeInterval?
    private var firstAudioFrom: TimeInterval?
    /// How this call got going: on a warm connection from the car, or cold.
    private var startPath = LiveStartPath.cold
    /// A call on a warm connection keeps the microphone off the socket until the fresh
    /// `session.update` has gone up, so nothing said reaches a session still on the warm-up's
    /// instructions. Cleared before the call is up, so nobody is ever told to talk into it.
    private var holdingMicrophone = false
    /// The warm connection this call took, kept alive here: its receive loop is what delivers
    /// OpenAI's events to the call (`LiveWarmLink.handOver`).
    private var warmLink: LiveWarmLink?
    /// OpenAI answered the tap's `session.update` on the warm connection.
    private var warmUpdated = false
    /// The warm connection failed after the tap, before the call was up: the start falls back.
    private var warmSocketFailure: String?
    /// How long the tap waits for `session.updated` on a warm connection before falling back.
    private static let warmUpdateDeadline: TimeInterval = 3
    /// The last call ended because the person asked it to by voice (`hang_up`), not by a tap or
    /// a failure.
    private(set) var endedByVoice = false
    /// The longest a voice hang-up waits for the goodbye to finish sounding: a call must never
    /// stay open because the playout model is off.
    private static let hangUpGrace: TimeInterval = 8

    private static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// The cue looping now, and since when: what its ceiling is measured from.
    private var looping: (cue: LiveCue, since: TimeInterval)?

    init() {
        // Whatever the call log holds goes before iOS suspends the app, in a background task so
        // the send is given the time to finish.
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { Self.flushInBackground() }
        }
        // iOS or the person is ending the app: the call's end is kept for the next launch to send.
        NotificationCenter.default.addObserver(forName: UIApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.end(reason: "app_terminated", farewell: []) }
        }
    }

    private static func flushInBackground() {
        let background = BackgroundTask()
        background.id = UIApplication.shared.beginBackgroundTask(withName: "live-telemetry") {
            MainActor.assumeIsolated { background.end() }
        }
        Task { @MainActor in
            await LiveTelemetry.shared.send()
            background.end()
        }
    }

    /// One `beginBackgroundTask`, ended once: when the send finishes or iOS runs out of time.
    @MainActor
    private final class BackgroundTask {
        var id: UIBackgroundTaskIdentifier = .invalid

        func end() {
            guard id != .invalid else { return }
            UIApplication.shared.endBackgroundTask(id)
            id = .invalid
        }
    }

    /// The phone or the car: which client is driving the call.
    private(set) var surface: ClientSource.Surface = .ios

    private var api: any LiveAPI { AppEnvironment.shared.connection.api.live(from: surface) }

    var isActive: Bool { state != .idle }

    func isActive(for conversation: Int) -> Bool { isActive && conversationID == conversation }

    /// `voiceIsOn`: the caller has just turned voice on, so a second `POST …/mode` is not raced
    /// against a Type instead pressed while the call connects.
    ///
    /// `opening`: a line to put to the model as soon as the call is up, as if the person had
    /// typed it — a tapped session row in the car, which names that session. Recorded
    /// on the thread as a user turn, so the transcript carries why the model answered as it did.
    /// On a call already running for this conversation it is sent at once.
    ///
    /// `surface`: the client starting it. A call already running for this conversation is
    /// handed over to it (`carryOn(on:)`).
    ///
    /// `startsMuted`: the microphone is off from the first frame, for a call coming back from
    /// the car's voice settings to a driver who had muted it.
    ///
    /// `warm`: the car's Continue, which may take the connection CarPlay pre-warm holds for this
    /// conversation (`LiveWarmKeeper`). A call coming back from the voice settings never does:
    /// it must be minted from the row the panel wrote.
    func start(_ conversation: Int, voiceIsOn: Bool = false, opening: String? = nil, startsMuted: Bool = false,
               from surface: ClientSource.Surface = .ios, warm allowWarm: Bool = false) async {
        if isActive(for: conversation) {
            await carryOn(on: surface)
            // Hung up, or replaced, while the hand-over was answered.
            guard isActive(for: conversation) else { return }
            if let opening {
                // Still connecting: there is no socket to send on yet; the start under way sends it.
                if !health.isConnected { pendingOpening = (text: opening, recorded: true) } else { open(with: opening) }
            }
            return
        }
        // A start nobody pressed for just now (the phone's button, a retry) is heard the same way.
        let alreadyHeard = pressHeard.map { Self.now - $0 < LiveCallHealth.connectDeadline } ?? false
        let tapped = pressedAt.flatMap { Self.now - $0 < LiveCallHealth.connectDeadline ? $0 : nil } ?? Self.now
        end(reason: "hang_up", farewell: cues.hungUp())
        if !alreadyHeard { pressed() }
        pressHeard = nil
        pressedAt = nil
        // Before the state moves, which the keeper reads as a call starting and closes what it holds.
        let warm = allowWarm && surface == .carplay ? LiveWarmKeeper.shared.claim(conversation) : nil
        tappedAt = tapped
        firstAudioFrom = tapped
        startPath = warm == nil ? .cold : .warm
        holdingMicrophone = false
        warmUpdated = false
        warmSocketFailure = nil
        generation += 1
        let mine = generation
        self.surface = surface
        conversationID = conversation
        conductor = RealtimeConductor()
        cues = LiveCueDirector()
        timeline = LiveCallTimeline()
        timeline.started(at: Self.now)
        sendNowLog = LiveSendNow()
        sendNowFollowup?.cancel()
        watchdog = MicWatchdog()
        health = LiveCallHealth()
        health.started(at: Self.now)
        microphoneOpen = false
        sessionOpen = false
        mintedFor = surface
        pendingOpening = opening.map { (text: $0, recorded: true) }
        lookedForMove = Self.now
        saidGoodbye = false
        lastError = nil
        muted = startsMuted
        telemetry.beginCall(conversation: conversation)
        telemetry.updateClient { $0.surface = surface.rawValue }
        telemetry.track(.callStarting(surface: surface.rawValue, opening: opening != nil))
        state = .connecting
        watch(generation: mine)
        do {
            if let warm {
                try await startWarm(warm, conversation: conversation, voiceIsOn: voiceIsOn, generation: mine)
                return
            }
            if !voiceIsOn { try await turnVoiceOn(conversation) }
            guard mine == generation else { return }
            mintedFor = self.surface
            let asked = Self.now
            let secret = try await mintSecret(conversation)
            guard mine == generation else { return }
            telemetry.adopt(secret.telemetry)
            telemetry.track(.secretMinted(ms: Self.now - asked, model: secret.model, listening: secret.listening, telemetry: secret.telemetry))
            conductor = RealtimeConductor(listening: secret.listening)
            openSocket(secret, generation: mine)
            health.stage = .microphone
            microphoneGeneration = mine
            let audioToken = try await audio.start(
                frames: { [weak self] pcm in Task { @MainActor in self?.sendAudio(pcm, microphone: mine) } },
                failed: { [weak self] message in Task { @MainActor in self?.microphoneFailed(message, microphone: mine) } }
            )
            // Hung up, or replaced by a newer call, while the microphone was opening: close only
            // what this start opened.
            guard mine == generation else { audio.stop(token: audioToken); return }
            watchdog.arm(at: Self.now)
            microphoneOpen = true
            health.stage = .session
            connectIfReady(generation: mine)
        } catch is CancellationError {
            return
        } catch {
            fail(Self.describe(error), generation: mine)
        }
    }

    private func openSocket(_ secret: LiveClientSecret, generation mine: Int) {
        var request = URLRequest(url: secret.websocketURL)
        request.setValue("Bearer \(secret.clientSecret)", forHTTPHeaderField: "Authorization")
        let task = URLSession.shared.webSocketTask(with: request)
        socket = task
        task.resume()
        receive(task, generation: mine)
    }

    /// The car's Continue on the connection CarPlay pre-warm held (`LiveWarmKeeper`): OpenAI has
    /// already said `session.created` on it, so what is left is the microphone and, alongside it,
    /// voice on and a fresh `session.update` — the warm-up's instructions are as old as the
    /// warm-up, and this brings them to the conversation as it is now, before anything said goes
    /// up. If those fail, the call falls back to the cold path on the same microphone: a new
    /// secret, a new socket, no second tap.
    private func startWarm(_ warm: LiveWarmLink, conversation: Int, voiceIsOn: Bool, generation mine: Int) async throws {
        telemetry.adopt(warm.secret.telemetry)
        conductor = RealtimeConductor(listening: warm.secret.listening)
        mintedFor = surface
        socket = warm.task
        warmLink = warm
        holdingMicrophone = true
        warm.handOver { [weak self] text, failure in
            self?.received(text: text, failure: failure, generation: mine)
        }
        let readied = Task { await self.readyWarm(conversation, voiceIsOn: voiceIsOn, generation: mine) }
        health.stage = .microphone
        microphoneGeneration = mine
        let audioToken: Int
        do {
            audioToken = try await audio.start(
                frames: { [weak self] pcm in Task { @MainActor in self?.sendAudio(pcm, microphone: mine) } },
                failed: { [weak self] message in Task { @MainActor in self?.microphoneFailed(message, microphone: mine) } }
            )
        } catch {
            readied.cancel()
            throw error
        }
        guard mine == generation else {
            readied.cancel()
            audio.stop(token: audioToken)
            return
        }
        watchdog.arm(at: Self.now)
        microphoneOpen = true
        let failure = await readied.value
        guard mine == generation else { return }
        if let failure {
            log.error("warm call fell back to cold: \(failure, privacy: .public)")
            telemetry.track(.warmFallback(failure))
            startPath = .fallback
            warm.close()
            warmLink = nil
            socket = nil
            sessionOpen = false
            try await turnVoiceOn(conversation)
            guard mine == generation else { return }
            mintedFor = surface
            let asked = Self.now
            let secret = try await mintSecret(conversation)
            guard mine == generation else { return }
            telemetry.adopt(secret.telemetry)
            telemetry.track(.secretMinted(ms: Self.now - asked, model: secret.model, listening: secret.listening, telemetry: secret.telemetry))
            conductor = RealtimeConductor(listening: secret.listening)
            openSocket(secret, generation: mine)
        }
        holdingMicrophone = false
        health.stage = .session
        connectIfReady(generation: mine)
    }

    /// Voice on, then the `session.update` that brings the warm session to the conversation as it
    /// is now, and OpenAI's `session.updated` for it: the proof the warm socket still works, before
    /// the microphone is let through and the driver is told to talk. The failure, or nil.
    private func readyWarm(_ conversation: Int, voiceIsOn: Bool, generation mine: Int) async -> String? {
        do {
            if !voiceIsOn { try await turnVoiceOn(conversation) }
            guard mine == generation else { return nil }
            let session = try await api.liveSessionUpdate(conversation, recordingModel: warmLink?.secret.model)
            guard mine == generation else { return nil }
            if let warmSocketFailure { return warmSocketFailure }
            guard sessionOpen else { return "The warm connection had not said session.created." }
            send(conductor.sessionUpdate(keeping: session))
            let asked = Self.now
            while Self.now - asked < Self.warmUpdateDeadline {
                if warmUpdated { return nil }
                if let warmSocketFailure { return warmSocketFailure }
                try await Task.sleep(for: .milliseconds(25))
                guard mine == generation else { return nil }
            }
            return "No session.updated on the warm connection within \(Int(Self.warmUpdateDeadline)) s."
        } catch {
            return Self.describe(error)
        }
    }

    /// The warm connection failed after the tap and before the call was up: the start under way
    /// falls back to cold rather than dropping the call. Says whether it took the failure.
    private func warmFailedBeforeUp(_ failure: String) -> Bool {
        guard startPath == .warm, holdingMicrophone, !health.isConnected else { return false }
        if warmSocketFailure == nil { warmSocketFailure = failure }
        return true
    }

    /// Move this call to `conversation`, which Live Mode has moved to: a new secret, a new socket
    /// and the same microphone. The old socket's late answers are dropped, and what was still
    /// sounding stops. A failure here is a call that dropped, which the car retries on whatever is
    /// current by then. A call still connecting has nothing to move: it is minted from the
    /// conversation it asked for, and fails or looks again once it is up.
    func reattach(to conversation: Int) async {
        guard isActive, health.isConnected, conversationID != conversation else { return }
        generation += 1
        let mine = generation
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        _ = audio.stopPlayback(arriving: nil)
        perform(.stopCues)
        telemetry.track(.callEnded(reason: "switched", duration: timeline.sinceStart(Self.now), summary: timeline.summary))
        telemetry.endCall()
        telemetry.flush()
        telemetry.beginCall(conversation: conversation)
        telemetry.updateClient { $0.surface = surface.rawValue }
        telemetry.track(.callStarting(surface: surface.rawValue, opening: true))
        conversationID = conversation
        handover.callMoved(to: conversation)
        conductor = RealtimeConductor()
        cues = LiveCueDirector()
        timeline = LiveCallTimeline()
        timeline.started(at: Self.now)
        sendNowLog = LiveSendNow()
        sendNowFollowup?.cancel()
        health = LiveCallHealth()
        health.started(at: Self.now)
        sessionOpen = false
        // The health that would have said it came back has just been replaced. Still lost, the
        // new one says so again.
        microphoneLost = false
        mintedFor = surface
        tappedAt = nil
        firstAudioFrom = nil
        holdingMicrophone = false
        warmLink = nil
        pendingOpening = (text: RealtimeConductor.switchedOpening, recorded: false)
        lookedForMove = Self.now
        lastError = nil
        state = .connecting
        watch(generation: mine)
        do {
            let asked = Self.now
            let secret = try await mintSecret(conversation)
            guard mine == generation else { return }
            telemetry.adopt(secret.telemetry)
            telemetry.track(.secretMinted(ms: Self.now - asked, model: secret.model, listening: secret.listening, telemetry: secret.telemetry))
            conductor = RealtimeConductor(listening: secret.listening)
            openSocket(secret, generation: mine)
            health.stage = .session
        } catch is CancellationError {
            return
        } catch {
            fail(Self.describe(error), generation: mine)
        }
    }

    /// Ask which conversation is current, and act on it (`LiveOverview.move`). A failed look changes
    /// nothing: the next one will do. A move this call made itself is on its way already, so the
    /// answer is dropped. A call ended here is a call that dropped: the car retries, and a car's
    /// call turns voice on, because the driver is the one talking.
    private func followCurrent(generation mine: Int) {
        Task {
            guard let overview = try? await api.liveConversations(), mine == generation else { return }
            switch overview.move(forCallOn: conversationID) {
            case .stay: return
            case let .follow(conversation): await reattach(to: conversation)
            case .end: fail("The call ended: Live Mode moved to a typed conversation.", generation: mine)
            }
        }
    }

    /// The call is up once the microphone is open and OpenAI has answered, in either order.
    private func connectIfReady(generation mine: Int) {
        guard mine == generation, !health.isConnected, microphoneOpen, sessionOpen, !holdingMicrophone else { return }
        health.connected(at: Self.now)
        telemetry.track(.connected(sinceStart: timeline.sinceStart(Self.now), listening: conductor.listening, gated: conductor.gated))
        if let tappedAt {
            telemetry.track(.callStartup(path: startPath, tapToReady: Self.now - tappedAt, surface: surface.rawValue))
            self.tappedAt = nil
        }
        state = .listening
        Task {
            // Handed over while connecting, after the secret was asked for: its instructions
            // name the client that started the call, so bring them up to the one driving it.
            if surface != mintedFor { await refreshSession() }
            guard mine == generation else { return }
            let first = pendingOpening
            pendingOpening = nil
            if let first { open(with: first.text, recorded: first.recorded) }
        }
    }

    func hangUp() {
        pressHeard = nil
        pressedAt = nil
        end(reason: "hang_up", farewell: cues.hungUp())
    }

    /// Talk was pressed: *pressed* sounds now, before the conversation is found, voice turned on or
    /// the secret minted, so the press is heard seconds before the call connects. It plays alone,
    /// on an engine that never opens the microphone (`LiveAudioEngine.playAlone`): nothing records
    /// before the call's screen is up, and no permission prompt comes with it. Not while a call
    /// is up, nor over a goodbye still sounding.
    func pressed() {
        guard !isActive else { return }
        let at = Self.now
        pressedAt = at
        let telemetry = telemetry
        guard audio.playAlone(.pressed, handBack: false, sounding: {
            telemetry.track(.cue(.pressed))
            telemetry.track(.acknowledged(sincePress: ProcessInfo.processInfo.systemUptime - at))
        }) else { return }
        pressHeard = at
    }

    /// The person asked to hang up (`RealtimeConductor.Effect.hangUp`): let the goodbye finish
    /// sounding, then end the call as End would. A newer call, or a tap on End meanwhile, makes
    /// this nothing.
    private func hangUpWhenSaid(generation mine: Int) {
        Task {
            while mine == generation, audio.replyRemaining > 0 {
                try? await Task.sleep(for: .milliseconds(100))
            }
            hangUpByVoice(generation: mine)
        }
    }

    /// Zimmer answered `hang_up`: whatever happens next — a `response.done` that never comes, a
    /// reply that will not stop — the call ends `hangUpGrace` from now.
    private func armHangUpDeadline(generation mine: Int) {
        Task {
            try? await Task.sleep(for: .seconds(Self.hangUpGrace))
            hangUpByVoice(generation: mine)
        }
    }

    private func hangUpByVoice(generation mine: Int) {
        guard mine == generation else { return }
        pressHeard = nil
        end(reason: "voice_hang_up", farewell: cues.hungUp(), byVoice: true)
    }

    /// End the call: `reason` is for the log; the `farewell` cue is the engine's last sound.
    private func end(reason: String, farewell: [LiveCueDirector.Action], byVoice: Bool = false) {
        endedByVoice = byVoice
        generation += 1
        watching?.cancel()
        watching = nil
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        microphoneGeneration = nil
        microphoneLost = false
        // The engine stays up just long enough to play the goodbye.
        var goodbye: LiveCue?
        for action in farewell {
            if case let .play(cue, _) = action {
                goodbye = cue
            } else {
                perform(action)
            }
        }
        let played = audio.stop(farewell: goodbye)
        saidGoodbye = played && goodbye == .disconnected
        if played, let goodbye { telemetry.track(.cue(goodbye)) }
        state = .idle
        muted = false
        pendingOpening = nil
        holdingMicrophone = false
        warmLink = nil
        tappedAt = nil
        firstAudioFrom = nil
        // Nothing left to send: the speech the call heard went with it.
        conductor = RealtimeConductor()
        sendNowFollowup?.cancel()
        if telemetry.callID != nil {
            telemetry.track(.callEnded(reason: reason, duration: timeline.sinceStart(Self.now), summary: timeline.summary))
            telemetry.endCall()
            telemetry.flush()
        }
    }

    /// Say with the falling notes that a call is not coming, unless the end that said so already
    /// played them. A call that was never up has no engine to play them for it.
    func soundUnavailable() {
        // The press this answers led nowhere: the next start was not pressed for.
        pressHeard = nil
        guard !isActive, !saidGoodbye else {
            saidGoodbye = false
            return
        }
        if audio.playAlone(.disconnected) { telemetry.track(.cue(.disconnected)) }
    }

    /// Put `text` to the model as a typed line and ask for its reply (`RealtimeConductor.open`).
    private func open(with text: String, recorded: Bool = true) {
        guard let conversation = conversationID else { return }
        let mine = generation
        apply(conductor.open(with: text), generation: mine)
        guard recorded else { return }
        Task {
            _ = try? await api.recordLiveTurn(conversation, role: .user, content: text, gated: false)
            guard mine == generation else { return }
            activity += 1
        }
    }

    /// Send now: end the turn turn detection is still in and send what was said
    /// (`RealtimeConductor.endTurn`), whatever the turn detection. A tap within the debounce of
    /// the last, a tap with nothing heard, and a tap while the last send is still out send nothing;
    /// each is logged with what it came to (`LiveSendNow`), never with what was said.
    func sendNow() {
        let now = Self.now
        // A tap CarPlay delivers late, from a screen that has just changed, can find the call
        // muted or deaf: nothing more to send.
        guard isActive, health.isConnected, !muted, !microphoneLost else {
            telemetry.track(sendNowLog.record(.ignoredEmpty, surface: surface.rawValue, at: now))
            return
        }
        guard sendNowLog.tap(at: now) else {
            telemetry.track(sendNowLog.record(.ignoredDebounced, surface: surface.rawValue, at: now))
            return
        }
        let outcome: LiveSendNow.Outcome
        switch conductor.endTurn() {
        case let .ended(effects):
            outcome = .submitted
            apply(effects, generation: generation)
        case .nothingToSend:
            outcome = .ignoredEmpty
        case .alreadySending:
            outcome = .ignoredInFlight
        }
        telemetry.track(sendNowLog.record(outcome, surface: surface.rawValue, at: now))
        guard outcome == .submitted else { return }
        let mine = generation
        sendNowFollowup?.cancel()
        sendNowFollowup = Task { [weak self] in
            try? await Task.sleep(for: .seconds(LiveSendNow.followWindow))
            guard !Task.isCancelled, let self, mine == self.generation else { return }
            for entry in self.sendNowLog.expire(at: Self.now) { self.telemetry.track(entry) }
        }
    }

    /// Muted, the microphone sends silence rather than nothing (`RealtimeConductor.appendAudio`).
    func toggleMute() {
        muted.toggle()
        telemetry.track(.muted(muted))
    }

    /// The Live settings or guidance changed (the settings screen saved): bring an open call up
    /// to them with the `session.update` Zimmer builds. The model, voice and reasoning effort
    /// stay as they are until the next call; OpenAI fixes those for a call's life.
    func refreshSession() async {
        guard isActive, socket != nil, let conversation = conversationID else { return }
        let mine = generation
        do {
            let session = try await api.liveSessionUpdate(conversation)
            guard mine == generation else { return }
            send(conductor.sessionUpdate(keeping: session))
        } catch {
            let message = Self.describe(error)
            log.error("live session update failed: \(message, privacy: .public)")
            guard mine == generation else { return }
            lastError = "The new Live settings did not reach this call: \(message)"
        }
    }

    /// The call moved between the phone and the car: from now on its requests name `surface`.
    /// The `session.update` Zimmer builds records the client asking for it, so asking for one
    /// both tells Zimmer and brings the open call up to instructions that say where the person
    /// is. A call still connecting is brought up to them by the start under way, once its
    /// socket is open.
    func carryOn(on surface: ClientSource.Surface) async {
        guard isActive, surface != self.surface else { return }
        self.surface = surface
        telemetry.updateClient { $0.surface = surface.rawValue }
        telemetry.track(.handedOver(to: surface.rawValue))
        await refreshSession()
    }

    /// The CarPlay scene went away: a call that is up carries on as the phone's, and the phone
    /// goes to it when it can (`LiveHandover`). A call the gear ended stays ended.
    func carLeft() {
        pressHeard = nil
        handover.carLeft(conversation: conversationID, callIsActive: isActive, at: Self.now)
        guard isActive else { return }
        telemetry.track(.carPlay("handover_armed"))
        Task { await carryOn(on: .ios) }
    }

    /// The CarPlay scene connected, so nothing is on its way to the phone's screen.
    func carCameBack() {
        handover.carCameBack()
    }

    /// The person opened something on purpose, which is worth more than a landing.
    func personChoseElsewhere() {
        handover.personChoseElsewhere()
    }

    /// What the phone should do about a call the car left on it, as things stand.
    func handoverStep(inFront: Bool, screen: LiveHandover.Screen) -> LiveHandover.Step {
        var next = handover
        let step = next.step(callConversation: conversationID, callIsActive: isActive, inFront: inFront, screen: screen, at: Self.now)
        if next != handover { handover = next }
        if case .land = step { telemetry.track(.carPlay("handover_landed")) }
        return step
    }

    // MARK: - Internals

    /// A no-op when it is on already. A server from before voice folded into Live Mode has no
    /// such route (404), and there a voice conversation needs nothing switched.
    private func turnVoiceOn(_ conversation: Int) async throws {
        do {
            _ = try await api.setLiveMode(conversation, mode: .voice)
        } catch let ZimmerError.http(status, _) where status == 404 {
            return
        }
    }

    /// The conversation may still be reading its AGENTS.md (409); give it a moment.
    private func mintSecret(_ conversation: Int) async throws -> LiveClientSecret {
        for _ in 0..<6 {
            do {
                return try await api.liveClientSecret(conversation)
            } catch let ZimmerError.http(status, message) where status == 409 && (message ?? "").localizedCaseInsensitiveContains("still reading") {
                try await Task.sleep(for: .milliseconds(1_500))
            }
        }
        throw ZimmerError.http(status: 409, message: "The conversation is taking too long to get ready.")
    }

    private func sendAudio(_ pcm: Data, microphone: Int) {
        guard microphone == microphoneGeneration, !pcm.isEmpty, !holdingMicrophone else { return }
        if !muted { sendNowLog.heard(pcm16: pcm, at: Self.now) }
        send(RealtimeConductor.appendAudio(pcm, muted: muted))
    }

    private func microphoneFailed(_ message: String, microphone: Int) {
        guard microphone == microphoneGeneration else { return }
        fail(message, generation: generation)
    }

    /// The call's watch, from the moment it starts: every 100 ms, silence in place of a
    /// microphone that stopped delivering (`MicWatchdog`), so the turn the person was in the
    /// middle of still ends; a stalled engine is asked to restart; and the call's health is
    /// checked (`LiveCallHealth`).
    private func watch(generation: Int) {
        watching?.cancel()
        watching = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, generation == self.generation, !Task.isCancelled else { return }
                // The audio thread's clock, not the main actor's: buffers still queued for this
                // actor were captured on time and are no stall.
                if let heard = self.audio.lastMicAudio, heard > (self.watchdog.lastFrame ?? 0),
                   case let .resumed(stalled, silence)? = self.watchdog.frame(at: heard) {
                    self.telemetry.track(.micResumed(stalledMs: stalled, silenceSentMs: silence))
                }
                if let looping = self.looping, Self.now - looping.since > looping.cue.ceiling {
                    self.telemetry.track(.loopTimedOut(looping.cue, after: Self.now - looping.since))
                    for action in self.cues.loopTimedOut() { self.perform(action) }
                }
                let (silence, change) = self.watchdog.tick(at: Self.now)
                if case let .stalled(after)? = change {
                    self.log.error("microphone stalled for \(after) ms; sending silence")
                    self.telemetry.track(.micStalled(afterMs: after))
                    self.audio.recoverIfStopped()
                }
                if silence > 0, !self.holdingMicrophone { self.send(RealtimeConductor.appendAudio(MicWatchdog.silence(silence))) }
                // Nothing else asks again: a restart that came back to a stopped engine, a second
                // route change, would otherwise sit out the microphone's deadline.
                if self.watchdog.stalledSince != nil { self.audio.recoverIfStopped() }
                // Someone reading the permission prompt is not a call failing to connect. The
                // phone only: in the car it cannot be answered, so the deadline stands.
                if self.surface == .ios, self.audio.awaitingPermission { self.health.started(at: Self.now) }
                #if DEBUG
                // The CarPlay drill holds its call on Connecting… on purpose, for the gear.
                if Self.drillHoldsTheCall { self.health.started(at: Self.now) }
                #endif
                // Hanging up: the call is over in a moment, wherever Live Mode has gone.
                if self.health.isConnected, !self.conductor.hangingUp, Self.now - self.lookedForMove >= Self.followEvery {
                    self.lookedForMove = Self.now
                    self.followCurrent(generation: generation)
                }
                let actions = self.health.tick(at: Self.now, stalledSince: self.watchdog.stalledSince, interrupted: self.audio.interrupted)
                for action in actions { self.act(on: action, generation: generation) }
            }
        }
    }

    #if DEBUG
    private static let drillHoldsTheCall = AppEnvironment.shared.isFixture
        && !Set(ProcessInfo.processInfo.arguments).isDisjoint(with: ["-ZimmerFixtureVoiceTurnedUp", "-ZimmerFixtureCarScript"])
    #endif

    private func act(on action: LiveCallHealth.Action, generation: Int) {
        switch action {
        case .ping:
            ping(generation: generation)
        case .microphoneLost:
            microphoneLost = true
            telemetry.track(.micLost(true))
            perform(.play(.disconnected))
        case .microphoneBack:
            microphoneLost = false
            telemetry.track(.micLost(false))
            perform(.play(.connected))
        case let .giveUp(reason):
            telemetry.track(.callGaveUp(reason, stage: health.stage, sinceStart: timeline.sinceStart(Self.now)))
            fail(reason.message, generation: generation)
        }
    }

    /// A quiet socket can be a dead one. The answer counts as hearing from OpenAI; an error means
    /// the socket has gone.
    private func ping(generation: Int) {
        guard let socket else { return }
        let asked = Self.now
        socket.sendPing { [weak self] error in
            let failure = error?.localizedDescription
            Task { @MainActor in
                guard let self, generation == self.generation else { return }
                self.telemetry.track(.socketPing(ok: failure == nil, ms: Self.now - asked))
                if let failure {
                    self.fail("The call dropped: \(failure)", generation: generation)
                } else {
                    self.health.pong(at: Self.now)
                }
            }
        }
    }

    /// Every state change: logged, and the cues follow it.
    private func stateChanged(from previous: LiveVoiceState) {
        telemetry.track(.stateChanged(from: previous, to: state, muted: muted))
        if state == .idle, handover.route != nil { handover.callEnded() }
        for action in cues.transition(to: state) { perform(action) }
    }

    private func perform(_ action: LiveCueDirector.Action) {
        switch action {
        case let .play(cue, delay):
            if audio.play(cue, after: delay) { telemetry.track(.cue(cue)) }
        case let .startLoop(cue):
            looping = (cue, Self.now)
            audio.startLoop(cue)
            telemetry.track(.loopCue(cue, on: true))
        case .stopLoop:
            audio.stopLoop()
            loopStopped()
        case .stopCues:
            audio.stopCues()
            loopStopped()
        }
    }

    private func loopStopped() {
        if let looping { telemetry.track(.loopCue(looping.cue, on: false)) }
        looping = nil
    }

    private func send(_ event: JSONValue) {
        let mine = generation
        socket?.send(.string(event.encoded())) { [weak self] error in
            guard let error else { return }
            let failure = error.localizedDescription
            Task { @MainActor in
                guard let self, mine == self.generation else { return }
                self.log.error("realtime send failed: \(failure, privacy: .public)")
                self.telemetry.track(.socketSendFailed(failure))
                if self.warmFailedBeforeUp(failure) { return }
                self.fail("The call dropped: \(failure)", generation: mine)
            }
        }
    }

    private func receive(_ task: URLSessionWebSocketTask, generation: Int) {
        task.receive { [weak self] result in
            let text: String? = switch result {
            case let .success(.string(string)): string
            case let .success(.data(data)): String(data: data, encoding: .utf8)
            default: nil
            }
            let failure: String? = if case let .failure(error) = result { error.localizedDescription } else { nil }
            Task { @MainActor in
                guard let self, generation == self.generation else { return }
                self.received(text: text, failure: failure, generation: generation)
                if failure == nil { self.receive(task, generation: generation) }
            }
        }
    }

    /// One thing the socket said: an event's text, or the failure that closed it. From this
    /// call's own socket, or from a warm connection it took over (`LiveWarmLink.handOver`).
    private func received(text: String?, failure: String?, generation: Int) {
        guard generation == self.generation else { return }
        if let failure {
            telemetry.track(.socketClosed(failure))
            if warmFailedBeforeUp(failure) { return }
            fail("The call dropped: \(failure)", generation: generation)
            return
        }
        guard let text, let event = JSONValue.parse(text) else { return }
        if holdingMicrophone, event["type"]?.string == "session.updated" { warmUpdated = true }
        health.heard(at: Self.now)
        for entry in timeline.observe(event, at: Self.now) { telemetry.track(entry) }
        for entry in sendNowLog.observe(event, at: Self.now) { telemetry.track(entry) }
        let was = conductor.listening
        let effects = conductor.handle(event)
        if conductor.listening != was {
            telemetry.track(.listeningChanged(from: was, to: conductor.listening))
        }
        apply(effects, generation: generation)
        if event["type"]?.string == "session.created" {
            sessionOpen = true
            connectIfReady(generation: generation)
        }
    }

    private func apply(_ effects: [RealtimeConductor.Effect], generation: Int) {
        for effect in effects {
            switch effect {
            case let .send(event):
                send(event)
            case let .relay(callID, name, arguments):
                relay(callID: callID, name: name, arguments: arguments, generation: generation)
            case let .record(role, text):
                guard let conversation = conversationID else { continue }
                Task {
                    _ = try? await api.recordLiveTurn(conversation, role: role, content: text, gated: false)
                    activity += 1
                }
            case let .hear(itemID, text):
                hear(itemID: itemID, text: text, generation: generation)
            case let .reattach(conversation):
                Task { await reattach(to: conversation) }
            case .hangUp:
                hangUpWhenSaid(generation: generation)
            case let .play(pcm):
                audio.play(pcm)
                if let from = firstAudioFrom {
                    firstAudioFrom = nil
                    telemetry.track(.firstAudio(sinceTap: Self.now - from, path: startPath))
                }
            case let .replyStarted(itemID):
                audio.replyStarted(itemID: itemID)
            case let .interrupt(arriving):
                for cut in audio.stopPlayback(arriving: arriving) {
                    send(RealtimeConductor.truncate(itemID: cut.itemID, audioEndMs: cut.heardMs))
                    telemetry.track(.replyInterrupted(cut))
                }
            case let .state(next):
                // Connecting ends in one place, `connectIfReady`.
                guard health.isConnected else { continue }
                // A reply coming through means the call recovered from whatever went wrong.
                if next == .speaking { lastError = nil }
                state = next
            case let .failure(message):
                log.error("realtime error: \(message, privacy: .public)")
                lastError = message
            case let .signal(signal):
                for action in cues.receive(signal) { perform(action) }
            }
        }
    }

    /// Gated: Zimmer decides whether the call answers this line. Unreachable, it is answered — a
    /// stray reply beats a call gone quiet.
    private func hear(itemID: String?, text: String, generation: Int) {
        guard let conversation = conversationID else { return }
        let asked = Self.now
        Task {
            let heard = try? await api.recordLiveTurn(conversation, role: .user, content: text, gated: true)
            guard generation == self.generation else { return }
            telemetry.track(.lineHeard(respond: heard?.respond ?? true, dropped: heard?.dropped == true, ms: Self.now - asked,
                                       listening: heard?.listening ?? conductor.listening))
            if heard?.dropped != true { activity += 1 }
            apply(conductor.heard(itemID: itemID, respond: heard?.respond ?? true), generation: generation)
        }
    }

    private func relay(callID: String, name: String, arguments: String, generation: Int) {
        guard let conversation = conversationID else { return }
        let asked = Self.now
        Task {
            var result: LiveToolResult?
            var failure: String?
            do {
                result = try await api.relayLiveToolCall(conversation, name: name, arguments: arguments, callID: callID)
            } catch {
                failure = Self.describe(error)
            }
            guard generation == self.generation else { return }
            telemetry.track(.toolCall(name, ms: Self.now - asked, ok: failure == nil && result?.error != true))
            activity += 1
            let effects = conductor.relayed(callID: callID, result: result, failure: failure)
            if result?.hangUp == true, conductor.hangingUp { armHangUpDeadline(generation: generation) }
            apply(effects, generation: generation)
        }
    }

    private func fail(_ message: String, generation: Int) {
        guard generation == self.generation else { return }
        log.error("live call ended: \(message, privacy: .public)")
        telemetry.track(.callFailed(message, state: state))
        end(reason: "failed", farewell: cues.dropped())
        lastError = message
        // The car retries first, and says so itself (`CarPlayLive`). The phone has only this.
        if surface == .ios { soundUnavailable() }
    }

    private static func describe(_ error: Error) -> String {
        if let zimmer = error as? ZimmerError { return zimmer.userMessage }
        if let audio = error as? LiveAudioEngine.Failure { return audio.description }
        return error.localizedDescription
    }
}
