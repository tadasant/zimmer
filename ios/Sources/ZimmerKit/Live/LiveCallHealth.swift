import Foundation

/// Whether a Live voice call is still a call: the rules that stop one sitting on *Connecting…* or
/// *Listening* for minutes. Pure, so they are tested on Linux: `LiveCall` tells it what happened,
/// and every tick it answers what to do.
///
/// - **Connecting** has a deadline, from the moment the call starts. A call is up once its
///   microphone is open and OpenAI has said `session.created`, which is the only proof the socket
///   works: a socket that has been asked to open has proved nothing.
/// - **A socket that went quiet** is pinged. Nothing else notices: a car driving out of coverage
///   leaves the socket open with nobody on the other end until TCP gives up, minutes later. Any
///   server event counts as hearing from OpenAI, so a ping goes only into a quiet call, and one
///   goes as soon as the call is up, to learn that this server answers them. Only a call that has
///   had a pong can be called dead for missing one, so a server that does not answer pings costs
///   the detection, not the call.
/// - **A microphone that stopped** is covered with silence by `MicWatchdog`. Past a couple of
///   seconds the person is told (`microphoneLost`); past a deadline the call gives up. An
///   interruption gets a far longer deadline, because iOS gives the audio back when a phone call
///   or Siri finishes (a 55 s one has come back and carried on), and sometimes never says it has.
///   The microphone's own deadline counts from the moment nothing was holding it, so a stall that
///   outlives its interruption by the second the engine takes to restart is not a dead microphone.
/// - **A timer that slept** (iOS suspended the app) proves nothing about the socket or the
///   microphone, so a gap between ticks starts both clocks over.
public struct LiveCallHealth: Sendable, Equatable {
    /// From the call starting to the call being up. Calls normally take 2 to 3 seconds.
    public static let connectDeadline: TimeInterval = 15
    /// How long a call may hear nothing from OpenAI before it pings.
    public static let quietBeforePing: TimeInterval = 10
    /// How often a quiet call pings.
    public static let pingEvery: TimeInterval = 5
    /// How long a call that has had a pong may hear nothing before it is dead.
    public static let socketDeadAfter: TimeInterval = 20
    /// How long the microphone is out before the person is told.
    public static let microphoneLostAfter: TimeInterval = 2
    /// How long a microphone that stopped on its own may stay out.
    public static let microphoneDeadline: TimeInterval = 20
    /// How long an interruption may hold the microphone.
    public static let interruptionDeadline: TimeInterval = 90
    /// A gap between ticks longer than this means the timer did not run.
    public static let longestTickGap: TimeInterval = 2

    /// How far a connecting call got, for the log.
    public enum Stage: String, Sendable {
        case secret, microphone, session
    }

    public enum GiveUp: Equatable, Sendable {
        case connectTimedOut(Stage)
        case socketSilent
        case microphoneStopped
        case microphoneHeld

        /// What the person is told, on the phone and on the car's log.
        public var message: String {
            switch self {
            case .connectTimedOut: return "Live Mode didn't connect in time."
            case .socketSilent: return "The call dropped: the connection went quiet."
            case .microphoneStopped: return "The microphone stopped. Start the call again."
            case .microphoneHeld: return "Another app kept the microphone. Start the call again."
            }
        }

        /// For the log: `call.gave_up`'s `reason`.
        public var reason: String {
            switch self {
            case .connectTimedOut: return "connect_timed_out"
            case .socketSilent: return "socket_silent"
            case .microphoneStopped: return "microphone_stopped"
            case .microphoneHeld: return "microphone_held"
            }
        }
    }

    public enum Action: Equatable, Sendable {
        case ping
        case microphoneLost
        case microphoneBack
        case giveUp(GiveUp)
    }

    public var stage = Stage.secret
    private var startedAt: TimeInterval?
    public private(set) var isConnected = false
    private var lastHeard: TimeInterval = 0
    private var lastPing: TimeInterval?
    private var hadPong = false
    private var lastTick: TimeInterval?
    private var microphoneIsLost = false
    /// The last tick an interruption was under way.
    private var interruptedAt: TimeInterval = 0
    /// The last time the timer woke from a gap.
    private var wokeAt: TimeInterval = 0
    private var finished = false

    public init() {}

    /// The call started connecting.
    public mutating func started(at now: TimeInterval) {
        startedAt = now
    }

    /// The microphone is open and OpenAI has said `session.created`.
    public mutating func connected(at now: TimeInterval) {
        isConnected = true
        lastHeard = now
    }

    /// A server event arrived.
    public mutating func heard(at now: TimeInterval) {
        lastHeard = now
    }

    /// A ping was answered.
    public mutating func pong(at now: TimeInterval) {
        hadPong = true
        lastHeard = now
    }

    /// The timer fired. `stalledSince`: when the microphone stopped, while it is stopped
    /// (`MicWatchdog.stalledSince`). `interrupted`: an interruption is under way.
    public mutating func tick(at now: TimeInterval, stalledSince: TimeInterval?, interrupted: Bool) -> [Action] {
        defer { lastTick = now }
        guard !finished, let startedAt else { return [] }
        guard isConnected else {
            guard now - startedAt >= Self.connectDeadline else { return [] }
            finished = true
            return [.giveUp(.connectTimedOut(stage))]
        }
        if let lastTick, now - lastTick > Self.longestTickGap {
            lastHeard = now
            lastPing = nil
            wokeAt = now
        }
        if interrupted { interruptedAt = now }
        if hadPong, now - lastHeard >= Self.socketDeadAfter {
            finished = true
            return [.giveUp(.socketSilent)]
        }
        var actions: [Action] = []
        if let stalledSince {
            let held = now - max(stalledSince, wokeAt)
            let stopped = now - max(stalledSince, wokeAt, interruptedAt)
            if interrupted ? held >= Self.interruptionDeadline : stopped >= Self.microphoneDeadline {
                finished = true
                return [.giveUp(interrupted ? .microphoneHeld : .microphoneStopped)]
            }
            if now - stalledSince >= Self.microphoneLostAfter, !microphoneIsLost {
                microphoneIsLost = true
                actions.append(.microphoneLost)
            }
        } else if microphoneIsLost {
            microphoneIsLost = false
            actions.append(.microphoneBack)
        }
        let pingDue = lastPing.map { now - $0 >= Self.pingEvery } ?? true
        if pingDue, lastPing == nil || now - lastHeard >= Self.quietBeforePing {
            lastPing = now
            actions.append(.ping)
        }
        return actions
    }
}
