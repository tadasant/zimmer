import Foundation
import ZimmerKit
import os

/// One call on the `gpt_live_claude` engine: GPT-Live as the voice over WebRTC (`GptLiveLink`),
/// Claude behind it through Zimmer. `LiveCall` owns the call — its state, cues, health and
/// screens — and hands this the part that differs from Realtime, as the web dock hands it to
/// `GptLiveCall` (app/javascript/lib/gpt_live_call.js).
///
///   start        WebRTC offer → `startGptLiveSession` → Zimmer starts the session with OpenAI
///                and returns its answer
///   events       each one to `GptLiveConductor`, and its effects performed: commentary and
///                closes to the data channel, finished lines to the thread, delegations to Zimmer
///                (Claude), ledger rows batched to `reportLiveUsage`
///   standby      held ready ahead of a tap by `LiveWarmKeeper`: started with inference paused,
///                muted, recording and asking nothing. `adopt` makes it `LiveCall`'s from the tap, and
///                `open` lets the microphone through. What it would write waits for Zimmer to have
///                the conversation (`settled`)
///   end          `session.close`, then `session.closed` (its usage) or the grace: the last lines,
///                the last rows, and the connection let go. `LiveCall` hears nothing more from a
///                call it ended, which keeps itself alive until that is done.
@MainActor
final class GptLiveCall {
    enum Signal {
        /// `session.started`: the call is up, or the session is standing by.
        case started
        /// In standby, the session woke before anybody tapped.
        case woke
        /// GPT-Live said something: the connection is alive.
        case heard
        case state(LiveVoiceState)
        case firstAudio
        /// A line was written to the thread.
        case recorded
        /// Claude answered a delegation, or did not.
        case delegated(ms: TimeInterval, ok: Bool)
        /// The backend ended the call and the goodbye has been said.
        case hangUp
        /// An error GPT-Live reported; the call carries on.
        case failure(String)
        /// The connection went.
        case dropped(String)
        /// What the cues need beyond the state: the person talking or heard, delegations running,
        /// a failure (`LiveCueDirector.receive`).
        case cue(LiveCueDirector.Signal)
        /// A run of the person's transcript ended: whether it streamed while they spoke, which the
        /// *heard* cue depends on (`GptLiveInputTiming`).
        case inputTiming(GptLiveInputTiming.Run)
    }

    /// Ledger rows wait this long to go in one request, at most `maxBatch` at a time.
    private static let flushAfter: TimeInterval = 5
    private static let maxBatch = 50
    private static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
    private static let log = Logger(subsystem: "com.tadasant.zimmer", category: "gpt-live")

    /// The client driving the call: every request names it, as the Realtime path's do.
    var surface: ClientSource.Surface
    let conversation: Int
    /// Started as a session held ready. A tap can take it before its start has gone to Zimmer, and it
    /// is still the one that was going to be started.
    private let startsInStandby: Bool
    private let link: GptLiveLink
    private var conductor: GptLiveConductor
    private var inputTiming = GptLiveInputTiming()
    /// Nil once `LiveCall` let go of this call: nothing more reaches it.
    private var signal: ((Signal) -> Void)?
    private let turns: LiveTurnQueue
    /// The conversation as Zimmer has it, for a call taken from standby: what it writes waits for
    /// this. Nil once settled when Zimmer has no conversation for it, and it writes nothing.
    private var settled: Task<Int?, Never>?
    private var usage: [LiveUsageEvent] = []
    private var flushing: Task<Void, Never>?
    private var ticking: Task<Void, Never>?
    private var ending = false
    /// Held from `end()` until the session has closed, after `LiveCall` has let go of it.
    private var keepAlive: GptLiveCall?

    private var api: any LiveAPI { AppEnvironment.shared.connection.api.live(from: surface) }

    init(conversation: Int, surface: ClientSource.Surface, muted: Bool, standby: Bool = false, signal: @escaping (Signal) -> Void) throws {
        self.conversation = conversation
        self.surface = surface
        self.signal = signal
        startsInStandby = standby
        conductor = GptLiveConductor(standby: standby)
        // A line waits for the one before it, and the first of a call from standby waits for Zimmer
        // to answer the tap.
        turns = standby ? LiveTurnQueue(patience: .seconds(15)) : LiveTurnQueue()
        link = try GptLiveLink(muted: muted || standby)
        link.onEvent = { [weak self] text in self?.received(text) }
        link.onDropped = { [weak self] reason in self?.dropped(reason) }
    }

    /// Offer, have Zimmer start the session, take OpenAI's answer. The call is up when GPT-Live
    /// says `session.started` (`Signal.started`).
    func start() async throws {
        let offer = try await link.offer()
        // Hung up while the offer was made: no session for Zimmer to start.
        guard !ending else { return }
        let answer = try await api.startGptLiveSession(conversation, sdp: offer, standby: startsInStandby)
        conductor.sessionStarted(id: answer.sessionID)
        // Hung up while Zimmer was starting it: never connect a session nobody wants.
        guard !ending else {
            link.close()
            return
        }
        try await link.accept(answer: answer.sdp)
        tick()
    }

    var isConnected: Bool { link.isConnected }

    // MARK: - Standby

    /// Up this moment, and GPT-Live has said so.
    var isStandingBy: Bool { conductor.hasStarted && link.isUp }

    /// While it is held: what it says, to the one holding it.
    func onStandby(_ signal: @escaping (Signal) -> Void) {
        self.signal = signal
    }

    /// `start` threw: reported like any other end of the connection, to whoever has the call by now.
    func failedToStart(_ reason: String) {
        dropped(reason)
    }

