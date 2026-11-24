import Foundation

/// Standby: a connection kept ready ahead of a tap, so the tap that starts a call waits on
/// nothing it could have done before. There are two, each with one of these: **New**'s, on a
/// conversation Zimmer keeps ready for it, and **Continue**'s, on the open one. The design, the
/// costs and the numbers behind every constant here are `ios/CARPLAY_PREWARM_DESIGN.md`.
///
/// Pure, so it is tested on Linux: the app (`LiveWarmKeeper`) tells it what happened, and it
/// answers what to do. **What it can ask for is the whole of what a connection in standby ever
/// does**:
///
/// - `refresh`: read what to be ready for. Continue's is the open conversation
///   (`GET /api/v1/live_conversations`); New's is the one Zimmer keeps ready
///   (`POST /api/v1/live_conversations/standby`);
/// - `mint`: ask Zimmer which engine the call would run on and open its connection: a Realtime
///   WebSocket, or a GPT-Live WebRTC session with inference paused. Changes nothing on the
///   conversation;
/// - `ping`: see that it is alive: a WebSocket control frame, or what ICE says;
/// - `close`: let it go.
///
/// There is no action that sends on the connection: no text, no microphone, no `response.create`,
/// no `session.update`. Only `claim`, which the app calls from the person's tap, hands it to a call.
///
/// **What it costs.** Realtime bills by tokens, and a session nothing is said on uses none. GPT-Live
/// bills by the second, at a lower rate while inference is paused; so a GPT-Live connection is held
/// only for `restAfter` from the last sign that a call may be near (the car connecting or coming to
/// the front, Live opening, a call starting or ending), and Zimmer refuses one past a daily cap.
///
/// Bounded besides, because a phone in a car is on battery and a cellular link: one connection of
/// each kind at most, replaced when it is old, at most `warmsPerVisit` mints, backing off after a
/// failure, and none at all on Low Power Mode, a serious thermal state, Low Data Mode or no network.
public struct LiveWarmStart: Sendable, Equatable {
    // MARK: - Policy

    /// How often the app ticks this.
    public static let tickEvery: TimeInterval = 1
    /// How often the open conversation is read again, so Continue's connection follows it.
    public static let refreshEvery: TimeInterval = 30
    /// How old a read of the open conversation a tap on Continue goes by: past one late refresh.
    public static let trustReadFor: TimeInterval = 60
    /// How often New's conversation is asked for again: it changes only when it is taken.
    public static let standbyRefreshEvery: TimeInterval = 600
    /// How often a warm connection is pinged. Well inside the idle timeouts of carrier NATs, which
    /// drop a quiet TCP flow after 30 s to a few minutes.
    public static let heartbeatEvery: TimeInterval = 20
    /// From the mint to the connection being up. A cold call takes 2 to 5 seconds for all of it, and
    /// a first request from a car can stall 5 more.
    public static let warmingDeadline: TimeInterval = 15
    /// A connection not heard from (an event or a pong) for this long is not handed to a call.
    public static let staleAfter: TimeInterval = 45
    /// A connection not heard from for this long is dead: closed, and warmed again after a wait.
    public static let deadAfter: TimeInterval = 70
    /// A Realtime connection is replaced after this, so the secret's session config (model, voice,
    /// turn detection) is never more than this far behind the Live settings.
    public static let maxAge: TimeInterval = 300
    /// A GPT-Live connection is held this long at most, and no longer than half the life OpenAI
    /// gave its session, so a call that starts on it has the rest to run in.
    public static let standbyMaxAge: TimeInterval = 1_200
    /// How long a GPT-Live connection, which costs money, is held after the last sign a call may
    /// be near. Past it, nothing is held until the next.
    public static let restAfter: TimeInterval = 1_200
    /// The waits after a failed warm-up, one per failure in a row; the last repeats.
    public static let backoff: [TimeInterval] = [5, 15, 60, 120]
    /// The most mints in one visit: an hour and a quarter of a home screen nobody taps, at `maxAge`
    /// each. Past it calls start cold. A visit is a car connection, or Live open on the phone, with any
    /// that begins within `visitLasts` of it: putting the phone down and picking it up is no new budget.
    public static let warmsPerVisit = 15
    public static let visitLasts: TimeInterval = 3_600
    /// A gap between ticks longer than this means iOS suspended the app: nothing heard can be
    /// trusted, so the connection is pinged and the open conversation read at once.
    public static let longestTickGap: TimeInterval = 5

