import Foundation

/// CarPlay pre-warm: while the car is connected and no call is up, keep one Realtime connection
/// ready for Continue, so the tap skips the secret, the TLS and WebSocket handshakes and OpenAI's
/// session setup. The design, the numbers behind every constant here and the missing off switch
/// are `ios/CARPLAY_PREWARM_DESIGN.md`.
///
/// Pure, so it is tested on Linux: the app (`LiveWarmLink`, `LiveWarmKeeper`) tells it what
/// happened, and it answers what to do. **What it can ask for is the whole of what a warm
/// connection ever does**, and none of it is a Realtime event:
///
/// - `refresh`: read the open conversation from Zimmer (`GET /api/v1/live_conversations`);
/// - `mint`: a prewarm secret (`LiveAPI.livePrewarmSecret`), which changes nothing on the
///   conversation, and a WebSocket opened with it;
/// - `ping`: a WebSocket control frame. Not a Realtime event: OpenAI bills nothing for it;
/// - `close`: drop the connection.
///
/// There is no action that sends on the socket. No audio, no text, no `response.create`, no
/// `session.update`: nothing user-originated and nothing billable goes up a warm connection.
/// Only `claim`, which the app calls from the driver's tap, hands the connection to the call,
/// and only the call sends on it.
///
/// OpenAI bills Realtime by tokens: audio and text in, audio and text out. A session that is open
/// with no audio appended and no response asked for produces none. What a warm connection costs
/// is a secret mint (free), a socket, and a ping every `heartbeatEvery`.
///
/// Bounded, because a phone in a car is on battery and a cellular link: one connection at most,
/// replaced after `maxAge`, at most `warmsPerDrive` mints per car connection, backing off after a
/// failure, and none at all on Low Power Mode, a serious thermal state, Low Data Mode or no network.
public struct LiveWarmStart: Sendable, Equatable {
    // MARK: - Policy

    /// How often the app ticks this.
    public static let tickEvery: TimeInterval = 1
    /// How often the open conversation is read again, so the warm connection follows it.
    public static let refreshEvery: TimeInterval = 30
    /// How often a warm connection is pinged. Well inside the idle timeouts of carrier NATs, which
    /// drop a quiet TCP flow after 30 s to a few minutes.
    public static let heartbeatEvery: TimeInterval = 20
    /// From the mint to OpenAI's `session.created`. A cold call takes 2 to 3 seconds for all of it.
    public static let warmingDeadline: TimeInterval = 10
    /// A connection not heard from (an event or a pong) for this long is not handed to a call.
    public static let staleAfter: TimeInterval = 45
    /// A connection not heard from for this long is dead: closed, and warmed again after a wait.
    public static let deadAfter: TimeInterval = 70
    /// A warm connection is replaced after this, so the secret's session config (model, voice,
    /// turn detection) is never more than this far behind the Live settings.
    public static let maxAge: TimeInterval = 300
    /// The waits after a failed warm-up, one per failure in a row; the last repeats.
    public static let backoff: [TimeInterval] = [5, 15, 60, 120]
    /// The most mints in one car connection: an hour and a quarter of a home screen nobody taps,
    /// at `maxAge` each. Past it the car starts cold.
    public static let warmsPerDrive = 15
    /// A gap between ticks longer than this means iOS suspended the app: nothing heard can be
    /// trusted, so the connection is pinged and the open conversation read at once.
    public static let longestTickGap: TimeInterval = 5

    // MARK: - Inputs and outputs

    /// What the app knows when it asks: the open conversation from the last refresh,
    /// the call, and the phone.
    public struct Conditions: Sendable, Equatable {
        public var callActive: Bool
        /// The conversation Continue would call: the open one.
        public var conversation: Int?
        /// It is active, not still reading its instructions: a secret can be minted on it.
        public var conversationReady: Bool
        public var lowPower: Bool
        /// `ProcessInfo.thermalState` is serious or critical.
        public var hot: Bool
        /// Low Data Mode: the person asked apps not to use the network in the background.
        public var constrained: Bool
        public var online: Bool