    /// `session.started` has come.
    var hasStarted: Bool { conductor.hasStarted }

    /// How long OpenAI gave the session from now, when it has said.
    var lifeLeft: TimeInterval? { conductor.expiresAt.map { $0 - Date().timeIntervalSince1970 } }

    /// The person tapped: this is `LiveCall`'s call from here. Still muted, until `open`.
    func adopt(surface: ClientSource.Surface, settled: Task<Int?, Never>, signal: @escaping (Signal) -> Void) {
        self.surface = surface
        self.settled = settled
        self.signal = signal
        perform(conductor.claim(at: Self.now))
    }

    /// The call's microphone is open: let it through.
    func open(muted: Bool) {
        link.setMuted(muted)
    }

    /// The keeper lets go before the call takes over: nothing more is reported to it.
    func detach() {
        signal = nil
    }

    /// The conversation to write to: Zimmer's answer to the tap, for a call taken from standby.
    /// Captured rather than asked of `self`, which may be gone by the time the last line goes.
    private var destination: @Sendable () async -> Int? {
        let settled = self.settled
        let conversation = self.conversation
        return {
            guard let settled else { return conversation }
            return await settled.value
        }
    }

    // MARK: - The call

    /// The backend ended the call and its goodbye is being said: the call is over in a moment.
    var hangingUp: Bool { conductor.hangingUp }

    func setMuted(_ muted: Bool) {
        link.setMuted(muted)
    }

    /// `LiveCall` is done with this call: close the session, wait for its final usage, then let go.
    func end() {
        guard !ending else { return }
        ending = true
        // Already over (the connection dropped): nothing to close, and nothing left to wait for.
        guard !conductor.ended else {
            signal = nil
            link.close()
            return
        }
        keepAlive = self
        // The session can take seconds to close, and the next call's microphone feeds every
        // connection there is: this one hears no more of it.
        link.setMuted(true)
        if let run = inputTiming.finish() { signal?(.inputTiming(run)) }
        signal = nil
        perform(conductor.close(at: Self.now))
        // Started, or still starting: the tick ends it after `closeGrace` if nothing answers.
        tick()
    }

    // MARK: - Internals

    private func tick() {
        guard ticking == nil else { return }
        ticking = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, !Task.isCancelled else { return }
                self.perform(self.conductor.tick(at: Self.now))
                if self.conductor.ended { return }
            }
        }
    }

    private func received(_ text: String) {
        guard let event = JSONValue.parse(text) else { return }
        signal?(.heard)
        if let run = inputTiming.observe(event, at: Self.now) { signal?(.inputTiming(run)) }
        perform(conductor.handle(event, at: Self.now))
    }

    private func dropped(_ reason: String) {
        let signal = self.signal
        if let run = inputTiming.finish() { signal?(.inputTiming(run)) }
        perform(conductor.finish(at: Self.now))
        signal?(.dropped(reason))
    }

    private func perform(_ effects: [GptLiveConductor.Effect]) {
        for effect in effects {
            switch effect {
            case let .send(event):
                if !link.send(event.encoded()) { Self.log.error("gpt-live event not sent: the channel is not open") }
            case let .record(role, text):
                let api = self.api
                let destination = self.destination
                turns.add { [weak self] in
                    guard let conversation = await destination() else { return }
                    _ = try? await api.recordLiveTurn(conversation, role: role, content: text, gated: false)
                    self?.signal?(.recorded)
                }
            case let .delegate(id, pending):
                delegate(id: id, pending: pending)
            case let .state(next):
                signal?(.state(next))
            case .started:
                signal?(.started)
            case .woke:
                signal?(.woke)
            case .firstAudio:
                signal?(.firstAudio)
            case let .report(event):
                usage.append(event)
                scheduleFlush()
            case .hangUp:
                signal?(.hangUp)
            case .closed:
                finished()
            case let .failure(message):
                Self.log.error("gpt-live error: \(message, privacy: .public)")
                signal?(.failure(message))
            case let .signal(cue):
                signal?(.cue(cue))
            }
        }
    }

    private func delegate(id: String, pending: String) {
        let api = self.api
        let asked = Self.now
        let destination = self.destination
        Task { [weak self] in
            var answer: LiveDelegation?
            var failure: String?
            do {
                guard let conversation = await destination() else { throw CancellationError() }
                answer = try await api.answerLiveDelegation(conversation, delegationID: id, pendingUserText: pending)
            } catch let error as ZimmerError {
                failure = error.userMessage
            } catch {
                failure = nil
            }
            guard let self else { return }
            self.signal?(.delegated(ms: Self.now - asked, ok: answer != nil))
            self.perform(self.conductor.delegated(id: id, answer: answer, failure: failure, at: Self.now))
        }
    }

    private func scheduleFlush() {
        if usage.count >= Self.maxBatch { return flush() }
        guard flushing == nil else { return }
        flushing = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.flushAfter))
            guard let self else { return }
            self.flushing = nil
            self.flush()
        }
    }

    private func flush() {
        flushing?.cancel()
        flushing = nil
        let api = self.api
        let held = conversation
        let destination = self.destination
        while !usage.isEmpty {
            let batch = Array(usage.prefix(Self.maxBatch))
            usage.removeFirst(batch.count)
            Task {
                do {
                    let conversation = await destination() ?? held
                    try await api.reportLiveUsage(conversation, events: batch)
                } catch {
                    Self.log.error("gpt-live usage not reported: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    private func finished() {
        flush()
        ticking?.cancel()
        ticking = nil
        link.close()
        keepAlive = nil
    }
}