    // MARK: - Inputs and outputs

    /// Which tap a connection is for.
    public enum Slot: String, Sendable, Equatable {
        /// Continue: the open conversation.
        case open
        /// New: the conversation Zimmer keeps ready. Held through a call too, because New is what
        /// replaces the conversation a call is on.
        case new
    }

    /// What the connection is.
    public enum Engine: String, Sendable, Equatable {
        case realtime
        case gptLive = "gpt_live"
    }

    /// What the app knows when it asks: the conversation from the last refresh, the call, and the
    /// phone.
    public struct Conditions: Sendable, Equatable {
        public var callActive: Bool
        /// The conversation this tap would call.
        public var conversation: Int?
        /// What the conversation holds, for an engine whose instructions are fixed when it starts:
        /// a GPT-Live connection made on another version of it is made again. Nil: nothing to say.
        public var version: String?
        /// The person is in a conversation they type in, so no call is near.
        public var typing: Bool
        /// It is active, not still reading its instructions: a secret can be minted on it.
        public var conversationReady: Bool
        public var lowPower: Bool
        /// `ProcessInfo.thermalState` is serious or critical.
        public var hot: Bool
        /// Low Data Mode: the person asked apps not to use the network in the background.
        public var constrained: Bool
        public var online: Bool

        public init(callActive: Bool = false, conversation: Int?, version: String? = nil, typing: Bool = false, conversationReady: Bool = true,
                    lowPower: Bool = false, hot: Bool = false, constrained: Bool = false, online: Bool = true) {
            self.callActive = callActive
            self.conversation = conversation
            self.version = version
            self.typing = typing
            self.conversationReady = conversationReady
            self.lowPower = lowPower
            self.hot = hot
            self.constrained = constrained
            self.online = online
        }

        /// Why nothing is held for `slot`, or nil when a connection may be.
        public func hold(for slot: Slot) -> Hold? {
            if callActive, slot == .open { return .callActive }
            if typing { return .typing }
            if lowPower { return .lowPower }
            if hot { return .thermal }
            if constrained { return .constrained }
            if !online { return .offline }
            if conversation == nil { return .noConversation }
            if !conversationReady { return .conversationNotReady }
            return nil
        }
    }

    /// Why no connection is being warmed.
    public enum Hold: String, Sendable, Equatable {
        case callActive = "call_active"
        case lowPower = "low_power"
        case thermal
        case constrained = "low_data_mode"
        case offline
        case noConversation = "no_conversation"
        case conversationNotReady = "conversation_not_ready"
        case typing
        /// Nothing for `restAfter` said a call is near, and this engine's standby costs money.
        case resting
        case budgetSpent = "budget_spent"
        case backingOff = "backing_off"
    }

    public enum Phase: String, Sendable, Equatable {
        /// Nothing open.
        case idle
        /// A secret is being minted, or the socket is waiting for `session.created`.
        case warming
        /// Open, `session.created` heard, and nothing sent.
        case warm
    }

    public enum CloseReason: String, Sendable, Equatable {
        case left
        case callStarted = "call_started"
        /// The conversation was added to since, and the connection's instructions cannot be.
        case conversationChanged = "conversation_changed"
        case settingsChanged = "settings_changed"
        case resting
        case suspended
        case conversationMoved = "conversation_moved"
        case maxAge = "max_age"
        case silent
        case timedOut = "warming_timed_out"
        case failed
        case held
    }

