import Foundation

/// The last New a call began on from standby, and whether Zimmer has answered it.
///
/// A New from standby is a call before it is Zimmer's conversation, and the call can end first: the
/// network goes, the driver hangs up. Starting a conversation ends the open one, so a retry must never
/// start another while that one may be, or may yet become, the one the person asked for. Until Zimmer has
/// answered, a retry asks for the same conversation; once it has, a retry goes back to it. Only a fresh
/// tap on New is a new New.
public struct LiveNew: Sendable, Equatable {
    /// What a New should do.
    public enum Step: Sendable, Equatable {
        /// A fresh one: what is in standby for it, or one made now.
        case start
        /// The same one asked for again: Zimmer may or may not have given it.
        case askAgain(Int)
        /// Zimmer gave it after the call was over: call it.
        case carryOn(Int)
    }

    private var conversation: Int?
    private var answered = false

    public init() {}

    public var step: Step {
        guard let conversation else { return .start }
        return answered ? .carryOn(conversation) : .askAgain(conversation)
    }

    /// The conversation asked for and not answered: not one to be ready on, and not one a call can be
    /// on until it is asked for again.
    public var unanswered: Int? { answered ? nil : conversation }

    /// A call began on `conversation`, kept ready for New.
    public mutating func began(on conversation: Int) {
        self.conversation = conversation
        answered = false
    }

    /// Zimmer answered the New that asked for `asked`, with `given`: the same one, or another when it was
    /// gone. An answer to an older New changes nothing.
    public mutating func answered(_ asked: Int, with given: Int) {
        guard conversation == asked else { return }
        conversation = given
        answered = true
    }

    /// Whether a call beginning now is this New again: a retry of it, or a call on its conversation.
    public func isThis(tap: CarLiveChoice?, conversation: Int?) -> Bool {
        guard let mine = self.conversation else { return false }
        return tap == .startNew || conversation == mine
    }
}
