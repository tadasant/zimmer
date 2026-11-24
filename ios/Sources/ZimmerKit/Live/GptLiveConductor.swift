import Foundation

/// What a call on the `gpt_live_claude` engine does with every GPT-Live event — the same rules as
/// the web dock's `GptLiveCall` (app/javascript/lib/gpt_live_call.js), kept here so they are
/// tested on Linux. The app (`GptLiveLink`, `LiveCall`) carries the WebRTC connection and performs
/// the effects; nothing here touches the network, the audio or a clock: the time is handed in.
///
/// GPT-Live has no tools. When the person asks for something that needs Zimmer (or real thought),
/// it emits `session.delegation.created`; the app posts the delegation to Zimmer, where Claude
/// runs Zimmer's tools and answers, and appends each chunk of the answer as
/// `session.commentary.append` for GPT-Live to say.
///
///   transcripts  `session.input_transcript.delta` / `output_transcript.delta` arrive as fragments
///                with no turn boundary; a run of one speaker's fragments is one turn, recorded
///                when the other side starts (or the call ends)
///   delegation   `session.delegation.created` → `.delegate` → `delegated(…)`: each chunk as
///                commentary, a cap warning once as quiet `session.thinking.append`, and
///                `end_call` hangs up once the goodbye has been said
///   hang-up      GPT-Live can say goodbye without delegating, and a goodbye ends nothing. So when
///                the person's line asked to hang up, GPT-Live answered it itself (no delegation)
///                and that answer is a goodbye, the call ends once it has been said
///                (`endsTheCall`), as if the backend had asked. A delegated line is the backend's
///                to end, with `end_call`
///   cues         the same `LiveCueDirector.Signal`s a Realtime call gives (`.signal`), read off
///                GPT-Live's events, which have no speech boundaries: the person's transcript
///                starting is *talking*, its going quiet for `heardIdle` with no answer begun is
///                *heard* (and thinking), each delegation in flight is a running tool (the
///                *working* loop, through any filler GPT-Live says over it), and a delegation
///                Zimmer could not answer is a failure
///   cost         the session's billed seconds every `sessionReportEvery` and at the end, each
///                turn's time to first audio, and the call's length → `.report` for the ledger
///   standby      a session held ready ahead of a tap (`LiveWarmStart`): nothing is sent and nothing
///                is read but that it started, its seconds go on the ledger at the standby rate, and
///                `claim` makes it a call from then on. A session that woke, or said anything,
///                before the tap is not one to keep: `.woke`
///   end          `session.close`, then `session.closed` (its usage) or `closeGrace`, whichever
///                is first
public struct GptLiveConductor: Sendable {
    public static let engine = LiveVoiceEngine.gptLive
    /// The longest a hang-up waits for the goodbye to start and finish.
    public static let goodbyeGrace: TimeInterval = 8
    /// The longest an ending call waits for `session.closed`.
    public static let closeGrace: TimeInterval = 3
    /// Output fragments this far apart are one finished answer.
    public static let spokenIdle: TimeInterval = 1.2
    /// The person's transcript quiet this long, with no answer begun: their line was heard.
    public static let heardIdle: TimeInterval = 0.6
    /// Thinking (after *heard*, or after Claude answered) with nothing said this long: GPT-Live
    /// is not answering, so the call goes back to listening, quietly.
    public static let answerGrace: TimeInterval = 8
    /// A long call's seconds are reported as it goes, so an app that dies takes at most this much
    /// unreported time with it.
    public static let sessionReportEvery: TimeInterval = 60

    public enum Effect: Sendable, Equatable {
        /// A client event for the data channel.
        case send(JSONValue)
        /// A finished line for the thread.
        case record(LiveTurn.Role, String)
        /// Ask Zimmer to answer this delegation; hand its answer to `delegated(id:answer:failure:)`.
        case delegate(id: String, pendingUserText: String)
        case state(LiveVoiceState)
        /// `session.started`: the call is up.
        case started
        /// In standby, inference began before anybody tapped: the session is not standing by.
        case woke
        /// GPT-Live's answer has begun to sound: the call's first audio, for the log.
        case firstAudio
        /// A row for the voice-engine ledger.
        case report(LiveUsageEvent)
        /// Time to end the call: the goodbye was said, or its grace ran out.
        case hangUp
        /// `session.closed` came, or its grace ran out: let go of the connection.
        case closed
        /// An error GPT-Live reported; the call carries on.
        case failure(String)
        /// What the call's cues need beyond its state, as `RealtimeConductor.Effect.signal`.
        case signal(LiveCueDirector.Signal)
    }