    /// What the app should do. Nothing here sends on the socket: see the type's comment.
    public enum Action: Sendable, Equatable {
        case refresh
        case mint(conversation: Int)
        case ping
        case close(CloseReason)
    }

    /// What a tap found.
    public enum Claim: Sendable, Equatable {
        /// The warm connection is the call's now. `age`: how long it had been warm.
        case warm(age: TimeInterval)
        /// A GPT-Live connection on its way up is the call's now, to finish coming up as.
        case warming(age: TimeInterval)
        /// None to hand over; the call starts cold.
        case cold(Miss)
    }

    /// Why a tap started cold.
    public enum Miss: String, Sendable, Equatable {
        /// There is none: something holds it (`hold`).
        case none
        /// One was on its way and not yet up.
        case warming
        /// The one warm is for another conversation.
        case otherConversation = "other_conversation"
        /// Not heard from recently enough to trust: iOS may have suspended the app under it.
        case stale
        case tooOld = "too_old"
    }

    // MARK: - State

    public let slot: Slot
    public private(set) var phase = Phase.idle
    /// The conversation the connection warming or warm is for.
    public private(set) var conversation: Int?
    /// What the connection is. Nil until Zimmer has said.
    public private(set) var engine: Engine?
    /// Mints in this visit.
    public private(set) var warms = 0
    /// Why nothing is warming, as of the last decision. Nil while one is, or before the first.
    public private(set) var hold: Hold?
    private var active = false
    private var visitBegan: TimeInterval?
    /// What the last connection was: whether holding one costs money, until Zimmer says otherwise.
    private var lastEngine: Engine?
    private var conditions: Conditions?
    private var version: String?
    private var life: TimeInterval = LiveWarmStart.maxAge
    private var interestAt: TimeInterval = 0
    private var since: TimeInterval = 0
    private var lastHeard: TimeInterval = 0
    private var lastPing: TimeInterval = 0
    private var lastRefresh: TimeInterval = 0
    private var lastTick: TimeInterval?
    private var failures = 0
    private var retryAt: TimeInterval?

    public init(_ slot: Slot = .open) {
        self.slot = slot
    }

    /// The car connected, or Live opened on the phone: a fresh budget, and read what to be ready for.
    public mutating func activate(at now: TimeInterval) -> [Action] {
        let (visit, spent) = (visitBegan, warms)
        self = LiveWarmStart(slot)
        if let visit, now - visit < Self.visitLasts {
            visitBegan = visit
            warms = spent
        } else {
            visitBegan = now
        }
        active = true
        interestAt = now
        lastRefresh = now
        lastTick = now
        return [.refresh]
    }

    /// The car went, or Live closed: close whatever is open, and do nothing more until it is back.
    public mutating func deactivate() -> [Action] {
        let open = phase != .idle
        let (visit, spent) = (visitBegan, warms)
        self = LiveWarmStart(slot)
        visitBegan = visit
        warms = spent
        return open ? [.close(.left)] : []
    }

    /// Something says a call may be near: Zimmer came to the front in the car, or on the phone.
    public mutating func interest(at now: TimeInterval) -> [Action] {
        guard active else { return [] }
        interestAt = now
        return hold == .resting ? evaluate(at: now) : []
    }

    /// A refresh answered, or the phone changed (Low Power Mode, the network, the call).
    public mutating func update(_ conditions: Conditions, at now: TimeInterval) -> [Action] {
        guard active else { return [] }
        self.conditions = conditions
        return evaluate(at: now)
    }

    /// A refresh got no answer: ask again in `refreshEvery`, however long this slot's is.
    public mutating func refreshFailed(at now: TimeInterval) {
        lastRefresh = now - refreshInterval + Self.refreshEvery
    }

