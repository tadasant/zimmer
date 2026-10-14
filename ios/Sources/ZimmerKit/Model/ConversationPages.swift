import Foundation

/// The conversation as the session page holds it: the newest window, which the page keeps
/// reading again, joined to the pages read back past the server's one-read cap. Positions
/// (`ConversationMessage.id`) are what join them, so a read never drops a message already on
/// screen and never shows one twice.
public struct ConversationPages: Hashable, Sendable {
    /// How many messages a poll reads from the end: enough to cover what lands between polls.
    public static let tailSize = 20

    /// The newest window, as last read whole and grown by the polls since.
    public private(set) var newest: Conversation?
    /// Pages read back past the cap, oldest first.
    public private(set) var earlier: [ConversationMessage] = []
    /// Where `earlier` starts and ends: positions `earlierStart ..< earlierEnd`.
    public private(set) var earlierStart = 0
    public private(set) var earlierEnd = 0

    public init() {}

    /// A whole read of the newest window. What it no longer covers is moved into the pages
    /// read back rather than dropped. If they can no longer be joined — more arrived between
    /// reads than the window holds, or the conversation got shorter, as it does when it is
    /// read differently — the pages read back go, and the newest window is what stays.
    public mutating func receive(_ window: Conversation) {
        if let old = newest, !earlier.isEmpty {
            if window.total < old.total {
                dropEarlier()
            } else {
                earlier += old.messages.filter { $0.id >= earlierEnd && $0.id < window.firstPosition }
                earlierEnd = max(earlierEnd, min(old.total, window.firstPosition))
                if earlierEnd < window.firstPosition { dropEarlier() }
            }
        }
        newest = window
    }

    /// A read of the last few messages, merged into the newest window by position. `false`
    /// when it cannot be: nothing read yet, more arrived than it covers, or the conversation
    /// got shorter. The caller then reads the window whole.
    public mutating func receiveTail(_ tail: Conversation) -> Bool {
        guard let old = newest, tail.total >= old.total, tail.firstPosition <= old.total else { return false }
        let kept = old.messages.filter { $0.id < tail.firstPosition }
        let first = min(old.firstPosition, tail.firstPosition)
        newest = Conversation(messages: kept + tail.messages, total: tail.total, truncated: first > 0, firstPosition: first)
        return true
    }

    /// A page read back with `before`: the messages just ahead of what is shown. A page that
    /// does not end where the shown messages start (one read twice) is ignored.
    public mutating func prepend(_ page: Conversation, before: Int) {
        guard let shown, before == shown.firstPosition, page.firstPosition < before else { return }
        if earlier.isEmpty { earlierEnd = before }
        earlier = page.messages.filter { $0.id < before } + earlier
        earlierStart = page.firstPosition
    }

    /// What the page shows: the pages read back, then the newest window.
    public var shown: Conversation? {
        guard let newest else { return nil }
        guard !earlier.isEmpty else { return newest }
        let messages = earlier + newest.messages.filter { $0.id >= earlierEnd }
        return Conversation(messages: messages, total: newest.total, truncated: earlierStart > 0, firstPosition: earlierStart)
    }

    private mutating func dropEarlier() {
        earlier = []
        earlierStart = 0
        earlierEnd = 0
    }
}
