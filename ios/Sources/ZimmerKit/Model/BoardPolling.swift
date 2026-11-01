import Foundation

/// When the board's poller may read, and when the app coming to the front restarts it.
///
/// Opening the app is when a stale board shows, and it is when the poller's own clock is most
/// likely to be in the way. The phone suspends the app between its reads, so after any absence
/// longer than `BoardFreshness.interval` the poller's sleep is overdue: it ends the moment the
/// phone resumes the process, before the scene is in front and often before the network is
/// back. A read started then fails, or hangs until its request times out, and while it is out
/// it holds the poller's one slot — so the read the return to the front makes must neither wait
/// on it nor be refused by it. Hence:
///
/// - the poller reads only while the app is in front (`pollerMayRead`), so its overdue tick is
///   not spent on a phone that is still waking;
/// - the read on coming back to the front does not ask this at all: it always goes, and a read
///   it overtakes is dropped by `BoardFreshness`'s tickets;
/// - each return to the front is counted (`returns`), and the poller restarts on the count, which
///   cancels a read the phone suspended mid-flight and starts its clock from the fresh read.
public struct BoardPolling: Sendable {
    /// The app is in front. False from going to the background until it comes back.
    public private(set) var inFront = true
    /// The poller's read is out.
    public private(set) var pollOut = false
    /// How many times the app has come back to the front.
    public private(set) var returns = 0

    public init() {}

    /// The app went to the background: the poller's ticks are held until it is back.
    public mutating func wentToBackground() {
        inFront = false
    }

    /// The app came back to the front. The caller reads the board at once, whatever is out.
    public mutating func cameToFront() {
        inFront = true
        returns += 1
    }

    /// Whether the poller may start a read: only in front, and one of its own at a time.
    public var pollerMayRead: Bool { inFront && !pollOut }

    /// The poller's read is starting; false, and nothing changes, when it may not.
    public mutating func beginPoll() -> Bool {
        guard pollerMayRead else { return false }
        pollOut = true
        return true
    }

    /// The poller's read came back, failed or was cancelled.
    public mutating func endPoll() {
        pollOut = false
    }
}