    /// Zimmer said what the connection being opened is.
    public mutating func connecting(_ engine: Engine) {
        guard phase == .warming else { return }
        self.engine = engine
        lastEngine = engine
    }

    /// The connection is up: OpenAI said `session.created`, or `session.started`. `life`: how long
    /// OpenAI gave the session, when it said.
    public mutating func ready(at now: TimeInterval, life: TimeInterval? = nil) {
        guard phase == .warming else { return }
        phase = .warm
        since = now
        lastHeard = now
        lastPing = now
        failures = 0
        retryAt = nil
        self.life = engine == .gptLive ? min(Self.standbyMaxAge, (life ?? .infinity) / 2) : Self.maxAge
    }

    /// Any server event, or a pong: the connection is alive.
    public mutating func heard(at now: TimeInterval) {
        guard phase != .idle else { return }
        lastHeard = max(lastHeard, now)
    }

    /// The mint failed, the connection closed, or it did not answer a ping.
    public mutating func failed(at now: TimeInterval) -> [Action] {
        guard phase != .idle else { return [] }
        return fail(.failed, at: now)
    }

    /// The Live settings were changed on this phone: what is held was made from the old ones.
    public mutating func settingsChanged(at now: TimeInterval) -> [Action] {
        guard active else { return [] }
        interestAt = now
        failures = 0
        retryAt = nil
        return (phase == .idle ? [] : close(.settingsChanged)) + evaluate(at: now)
    }

    public mutating func tick(at now: TimeInterval) -> [Action] {
        guard active else { return [] }
        var actions: [Action] = []
        let slept = lastTick.map { now - $0 > Self.longestTickGap } ?? false
        lastTick = now
        if slept || now - lastRefresh >= refreshInterval {
            lastRefresh = now
            actions.append(.refresh)
        }
        // Suspended, the app kept no ICE consent going: OpenAI has let a GPT-Live session go, or is
        // about to, and nothing on this end says so for seconds. Not one to hand to a call.
        if slept, phase != .idle, engine == .gptLive { actions += close(.suspended) + evaluate(at: now) }
        switch phase {
        case .idle:
            if let retryAt, now >= retryAt {
                self.retryAt = nil
                actions += evaluate(at: now)
            }
        case .warming:
            if now - since > Self.warmingDeadline { actions += fail(.timedOut, at: now) }
        case .warm:
            if now - lastHeard > Self.deadAfter {
                actions += fail(.silent, at: now)
            } else if resting(at: now) {
                actions += evaluate(at: now)
            } else if now - since >= life {
                actions += close(.maxAge)
                actions += evaluate(at: now)
            } else if slept || now - lastPing >= Self.heartbeatEvery {
                lastPing = now
                actions.append(.ping)
            }
        }
        return actions
    }

    /// The person tapped, and the call is starting on `conversation`. Only this hands a connection
    /// to a call. A New that is taken leaves nothing to be ready for until Zimmer keeps another.
    public mutating func claim(_ conversation: Int, at now: TimeInterval) -> Claim {
        if phase == .idle { return .cold(.none) }
        if self.conversation != conversation { return .cold(.otherConversation) }
        // Nothing has ticked since iOS suspended the app: see `tick`.
        if engine == .gptLive, let lastTick, now - lastTick > Self.longestTickGap { return .cold(.stale) }
        let age = now - since
        if phase == .warming {
            // On its way up it is still seconds ahead of one started now. A Realtime socket has
            // nothing on it yet worth taking.
            guard engine == .gptLive else { return .cold(.warming) }
            taken()
            return .warming(age: age)
        }
        if now - lastHeard > Self.staleAfter { return .cold(.stale) }
        if age >= life { return .cold(.tooOld) }
        taken()
        return .warm(age: age)
    }

    /// A call started, on this connection or not.
    public mutating func callStarted(at now: TimeInterval) -> [Action] {
        guard active else { return [] }
        interestAt = now
        conditions?.callActive = true
        return evaluate(at: now)
    }

