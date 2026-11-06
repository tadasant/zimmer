import Foundation

/// Which conversation a call from the car is on: the driver's choice on the home screen.
///
/// Live Mode stays one thread. This is a choice at the point of starting, between carrying on
/// with the open conversation and ending it for a fresh one, not a choice among threads.
public enum CarLiveChoice: String, Hashable, Sendable {
    case continueOpen = "continue"
    case startNew = "new"
}

/// The choice the car is acting on, kept across the retries of one tap.
///
/// **New is spent the moment Zimmer answers it.** Starting a conversation ends the open one, so a
/// retry that started again would throw away the conversation the driver has just asked for, on
/// every retry. Once Zimmer has answered, the new conversation is the open one, so `LiveRetry`'s
/// retries and a dropped call's come back through `continueOpen`. A start Zimmer never answered
/// is still New: Retry asks for it again, not for the conversation the driver chose to leave.
public struct CarLiveWish: Hashable, Sendable {
    public private(set) var choice = CarLiveChoice.continueOpen

    public init() {}

    /// The driver tapped `tile`. A running call is the conversation, whatever the tile said when
    /// the driver reached for it, so New never replaces a call: it goes back to it. A tile
    /// reporting on a choice already made asks for that choice again.
    public mutating func tapped(_ tile: LiveTalkTile, callIsActive: Bool) {
        choice = callIsActive ? .continueOpen : tile.choice ?? choice
    }

    /// Zimmer answered, or a call is up: whatever comes next carries on with that conversation.
    public mutating func answered() {
        choice = .continueOpen
    }
}

extension LiveAPI {
    /// The conversation to call for `choice`: the open one, or a new one with voice on. Nil when
    /// the driver asked to continue and nothing is open: an ended conversation cannot take a
    /// call, and starting a new one in its place would be a different thread than the one asked
    /// for, with nothing to say so.
    public func conversation(for choice: CarLiveChoice) async throws -> Int? {
        switch choice {
        case .continueOpen: return try await liveConversations().current
        case .startNew: return try await startLiveConversation(.voice).id
        }
    }
}
