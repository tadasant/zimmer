import Foundation

/// What the car does when a Live Mode call it started cannot connect, or drops: it says so on
/// the Talk tile and tries again, quietly. It never speaks with any other voice — the car has
/// one voice, the Realtime call's — so a call that is not up is shown, not said.
///
/// The retries belong to the driver's tap. Tapping Talk starts a fresh budget; a few failures
/// in a row use it up, and the tile then says Live Mode is unavailable until the driver taps it
/// again. Hanging up ends the wish for a call, so nothing is retried after it.
public struct LiveRetry: Hashable, Sendable {
    /// The waits before each retry. Once they are used up the car stops trying.
    public static let delays: [Duration] = [.seconds(2), .seconds(5), .seconds(15)]

    /// The driver asked for a call and has not hung up.
    public private(set) var wanted = false
    /// Failures since the driver last asked.
    public private(set) var failures = 0
    /// Waiting to try again.
    public private(set) var retrying = false

    public init() {}

    /// The driver tapped Talk (or a session's row): a fresh budget.
    public mutating func asked() {
        wanted = true
        failures = 0
        retrying = false
    }

    /// The call is up again, or a retry is starting it.
    public mutating func attempting() {
        retrying = false
    }

    /// The driver hung up, or the car went away: nothing more to retry.
    public mutating func stopped() {
        wanted = false
        failures = 0
        retrying = false
    }

    /// The call failed. How long to wait before trying again, or nil when the car should stop
    /// and say Live Mode is unavailable — or when nobody asked for this call.
    public mutating func failed() -> Duration? {
        guard wanted else { return nil }
        guard failures < Self.delays.count else {
            wanted = false
            retrying = false
            return nil
        }
        let wait = Self.delays[failures]
        failures += 1
        retrying = true
        return wait
    }

    /// What the Talk tile says.
    public func tile(callIsActive: Bool) -> LiveTalkTile {
        if callIsActive { return .inCall }
        if retrying { return .retrying }
        if failures > 0 && !wanted { return .unavailable }
        return .ready
    }
}

/// The Talk tile's words: the one place the car says whether Live Mode is there.
public enum LiveTalkTile: Hashable, Sendable {
    case ready, inCall, retrying, unavailable

    /// Longest first, as CarPlay chooses among them.
    public var titleVariants: [String] {
        switch self {
        case .ready: return ["Talk to Zimmer", "Talk"]
        case .inCall: return ["Back to the call", "Call"]
        case .retrying: return ["Live Mode unavailable, retrying…", "Retrying…"]
        case .unavailable: return ["Live Mode unavailable. Tap to retry", "Retry"]
        }
    }

    /// The tile's symbol.
    public var symbol: String {
        switch self {
        case .ready: return "mic.fill"
        case .inCall: return "waveform"
        case .retrying: return "arrow.triangle.2.circlepath"
        case .unavailable: return "exclamationmark.triangle.fill"
        }
    }
}
