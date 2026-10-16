import Foundation

/// When the board reads itself again, and which of its reads may replace the list.
///
/// The board is read by several hands at once — the poller, a pull, a filter change, the read
/// after a row action — and the answers come back in any order. Only the newest read started
/// may replace the list, and only if nothing on this device changed the list after it started:
/// an older answer is the server before a trash, and would put the trashed row back.
public struct BoardFreshness: Sendable {
    /// Between reads while the board is in front.
    public static let interval: Duration = .seconds(30)
    /// Between reads after one that failed: a phone just back from the background often has
    /// no network for its first request.
    public static let retryInterval: Duration = .seconds(10)
    /// Coming back to the board reads it, unless it was read this recently.
    public static let staleAfter: TimeInterval = 5

    private var started = 0
    private var changedAt = 0
    /// When the list last came back from the server and was kept.
    public private(set) var lastRead: Date?
    /// The newest read failed, so the next is sooner.
    public private(set) var lastReadFailed = false

    public init() {}

    /// A read of the list is starting: its ticket, for `finish`.
    public mutating func begin() -> Int {
        started += 1
        return started
    }

    /// The list was changed here (a row trashed, starred, restored), so every read already
    /// out answers for the list as it was before.
    public mutating func noteLocalChange() {
        changedAt = started
    }

    /// Whether the read with `ticket` may replace the list.
    public func admits(_ ticket: Int) -> Bool {
        ticket == started && ticket > changedAt
    }

    /// The read with `ticket` came back; true when its rows replace the list.
    public mutating func finish(_ ticket: Int, at now: Date = Date()) -> Bool {
        guard admits(ticket) else { return false }
        lastRead = now
        lastReadFailed = false
        return true
    }

    /// The read with `ticket` failed. Only the newest read's failure counts.
    public mutating func fail(_ ticket: Int) {
        if ticket == started { lastReadFailed = true }
    }

    /// Whether coming back to the board should read it.
    public func isStale(at now: Date = Date()) -> Bool {
        guard let lastRead else { return true }
        return now.timeIntervalSince(lastRead) >= Self.staleAfter
    }

    /// How long the poller sleeps before its next read.
    public var nextPoll: Duration {
        lastReadFailed ? Self.retryInterval : Self.interval
    }
}