    /// The call ended, or Zimmer answered New's: read what to be ready for next.
    public mutating func callEnded(at now: TimeInterval) -> [Action] {
        guard active else { return [] }
        interestAt = now
        conditions?.callActive = false
        lastRefresh = now
        return [.refresh]
    }

    /// Zimmer has answered the New this slot's conversation was taken for, so it can keep another
    /// ready: held through the call, for the New that ends it.
    public mutating func taken(at now: TimeInterval) -> [Action] {
        guard active else { return [] }
        lastRefresh = now
        return [.refresh]
    }

    // MARK: - Internals

    private var refreshInterval: TimeInterval { slot == .new ? Self.standbyRefreshEvery : Self.refreshEvery }

    private func resting(at now: TimeInterval) -> Bool {
        lastEngine == .gptLive && now - interestAt >= Self.restAfter
    }

    private mutating func taken() {
        phase = .idle
        conversation = nil
        if slot == .new { conditions?.conversation = nil }
    }

    private mutating func evaluate(at now: TimeInterval) -> [Action] {
        guard let conditions else { return [] }
        if let hold = conditions.hold(for: slot) {
            self.hold = hold
            if phase == .idle { return [] }
            return close(hold == .callActive ? .callStarted : .held)
        }
        guard let target = conditions.conversation else { return [] }
        if resting(at: now) {
            hold = .resting
            return phase == .idle ? [] : close(.resting)
        }
        var actions: [Action] = []
        if phase != .idle {
            if conversation != target {
                actions += close(.conversationMoved)
            } else if engine == .gptLive, version != conditions.version {
                actions += close(.conversationChanged)
            } else {
                return []
            }
        }
        if let retryAt, now < retryAt {
            hold = .backingOff
            return actions
        }
        guard warms < Self.warmsPerVisit else {
            hold = .budgetSpent
            return actions
        }
        hold = nil
        phase = .warming
        conversation = target
        // Until Zimmer says what this one is.
        engine = nil
        version = conditions.version
        since = now
        lastHeard = now
        warms += 1
        return actions + [.mint(conversation: target)]
    }

    private mutating func close(_ reason: CloseReason) -> [Action] {
        phase = .idle
        conversation = nil
        return [.close(reason)]
    }

    private mutating func fail(_ reason: CloseReason, at now: TimeInterval) -> [Action] {
        failures += 1
        retryAt = now + Self.backoff[min(failures, Self.backoff.count) - 1]
        hold = .backingOff
        return close(reason)
    }
}

/// How a call got going, for `call.startup`.
public enum LiveStartPath: String, Sendable, Equatable {
    /// On the warm connection.
    case warm
    /// Minted and connected from nothing.
    case cold
    /// On a GPT-Live connection that was still on its way up.
    case warming
    /// The connection was claimed and failed to come up as a call; started cold instead.
    case fallback
}

/// Standby's events, for `LiveTelemetry`. Names, reasons and timings only. `slot` is the tap the
/// connection is for (`open` or `new`).
public extension LiveEvent {
    static func warmMinting(_ slot: LiveWarmStart.Slot, conversation: Int, warms: Int) -> LiveEvent {
        LiveEvent(.debug, "warm.minting") { ["slot": .string(slot.rawValue), "conversation": .int(conversation), "warms": .int(warms)] }
    }

    /// The connection is up: from asking Zimmer for it to OpenAI's answer on it.
    static func warmReady(_ slot: LiveWarmStart.Slot, engine: LiveWarmStart.Engine?, sinceMint: TimeInterval, life: TimeInterval? = nil) -> LiveEvent {
        LiveEvent(.info, "warm.ready") {
            ["slot": .string(slot.rawValue), "engine": .text(engine?.rawValue), "since_mint_ms": .ms(sinceMint), "session_life_ms": .ms(life)]
        }
    }