        public init(callActive: Bool = false, conversation: Int?, conversationReady: Bool = true, lowPower: Bool = false,
                    hot: Bool = false, constrained: Bool = false, online: Bool = true) {
            self.callActive = callActive
            self.conversation = conversation
            self.conversationReady = conversationReady
            self.lowPower = lowPower
            self.hot = hot
            self.constrained = constrained
            self.online = online
        }

        /// Why nothing is warmed, or nil when a connection may be.
        public var hold: Hold? {
            if callActive { return .callActive }
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
        case carLeft = "car_left"
        case callStarted = "call_started"
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
        /// None to hand over; the call starts cold.
        case cold(Miss)
    }

    /// Why a tap started cold.
    public enum Miss: String, Sendable, Equatable {
        /// The car never warmed one: something holds it (`hold`).
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

    public private(set) var phase = Phase.idle
    /// The conversation the connection warming or warm is for.
    public private(set) var conversation: Int?
    /// Mints in this car connection.
    public private(set) var warms = 0
    /// Why nothing is warming, as of the last decision. Nil while one is, or before the first.
    public private(set) var hold: Hold?
    private var carConnected = false
    private var conditions: Conditions?
    private var since: TimeInterval = 0
    private var lastHeard: TimeInterval = 0
    private var lastPing: TimeInterval = 0
    private var lastRefresh: TimeInterval = 0
    private var lastTick: TimeInterval?
    private var failures = 0
    private var retryAt: TimeInterval?

    public init() {}

    /// The car connected: a fresh budget, and read what is open.
    public mutating func carConnected(at now: TimeInterval) -> [Action] {
        self = LiveWarmStart()
        carConnected = true
        lastRefresh = now
        lastTick = now
        return [.refresh]
    }

    /// The car went: close whatever is open, and do nothing more until it is back.
    public mutating func carDisconnected() -> [Action] {
        let open = phase != .idle
        self = LiveWarmStart()
        return open ? [.close(.carLeft)] : []
    }

    /// A refresh answered, or the phone changed (Low Power Mode, the network, the call).
    public mutating func update(_ conditions: Conditions, at now: TimeInterval) -> [Action] {
        guard carConnected else { return [] }
        self.conditions = conditions
        return evaluate(at: now)
    }

    /// OpenAI said `session.created` on the socket: warm.
    public mutating func ready(at now: TimeInterval) {
        guard phase == .warming else { return }
        phase = .warm
        since = now
        lastHeard = now
        lastPing = now
        failures = 0
        retryAt = nil
    }

    /// Any server event, or a pong: the connection is alive.
    public mutating func heard(at now: TimeInterval) {
        guard phase != .idle else { return }
        lastHeard = max(lastHeard, now)
    }

    /// The mint failed, the socket closed, or a ping came back with an error.
    public mutating func failed(at now: TimeInterval) -> [Action] {
        guard phase != .idle else { return [] }
        return fail(.failed, at: now)
    }

    public mutating func tick(at now: TimeInterval) -> [Action] {
        guard carConnected else { return [] }
        var actions: [Action] = []
        let slept = lastTick.map { now - $0 > Self.longestTickGap } ?? false
        lastTick = now
        if slept || now - lastRefresh >= Self.refreshEvery {
            lastRefresh = now
            actions.append(.refresh)
        }
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
            } else if now - since >= Self.maxAge {
                actions += close(.maxAge)
                actions += evaluate(at: now)
            } else if slept || now - lastPing >= Self.heartbeatEvery {
                lastPing = now
                actions.append(.ping)
            }
        }
        return actions
    }

    /// The driver tapped Continue on `conversation`. Only this hands a connection to a call.
    public mutating func claim(_ conversation: Int, at now: TimeInterval) -> Claim {
        switch phase {
        case .idle: return .cold(.none)
        case .warming: return .cold(.warming)
        case .warm: break
        }
        if self.conversation != conversation { return .cold(.otherConversation) }
        if now - lastHeard > Self.staleAfter { return .cold(.stale) }
        if now - since >= Self.maxAge { return .cold(.tooOld) }
        let age = now - since
        phase = .idle
        self.conversation = nil
        return .warm(age: age)
    }

    /// A call started, warm or cold: whatever is still open is not going to be used.
    public mutating func callStarted(at now: TimeInterval) -> [Action] {
        guard carConnected else { return [] }
        conditions?.callActive = true
        return evaluate(at: now)
    }