    public private(set) var sessionID: String?
    /// Ending: `session.close` has gone, and the call is waiting for `session.closed`.
    public private(set) var closing = false
    public private(set) var ended = false
    /// The backend said the call is ending (`end_call`): the next answer to stop sounding ends it.
    public var hangingUp: Bool { goodbyePending || saidGoodbye }

    /// Held ready, and nobody's call yet.
    public private(set) var inStandby: Bool
    /// `session.started`'s `expires_at`, in Unix seconds: when OpenAI ends the session.
    public private(set) var expiresAt: TimeInterval?
    public private(set) var hasStarted = false

    private let callKey: String
    /// It was held before it was a call, so `session.closed`'s seconds cover more than the call.
    private var wasHeld: Bool
    private var heldSince: TimeInterval?
    /// When this last ran while held. A gap is the app suspended, with no ICE consent going, so OpenAI
    /// has let the session go and is billing nothing.
    private var heldSeen: TimeInterval?
    private var seq = 0
    private var eventSeq = 0
    private var userText = ""
    /// The person's last finished line: what GPT-Live's next answer is answering.
    private var lastUserLine = ""
    /// GPT-Live delegated `lastUserLine`: ending the call for it is the backend's (`end_call`).
    private var lineDelegated = false
    private var assistantText = ""
    private var userSpokeAt: TimeInterval?
    private var awaitingAnswer = false
    /// The person's transcript is arriving: they are talking.
    private var personTalking = false
    /// When the person's line counts as heard, if no answer starts first.
    private var heardDeadline: TimeInterval?
    /// Delegations posted to Zimmer and not yet answered: the call's running tools.
    private var delegations: Set<String> = []
    /// When thinking with nothing said gives up and goes back to listening.
    private var thinkingDeadline: TimeInterval?
    private var delegatedThisTurn = false
    private var heardAnswer = false
    private var lastOutput: TimeInterval?
    private var goodbyePending = false
    private var saidGoodbye = false
    private var goodbyeDeadline: TimeInterval?
    private var closeDeadline: TimeInterval?
    private var warned = false
    private var startedAt: TimeInterval?
    private var callMark: TimeInterval?
    private var endedAt: TimeInterval?
    private var nextSessionReport: TimeInterval?
    private var reportedSeconds: Double = 0
    private var sessionReported = false
    private var closedUsage: JSONValue?

    /// `callKey`: unique to the call; every ledger row's key starts with it.
    public init(callKey: String = GptLiveConductor.newCallKey(), standby: Bool = false) {
        self.callKey = callKey
        inStandby = standby
        wasHeld = standby
    }