    static func warmClosed(_ slot: LiveWarmStart.Slot, _ reason: LiveWarmStart.CloseReason, age: TimeInterval?) -> LiveEvent {
        LiveEvent(.info, "warm.closed") { ["slot": .string(slot.rawValue), "reason": .string(reason.rawValue), "age_ms": .ms(age)] }
    }

    static func warmFailed(_ slot: LiveWarmStart.Slot, _ message: String) -> LiveEvent {
        LiveEvent(.warn, "warm.failed") { ["slot": .string(slot.rawValue), "message": .string(message)] }
    }

    /// Nothing is being held, and why. Logged when the reason changes.
    static func warmHeld(_ slot: LiveWarmStart.Slot, _ hold: LiveWarmStart.Hold) -> LiveEvent {
        LiveEvent(.debug, "warm.held") { ["slot": .string(slot.rawValue), "hold": .string(hold.rawValue)] }
    }

    /// What a tap found: the hit rate for a tap is `claimed` over `claimed` plus `missed`.
    static func warmClaim(_ slot: LiveWarmStart.Slot, _ claim: LiveWarmStart.Claim, hold: LiveWarmStart.Hold?, engine: LiveWarmStart.Engine?) -> LiveEvent {
        func claimed(_ age: TimeInterval, up: Bool) -> LiveEvent {
            LiveEvent(.info, "warm.claimed") {
                ["slot": .string(slot.rawValue), "engine": .text(engine?.rawValue), "up": .bool(up), "age_ms": .ms(age)]
            }
        }
        switch claim {
        case let .warm(age): return claimed(age, up: true)
        case let .warming(age): return claimed(age, up: false)
        case let .cold(miss):
            return LiveEvent(.info, "warm.missed") {
                ["slot": .string(slot.rawValue), "reason": .string(miss.rawValue), "hold": .text(hold?.rawValue)]
            }
        }
    }

    /// A claimed connection did not become a call; the call went cold instead.
    static func warmFallback(_ message: String) -> LiveEvent {
        LiveEvent(.warn, "warm.fallback") { ["message": .string(message)] }
    }

    /// The startup metric: from the tap to the call being up (the *connected* notes), and how it
    /// got there. `tap_to_ready_ms`, split by `tap` and `path`, is the number standby is judged on.
    /// `tap`: `new`, `continue`, or nil for a call on a conversation already on the screen.
    static func callStartup(path: LiveStartPath, tap: String?, engine: String, tapToReady: TimeInterval, surface: String) -> LiveEvent {
        LiveEvent(.info, "call.startup") {
            ["path": .string(path.rawValue), "tap": .text(tap), "engine": .string(engine), "tap_to_ready_ms": .ms(tapToReady), "surface": .string(surface)]
        }
    }

    /// Zimmer has the conversation the call is on: from the tap, and how long the request took. On a
    /// call from standby this comes after the call is up, so it is no part of the wait.
    static func callSettled(sinceTap: TimeInterval?, request: TimeInterval, moved: Bool) -> LiveEvent {
        LiveEvent(.info, "call.settled") { ["since_tap_ms": .ms(sinceTap), "request_ms": .ms(request), "moved": .bool(moved)] }
    }

    /// The microphone is open on a call from standby: from the tap.
    static func warmMicrophoneOpen(sinceTap: TimeInterval) -> LiveEvent {
        LiveEvent(.info, "call.microphone_open") { ["since_tap_ms": .ms(sinceTap)] }
    }

    /// The first of the model's audio played on this call: from the tap. A call the driver opens
    /// by talking has this after their first line; one opened with a line (a tapped session) has
    /// it straight after connecting.
    static func firstAudio(sinceTap: TimeInterval, path: LiveStartPath) -> LiveEvent {
        LiveEvent(.info, "call.first_audio") { ["since_tap_ms": .ms(sinceTap), "path": .string(path.rawValue)] }
    }
}
