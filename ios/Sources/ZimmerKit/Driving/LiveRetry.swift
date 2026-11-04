import Foundation

/// What the car does when a Live Mode call it started cannot connect, or drops: it says so on
/// the Talk tile and tries again, quietly. It never speaks with any other voice — the car has
/// one voice, the Realtime call's — so a call that is not up is shown, not said.
///
/// The retries belong to the driver's tap. Tapping Talk starts a fresh budget; a few failures
/// in a row use it up, and the tile then says Live Mode is unavailable until the driver taps it
/// again. Hanging up ends the wish for a call, so nothing is retried after it.
///
/// The budget is time as well as tries. A call that fails at once uses all three retries; one
/// that hangs until `LiveCallHealth.connectDeadline` would take over a minute to, so no wait
/// starts that would run past `budget`, and a driver hears the outcome in about half a minute.
public struct LiveRetry: Hashable, Sendable {
    /// The waits before each retry. Once they are used up the car stops trying.
    public static let delays: [Duration] = [.seconds(2), .seconds(5), .seconds(15)]
    /// No retry is waited for past this long after the tap, or after a call that was up dropped.
    public static let budget: TimeInterval = 30

    /// The driver asked for a call and has not hung up.
    public private(set) var wanted = false
    /// Failures since the driver last asked, or since the call last came up.
    public private(set) var failures = 0
    /// Finding the conversation to call, the part of a tap that comes before the call exists.
    /// A second tap in the meantime is not a second attempt.
    public private(set) var lookingUp = false
    /// When this run of trying began: the tap, or a good call's drop. Nil while a call is up.
    private var since: TimeInterval?

    public init() {}

    /// The driver tapped Talk (or a session's row): a fresh budget.
    public mutating func asked(at now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        wanted = true
        failures = 0
        since = now
    }

    /// An attempt started finding its conversation.
    public mutating func lookup() {
        lookingUp = true
    }

    /// The attempt has its conversation, or has failed to find one.
    public mutating func lookedUp() {
        lookingUp = false
    }

    /// The call came up: the next drop gets the whole budget again.
    public mutating func connected() {
        failures = 0
        since = nil
    }

    /// A failure no retry can fix (the microphone is off for Zimmer): stop, and say unavailable.
    public mutating func gaveUp() {
        wanted = false
        failures = max(failures, 1)
    }

    /// The driver hung up, or the car went away: nothing more to retry.
    public mutating func stopped() {
        wanted = false
        failures = 0
    }

    /// The call failed. How long to wait before trying again, or nil when the car should stop
    /// and say Live Mode is unavailable — or when nobody asked for this call.
    public mutating func failed(at now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Duration? {
        guard wanted else { return nil }
        let since = self.since ?? now
        self.since = since
        let wait = failures < Self.delays.count ? Self.delays[failures] : nil
        guard let wait, now - since + Double(wait.components.seconds) <= Self.budget else {
            wanted = false
            failures = max(failures, 1)
            return nil
        }
        failures += 1
        return wait
    }

    /// What the Talk tile says.
    public func tile(callIsActive: Bool) -> LiveTalkTile {
        if callIsActive { return .inCall }
        guard failures > 0 else { return lookingUp ? .connecting : .ready }
        // Waiting to retry, or a retry connecting: either way it is still trying.
        return wanted ? .retrying : .unavailable
    }
}

/// The Talk tile's words: the one place the car says whether Live Mode is there.
public enum LiveTalkTile: Hashable, Sendable {
    case ready, connecting, inCall, retrying, unavailable

    /// Longest first, as CarPlay chooses among them.
    public var titleVariants: [String] {
        switch self {
        case .ready: return ["Talk to Zimmer", "Talk"]
        case .connecting: return ["Connecting…", "Calling…"]
        case .inCall: return ["Back to the call", "Call"]
        case .retrying: return ["Live Mode unavailable, retrying…", "Retrying…"]
        case .unavailable: return ["Live Mode unavailable. Tap to retry", "Retry"]
        }
    }

    /// The tile's symbol.
    public var symbol: String {
        switch self {
        case .ready: return "mic.fill"
        case .connecting: return "waveform"
        case .inCall: return "waveform"
        case .retrying: return "arrow.triangle.2.circlepath"
        case .unavailable: return "exclamationmark.triangle.fill"
        }
    }
}