    public static func newCallKey() -> String {
        "ios" + String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12)).lowercased()
    }

    /// Zimmer started the session: OpenAI's id for it, for the ledger.
    public mutating func sessionStarted(id: String?) {
        sessionID = id
    }

    /// The person tapped: from now on this is a call. Its seconds in standby go on the ledger; the
    /// call's own start here, at the active rate from the first, whatever moment OpenAI wakes it.
    public mutating func claim(at now: TimeInterval) -> [Effect] {
        guard inStandby, !ended, !closing else { return [] }
        let effects = reportHeld(at: now, partial: false)
        inStandby = false
        if hasStarted { callBegan(at: now) }
        return effects
    }

    private mutating func callBegan(at now: TimeInterval) {
        startedAt = now
        callMark = now
        nextSessionReport = now + Self.sessionReportEvery
    }

    /// What a session in standby says. Nothing is asked of it, so nothing is recorded or answered.
    private mutating func handleInStandby(_ event: JSONValue, at now: TimeInterval) -> [Effect] {
        switch event["type"]?.string {
        case "session.started":
            started(event)
            heldSince = now
            heldSeen = now
            nextSessionReport = now + Self.sessionReportEvery
            return [.started]
        case "session.resumed", "session.input_transcript.delta", "session.output_transcript.delta", "session.delegation.created":
            return [.woke]
        case "session.closed":
            return finish(at: now)
        case "error":
            return [.failure(event["error"]?["message"]?.string ?? "GPT-Live reported an error.")]
        default:
            return []
        }
    }

    private mutating func started(_ event: JSONValue) {
        hasStarted = true
        if sessionID == nil { sessionID = event["session"]?["id"]?.string }
        if case let .number(at)? = event["session"]?["expires_at"] { expiresAt = at }
    }

    /// One server event from the data channel.
    public mutating func handle(_ event: JSONValue, at now: TimeInterval) -> [Effect] {
        guard !ended else { return [] }
        if inStandby { return handleInStandby(event, at: now) }
        switch event["type"]?.string {
        case "session.started":
            started(event)
            callBegan(at: now)
            return [.started, .state(.listening)]
        case "session.input_transcript.delta":
            var effects = flushAssistant()
            userText += event["delta"]?.string ?? ""
            userSpokeAt = now
            awaitingAnswer = true
            thinkingDeadline = nil
            heardDeadline = now + Self.heardIdle
            if !personTalking {
                personTalking = true
                effects.append(.signal(.personTalking))
            }
            effects.append(.state(.listening))
            return effects
        case "session.output_transcript.delta":
            var effects = flushUser()
            if awaitingAnswer, let spoke = userSpokeAt {
                seq += 1
                effects.append(.report(LiveUsageEvent(engine: Self.engine, operation: "turn_latency", key: key(),
                                                      firstAudioMs: max(0, Int(((now - spoke) * 1_000).rounded())),
                                                      details: ["delegated": .bool(delegatedThisTurn)])))
            }
            if !heardAnswer {
                heardAnswer = true
                effects.append(.firstAudio)
            }
            awaitingAnswer = false
            delegatedThisTurn = false
            // The goodbye has started: once it stops, the call ends.
            if goodbyePending {
                goodbyePending = false
                saidGoodbye = true
            }
            assistantText += event["delta"]?.string ?? ""
            lastOutput = now
            thinkingDeadline = nil
            effects.append(.state(.speaking))
            // The answer has begun: the person's line needs no *heard*.
            effects += personDone()
            return effects
        case "session.delegation.created":
            guard event["delegation"]?["target"]?.string == "client", let id = event["delegation"]?["id"]?.string else { return [] }
            let pending = userText
            var effects = flushUser() + personDone()
            lineDelegated = true
            delegatedThisTurn = true
            thinkingDeadline = nil
            delegations.insert(id)
            effects.append(.delegate(id: id, pendingUserText: pending))
            // Running first, so the call goes straight to the working loop, not through thinking.
            effects.append(.signal(.toolsRunning(delegations.count)))
            effects.append(.state(.working))
            return effects
        case "session.closed":
            closedUsage = event["usage"]
            return finish(at: now)
        case "error":
            // As on Realtime: with nothing running or sounding, no answer is coming, so back to
            // listening. A stray error while Claude works or GPT-Live talks means nothing yet.
            let idle = delegations.isEmpty && lastOutput == nil
            if idle { thinkingDeadline = nil }
            return [.failure(event["error"]?["message"]?.string ?? "GPT-Live reported an error.")]
                + (idle ? [.signal(.noAnswerComing), .state(.listening)] : [])
        default:
            return []
        }
    }

    /// Zimmer answered a delegation (`answer`), or could not be reached (`failure`).
    public mutating func delegated(id: String, answer: LiveDelegation?, failure: String?, at now: TimeInterval) -> [Effect] {
        guard !ended else { return [] }
        let wasRunning = delegations.remove(id) != nil
        var effects: [Effect] = wasRunning ? [.signal(.toolsRunning(delegations.count))] : []
        // The last delegation is back and GPT-Live is quiet: thinking until it says what came back
        // (the answer, or that it failed), or `answerGrace` passes. Nothing to say: listening.
        let saying = answer.map { !$0.chunks.allSatisfy(\.isEmpty) } ?? true
        if wasRunning, delegations.isEmpty, lastOutput == nil {
            if saying {
                thinkingDeadline = now + Self.answerGrace
                effects.append(.state(.thinking))
            } else {
                effects.append(.state(.listening))
            }
        }
        guard let answer else {
            if wasRunning { effects.append(.signal(.actionFailed)) }
            return effects + [commentary(id, failure.map { "I couldn't do that: \($0)." } ?? "I couldn't reach Zimmer just now. Try again in a moment.")]
        }
        if let warning = answer.warning, !warning.isEmpty, !warned {
            warned = true
            effects.append(.send(.object(["type": .string("session.thinking.append"), "event_id": .string(eventID()),
                                          "delegation_id": .null, "content": .string("Budget note from Zimmer: \(warning)")])))
        }
        effects += answer.chunks.filter { !$0.isEmpty }.map { commentary(id, $0) }
        if answer.endCall {
            goodbyePending = true
            goodbyeDeadline = now + Self.goodbyeGrace
        }
        return effects
    }

    /// Every 100 ms or so: a finished answer, a goodbye said, a grace run out, a minute of session.
    public mutating func tick(at now: TimeInterval) -> [Effect] {
        guard !ended else { return [] }
        var effects: [Effect] = []
        if inStandby, !closing {
            if let heldSeen, now - heldSeen > Self.longestHeldGap { effects += reportHeld(at: now, partial: true) }
            heldSeen = now
        }
        if let closeDeadline, now >= closeDeadline { return finish(at: now) }
        if closing { return [] }
        if let heardDeadline, now >= heardDeadline {
            self.heardDeadline = nil
            let answered = !awaitingAnswer
            effects += personDone()
            if !answered {
                thinkingDeadline = now + Self.answerGrace
                effects += [.state(.thinking), .signal(.heardPerson)]
            }
        }
        if let thinkingDeadline, now >= thinkingDeadline {
            self.thinkingDeadline = nil
            if delegations.isEmpty { effects.append(.state(.listening)) }
        }
        if let lastOutput, now - lastOutput >= Self.spokenIdle {
            self.lastOutput = nil
            let said = assistantText
            effects += flushAssistant()
            // Only the first answer to a line GPT-Live did not delegate is checked: the line is
            // spent once answered.
            let asked = lineDelegated ? "" : lastUserLine
            lastUserLine = ""
            if saidGoodbye || (delegations.isEmpty && Self.endsTheCall(asked: asked, said: said)) {
                goodbyeDeadline = nil
                return effects + [.hangUp]
            }
            effects.append(.state(.listening))
        }
        if let goodbyeDeadline, now >= goodbyeDeadline {
            self.goodbyeDeadline = nil
            effects.append(.hangUp)
        }
        if let next = nextSessionReport, now >= next {
            nextSessionReport = now + Self.sessionReportEvery
            effects += reportHeld(at: now, partial: true)
            effects += reportCall(at: now, partial: true)
            effects += reportSession(at: now, partial: true)
        }
        return effects
    }

    /// The call is ending: close the session and wait, at most `closeGrace`, for `session.closed`.
    /// The call's length stops here; the wait is not part of it.
    public mutating func close(at now: TimeInterval) -> [Effect] {
        guard !ended, !closing else { return [] }
        closing = true
        endedAt = now
        closeDeadline = now + Self.closeGrace
        return [.send(.object(["type": .string("session.close"), "event_id": .string(eventID())]))]
    }

    /// The connection is gone, or `session.closed` came: what was said and what it cost, then done.
    public mutating func finish(at now: TimeInterval) -> [Effect] {
        guard !ended else { return [] }
        if endedAt == nil { endedAt = now }
        var effects = flushUser() + flushAssistant()
        effects += reportHeld(at: now, partial: false)
        effects += reportCall(at: now, partial: false)
        effects += reportSession(at: now, partial: false)
        ended = true
        effects.append(.closed)
        return effects
    }

    // MARK: - Internals

    /// The person's run of transcript is over: they stopped talking.
    private mutating func personDone() -> [Effect] {
        heardDeadline = nil
        guard personTalking else { return [] }
        personTalking = false
        return [.signal(.personStopped)]
    }

    private mutating func commentary(_ id: String, _ content: String) -> Effect {
        .send(.object(["type": .string("session.commentary.append"), "event_id": .string(eventID()),
                       "delegation_id": .string(id), "content": .string(content)]))
    }

    private mutating func flushUser() -> [Effect] {
        let text = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        userText = ""
        guard !text.isEmpty else { return [] }
        lastUserLine = text
        lineDelegated = false
        return [.record(.user, text)]
    }

    /// The person's line asked to hang up and the answer to it said goodbye: the call is over,
    /// whether or not GPT-Live delegated the hang-up. Kept in step with `endsTheCall` in the web
    /// dock's app/javascript/lib/gpt_live_call.js.
    public static func endsTheCall(asked: String, said: String) -> Bool {
        func plain(_ text: String) -> String {
            text.lowercased().replacingOccurrences(of: "\u{2019}", with: "'").replacingOccurrences(of: "\u{2018}", with: "'")
        }
        func matches(_ text: String, _ pattern: String) -> Bool {
            text.range(of: pattern, options: .regularExpression) != nil
        }
        let line = plain(asked)
        return matches(line, #"\b(hang (it )?up|end (the|this) call|stop listening|pause|good ?bye|bye)\b"#)
            && !matches(line, #"\b(don'?t|do not|not yet|never|how)\b"#)
            && matches(plain(said), #"\b(hanging up|ending (the|this) call|good ?bye|bye)\b"#)
    }

    private mutating func flushAssistant() -> [Effect] {
        let text = assistantText.trimmingCharacters(in: .whitespacesAndNewlines)
        assistantText = ""
        return text.isEmpty ? [] : [.record(.assistant, text)]
    }

    /// The call's length since the last report, to when the person hung up.
    private mutating func reportCall(at now: TimeInterval, partial: Bool) -> [Effect] {
        guard let mark = callMark else { return [] }
        let to = partial ? now : (endedAt ?? now)
        callMark = partial ? to : nil
        seq += 1
        return [.report(LiveUsageEvent(engine: Self.engine, operation: "call", key: key(), seconds: Self.round(to - mark),
                                       details: ["partial": .bool(partial)]))]
    }

    /// The seconds a session was held in standby since the last report, at OpenAI's standby rate.
    private mutating func reportHeld(at now: TimeInterval, partial: Bool) -> [Effect] {
        guard inStandby, let since = heldSince else { return [] }
        var to = partial ? now : (endedAt ?? now)
        var over = !partial
        // Asleep since: held only as far as this last ran, and no further.
        if let heldSeen, to - heldSeen > Self.longestHeldGap {
            to = heldSeen
            over = true
        }
        heldSince = over ? nil : to
        guard to > since else { return [] }
        seq += 1
        return [.report(LiveUsageEvent(engine: Self.engine, operation: "voice_standby", key: key(), seconds: Self.round(to - since),
                                       details: ["session_id": .string(sessionID ?? ""), "partial": .bool(partial)]))]
    }

    /// GPT-Live bills the session's seconds: reported every minute and the rest at the end. The
    /// total is `session.closed`'s final usage when it came, else the seconds this call saw; on a
    /// session held in standby first, the seconds this call saw, because the usage covers both.
    private mutating func reportSession(at now: TimeInterval, partial: Bool) -> [Effect] {
        guard !sessionReported, let startedAt else { return [] }
        var total = now - startedAt
        var fromUsage = false
        if !partial {
            sessionReported = true
            if !wasHeld, let reported = Self.billedSeconds(closedUsage) {
                total = reported
                fromUsage = true
            }
        }
        let seconds = max(total - reportedSeconds, 0)
        reportedSeconds += seconds
        guard seconds > 0 else { return [] }
        seq += 1
        return [.report(LiveUsageEvent(engine: Self.engine, operation: "voice_session", key: key(), seconds: Self.round(seconds),
                                       details: ["session_id": .string(sessionID ?? ""), "from_usage": .bool(fromUsage),
                                                 "partial": .bool(partial)]))]
    }

    /// `session.closed`'s usage: `seconds` as GPT-Live reports it, or the spellings the web dock
    /// also accepts.
    static func billedSeconds(_ usage: JSONValue?) -> Double? {
        guard let usage else { return nil }
        for key in ["seconds", "duration_seconds", "session_seconds"] {
            if case let .number(value)? = usage[key] { return value }
        }
        if case let .number(ms)? = usage["duration_ms"] { return ms / 1_000 }
        return nil
    }

    /// A gap longer than this while held is the app suspended, not a late tick.
    static let longestHeldGap: TimeInterval = 5

    private static func round(_ seconds: Double) -> Double { (seconds * 1_000).rounded() / 1_000 }

    private func key() -> String { "\(callKey).\(seq)" }

    private mutating func eventID() -> String {
        eventSeq += 1
        return "zimmer_ios_\(eventSeq)"
    }
}