    /// The call ended with the car still connected: read what is open, for the next tap.
    public mutating func callEnded(at now: TimeInterval) -> [Action] {
        guard carConnected else { return [] }
        conditions?.callActive = false
        lastRefresh = now
        return [.refresh]
    }

    // MARK: - Internals

    private mutating func evaluate(at now: TimeInterval) -> [Action] {
        guard let conditions else { return [] }
        if let hold = conditions.hold {
            self.hold = hold
            if phase == .idle { return [] }
            return close(hold == .callActive ? .callStarted : .held)
        }
        guard let target = conditions.conversation else { return [] }
        var actions: [Action] = []
        if phase != .idle {
            if conversation == target { return [] }
            actions += close(.conversationMoved)
        }
        if let retryAt, now < retryAt {
            hold = .backingOff
            return actions
        }
        guard warms < Self.warmsPerDrive else {
            hold = .budgetSpent
            return actions
        }
        hold = nil
        phase = .warming
        conversation = target
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

/// How a call from the car got going, for `call.startup`.
public enum LiveStartPath: String, Sendable, Equatable {
    /// On the warm connection.
    case warm
    /// Minted and connected from nothing.
    case cold
    /// The warm connection was claimed and failed to come up as a call; started cold instead.
    case fallback
}

/// The pre-warm's events, for `LiveTelemetry`. Names, reasons and timings only.
public extension LiveEvent {
    static func warmMinting(conversation: Int, warms: Int) -> LiveEvent {
        LiveEvent(.debug, "warm.minting") { ["conversation": .int(conversation), "warms": .int(warms)] }
    }

    /// `session.created` on a warm connection: from asking for the secret to OpenAI's answer.
    static func warmReady(sinceMint: TimeInterval) -> LiveEvent {
        LiveEvent(.info, "warm.ready") { ["since_mint_ms": .ms(sinceMint)] }
    }

    static func warmClosed(_ reason: LiveWarmStart.CloseReason, age: TimeInterval?) -> LiveEvent {
        LiveEvent(.info, "warm.closed") { ["reason": .string(reason.rawValue), "age_ms": .ms(age)] }
    }

    static func warmFailed(_ message: String) -> LiveEvent {
        LiveEvent(.warn, "warm.failed") { ["message": .string(message)] }
    }

    /// Nothing is being warmed, and why. Logged when the reason changes.
    static func warmHeld(_ hold: LiveWarmStart.Hold) -> LiveEvent {
        LiveEvent(.debug, "warm.held") { ["hold": .string(hold.rawValue)] }
    }

    /// What a tap found: the warm-hit rate is `claimed` over `claimed` plus `missed`.
    static func warmClaim(_ claim: LiveWarmStart.Claim, hold: LiveWarmStart.Hold?) -> LiveEvent {
        switch claim {
        case let .warm(age):
            return LiveEvent(.info, "warm.claimed") { ["age_ms": .ms(age)] }
        case let .cold(miss):
            return LiveEvent(.info, "warm.missed") { ["reason": .string(miss.rawValue), "hold": .text(hold?.rawValue)] }
        }
    }

    /// A claimed connection did not become a call; the call went cold instead.
    static func warmFallback(_ message: String) -> LiveEvent {
        LiveEvent(.warn, "warm.fallback") { ["message": .string(message)] }
    }

    /// The startup metric: from the tap to the call being up (the *connected* notes), and how it
    /// got there. `tap_to_ready_ms`, split by `path`, is the number the pre-warm is judged on.
    static func callStartup(path: LiveStartPath, tapToReady: TimeInterval, surface: String) -> LiveEvent {
        LiveEvent(.info, "call.startup") { ["path": .string(path.rawValue), "tap_to_ready_ms": .ms(tapToReady), "surface": .string(surface)] }
    }

    /// The first of the model's audio played on this call: from the tap. A call the driver opens
    /// by talking has this after their first line; one opened with a line (a tapped session) has
    /// it straight after connecting.
    static func firstAudio(sinceTap: TimeInterval, path: LiveStartPath) -> LiveEvent {
        LiveEvent(.info, "call.first_audio") { ["since_tap_ms": .ms(sinceTap), "path": .string(path.rawValue)] }
    }
}
